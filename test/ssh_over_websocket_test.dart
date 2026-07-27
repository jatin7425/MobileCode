@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/features/ssh/websocket_ssh_socket.dart';

/// End-to-end proof of the Codespaces transport.
///
/// This reproduces the exact topology the app will use for a Codespace:
///
///     dartssh2  ->  WebSocketSshSocket  ->  ws bridge  ->  real sshd
///
/// A Codespace's forwarded port is an HTTPS endpoint with a WebSocket upgrade
/// in front of a listener inside the container. If SSH survives that path
/// here, the approach is sound; if it does not, no amount of UI work saves it.
///
/// Skips when sshd is unavailable rather than failing, so the suite still runs
/// on machines without openssh-server.
void main() {
  final sshdPath = ['/usr/sbin/sshd', '/usr/local/sbin/sshd']
      .firstWhere(FileSystemEntity.isFileSync, orElse: () => '');

  test(
    'runs a real SSH session over a WebSocket',
    () async {
      final fixture = await _SshdFixture.start(sshdPath);
      addTearDown(fixture.stop);

      final bridge = await _WebSocketToTcpBridge.start(fixture.port);
      addTearDown(bridge.stop);

      final socket = await WebSocketSshSocket.connect(bridge.uri);
      final client = SSHClient(
        socket,
        username: fixture.username,
        identities: SSHKeyPair.fromPem(fixture.clientKeyPem),
        onVerifyHostKey: (_, _) => true,
      );

      try {
        await client.authenticated.timeout(const Duration(seconds: 20));

        final output = utf8.decode(
          await client.run('echo hello-over-websocket'),
        );
        expect(output.trim(), 'hello-over-websocket');

        // A second command on the same connection: proves the byte stream
        // stays in sync after the first channel closes, which is where
        // framing bugs in a WebSocket transport would show up.
        final second = utf8.decode(await client.run('echo second'));
        expect(second.trim(), 'second');
      } finally {
        client.close();
      }
    },
    skip: sshdPath.isEmpty ? 'sshd not installed' : null,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

/// A throwaway sshd listening on loopback with a generated key pair.
class _SshdFixture {
  _SshdFixture._({
    required this.process,
    required this.directory,
    required this.port,
    required this.username,
    required this.clientKeyPem,
  });

  final Process process;
  final Directory directory;
  final int port;
  final String username;
  final String clientKeyPem;

  static Future<_SshdFixture> start(String sshdPath) async {
    final dir = Directory.systemTemp.createTempSync('mobilecode-sshd');
    final hostKey = '${dir.path}/host_ed25519';
    final clientKey = '${dir.path}/client_ed25519';

    for (final key in [hostKey, clientKey]) {
      final result = await Process.run(
        'ssh-keygen',
        ['-q', '-t', 'ed25519', '-N', '', '-f', key],
      );
      if (result.exitCode != 0) {
        throw StateError('ssh-keygen failed: ${result.stderr}');
      }
    }

    final authorizedKeys = File('${dir.path}/authorized_keys')
      ..writeAsStringSync(File('$clientKey.pub').readAsStringSync());

    final port = await _freePort();
    final username = Platform.environment['USER'] ?? 'root';

    File('${dir.path}/sshd_config').writeAsStringSync('''
Port $port
ListenAddress 127.0.0.1
HostKey $hostKey
AuthorizedKeysFile ${authorizedKeys.path}
PidFile ${dir.path}/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin yes
StrictModes no
LogLevel ERROR
''');

    // sshd refuses to start without its privilege separation directory.
    Directory('/run/sshd').createSync(recursive: true);

    final process = await Process.start(
      sshdPath,
      ['-D', '-e', '-f', '${dir.path}/sshd_config'],
    );
    process.stderr.transform(utf8.decoder).listen((line) {
      if (line.trim().isNotEmpty) printOnFailure('sshd: ${line.trim()}');
    });

    await _waitForPort(port);

    return _SshdFixture._(
      process: process,
      directory: dir,
      port: port,
      username: username,
      clientKeyPem: File(clientKey).readAsStringSync(),
    );
  }

  Future<void> stop() async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => 0,
    );
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }

  static Future<int> _freePort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  static Future<void> _waitForPort(int port) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 500),
        );
        socket.destroy();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    throw StateError('sshd did not start listening on $port');
  }
}

/// Stands in for the Codespaces forwarded port: accepts a WebSocket upgrade
/// and proxies the bytes to a local TCP listener.
class _WebSocketToTcpBridge {
  _WebSocketToTcpBridge._(this._server);

  final HttpServer _server;

  static Future<_WebSocketToTcpBridge> start(int targetPort) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bridge = _WebSocketToTcpBridge._(server);

    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      final tcp = await Socket.connect(
        InternetAddress.loopbackIPv4,
        targetPort,
      );

      tcp.listen(
        ws.add,
        onDone: () => ws.close(),
        onError: (_) => ws.close(),
        cancelOnError: true,
      );

      ws.listen(
        (message) {
          if (message is List<int>) tcp.add(message);
        },
        onDone: () => tcp.destroy(),
        onError: (_) => tcp.destroy(),
        cancelOnError: true,
      );
    });

    return bridge;
  }

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}/');

  Future<void> stop() => _server.close(force: true);
}
