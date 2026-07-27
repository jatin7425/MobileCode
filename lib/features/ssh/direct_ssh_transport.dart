import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'package:mobilecode/data/models/host.dart';
import 'package:mobilecode/data/secure/credential_store.dart';
import 'package:mobilecode/features/ssh/host_key_verifier.dart';
import 'package:mobilecode/features/ssh/ssh_transport.dart';
import 'package:mobilecode/features/ssh/tmux.dart';

/// Raised when we cannot connect, with a message fit to show the user.
class SshConnectionException implements Exception {
  const SshConnectionException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// Builds the host key verifier for a connection. Injected so the UI can own
/// the trust prompt without this layer importing Flutter.
typedef HostKeyVerifierFactory = HostKeyVerifier Function(HostConfig host);

/// Connects straight from the device to the host — no relay, nothing in the
/// middle.
class DirectSshTransport implements SshTransport {
  DirectSshTransport({
    required this.credentials,
    required this.verifierFactory,
    this.launcher = const TmuxLauncher(),
    this.timeout = const Duration(seconds: 20),
  });

  final CredentialStore credentials;
  final HostKeyVerifierFactory verifierFactory;
  final TmuxLauncher launcher;
  final Duration timeout;

  @override
  Future<SshConnection> connect(HostConfig host) async {
    final verifier = verifierFactory(host);
    final client = await _authenticate(host, verifier);
    return _DirectSshConnection(
      client: client,
      host: host,
      launcher: launcher,
    );
  }

  Future<SSHClient> _authenticate(
    HostConfig host,
    HostKeyVerifier verifier,
  ) async {
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(
        host.hostname,
        host.port,
        timeout: timeout,
      );
    } catch (error) {
      throw SshConnectionException(
        'Could not reach ${host.hostname}:${host.port}.',
        cause: error,
      );
    }

    final secret = host.credentialRef == null
        ? null
        : await credentials.read(host.credentialRef!);

    final client = SSHClient(
      socket,
      username: host.username,
      onVerifyHostKey: verifier.verify,
      identities: host.authMethod == SshAuthMethod.privateKey && secret != null
          ? _parseKey(secret, await _passphraseFor(host))
          : null,
      onPasswordRequest: host.authMethod == SshAuthMethod.password
          ? () => secret ?? ''
          : null,
    );

    try {
      await client.authenticated;
    } catch (error) {
      client.close();
      final mismatch = verifier.mismatch;
      if (mismatch != null) {
        throw SshConnectionException(
          'The host key for ${host.label} changed. This is either a rebuilt '
          'machine or someone intercepting the connection. Nothing was sent. '
          'Remove the pinned key in settings if you know the host was '
          'rebuilt.',
          cause: mismatch,
        );
      }
      throw SshConnectionException(
        'Authentication failed for ${host.displayAddress}.',
        cause: error,
      );
    }

    return client;
  }

  Future<String?> _passphraseFor(HostConfig host) =>
      credentials.read(CredentialStore.hostPassphraseRef(host.id));

  List<SSHKeyPair> _parseKey(String pem, String? passphrase) {
    try {
      return SSHKeyPair.fromPem(pem, passphrase);
    } catch (error) {
      throw SshConnectionException(
        'That private key could not be read. If it is passphrase-protected, '
        'check the passphrase.',
        cause: error,
      );
    }
  }

}

class _DirectSshConnection implements SshConnection {
  _DirectSshConnection({
    required this.client,
    required this.host,
    required this.launcher,
  });

  final SSHClient client;
  final HostConfig host;
  final TmuxLauncher launcher;

  @override
  Future<String> run(String command) async =>
      utf8.decode(await client.run(command), allowMalformed: true);

  @override
  Future<TerminalSession> openSession(SessionRequest request) async {
    final multiplexer = await _detectMultiplexer();
    final command = launcher.attachOrCreate(
      name: request.sessionName,
      workingDirectory:
          request.workingDirectory ?? host.defaultWorkingDirectory,
      agent: request.agent,
      multiplexer: multiplexer,
    );

    final pty = SSHPtyConfig(width: request.columns, height: request.rows);

    // Run the multiplexer as the channel's command rather than typing it into
    // a shell: no race against the shell's prompt, and nothing lands in the
    // user's shell history.
    final session = command.isEmpty
        ? await client.shell(pty: pty, environment: request.environment)
        : await client.execute(
            command,
            pty: pty,
            environment: request.environment,
          );

    return _DirectTerminalSession(
      client: client,
      session: session,
      multiplexer: multiplexer,
      sessionName: request.sessionName,
      launcher: launcher,
    );
  }

  @override
  Future<void> close() async {
    client.close();
    await client.done;
  }

  Future<MultiplexerKind> _detectMultiplexer() async {
    try {
      return TmuxLauncher.parseDetectOutput(
        await run(TmuxLauncher.detectCommand),
      );
    } catch (_) {
      // A host that will not answer a probe still deserves a shell; treat it
      // as having no multiplexer and let the UI warn about durability.
      return MultiplexerKind.none;
    }
  }
}

class _DirectTerminalSession implements TerminalSession {
  _DirectTerminalSession({
    required this.client,
    required this.session,
    required this.multiplexer,
    required this.sessionName,
    required this.launcher,
  }) {
    _output
      ..addStream(session.stdout).whenComplete(_maybeClose)
      ..addStream(session.stderr).whenComplete(_maybeClose);
  }

  final SSHClient client;
  final SSHSession session;
  final String sessionName;
  final TmuxLauncher launcher;

  @override
  final MultiplexerKind multiplexer;

  final _output = StreamController<Uint8List>.broadcast();
  int _openStreams = 2;

  void _maybeClose() {
    if (--_openStreams == 0 && !_output.isClosed) _output.close();
  }

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<void> get done => session.done;

  @override
  void write(Uint8List data) => session.write(data);

  @override
  void resize(
    int columns,
    int rows, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) =>
      session.resizeTerminal(columns, rows, pixelWidth, pixelHeight);

  @override
  Future<void> detach() async {
    // Just drop the connection. tmux notices its client went away and detaches
    // the session, leaving the agent running.
    client.close();
    await client.done;
  }

  @override
  Future<void> close() async {
    if (multiplexer == MultiplexerKind.tmux) {
      try {
        await client.run(launcher.killSession(sessionName));
      } catch (_) {
        // Best effort — we are tearing down regardless.
      }
    }
    client.close();
    await client.done;
  }
}
