import 'dart:typed_data';

import 'package:mobilecode/data/models/host.dart';
import 'package:mobilecode/features/agents/agent_spec.dart';
import 'package:mobilecode/features/ssh/tmux.dart';

/// What to open on the host.
class SessionRequest {
  const SessionRequest({
    required this.sessionName,
    this.agent,
    this.workingDirectory,
    this.environment = const {},
    this.columns = 80,
    this.rows = 24,
  });

  /// Multiplexer session name, already sanitised by [TmuxLauncher.sessionName].
  final String sessionName;

  /// Agent to launch, or null for a plain shell.
  final AgentSpec? agent;

  final String? workingDirectory;

  /// Extra environment for the remote process.
  ///
  /// Delivered over the SSH protocol's own env channel, which sshd applies
  /// only for variables listed in its `AcceptEnv`. Most sshd configurations
  /// accept little beyond `LANG` and `LC_*`, so treat delivery as best-effort
  /// and verify before relying on it for agent credentials.
  ///
  /// Note what this deliberately is not: an `export KEY=...` line written to
  /// the shell. That would land the secret in shell history and expose it in
  /// `ps` to every other user on the box.
  final Map<String, String> environment;

  final int columns;
  final int rows;
}

/// A live PTY on the remote host.
abstract class TerminalSession {
  /// Bytes from the remote process, stdout and stderr merged as a PTY does.
  Stream<Uint8List> get output;

  /// Completes when the remote side ends.
  Future<void> get done;

  /// Whether the remote work survives losing this connection.
  MultiplexerKind get multiplexer;

  void write(Uint8List data);

  /// Tells the remote process the window changed. Agent TUIs repaint on
  /// SIGWINCH; skip this and their output wraps into garbage.
  void resize(int columns, int rows, {int pixelWidth = 0, int pixelHeight = 0});

  /// Drops the connection but leaves the remote session running. This is what
  /// the app does when it goes to the background.
  Future<void> detach();

  /// Ends the remote session and everything inside it.
  Future<void> close();
}

/// Opens connections to a host.
///
/// The app connects directly from the device, but everything above this
/// interface is written against it rather than against dartssh2. If we ever
/// need a relay — the one thing direct connections cannot do is wake the
/// phone when an agent finishes — it slots in here without the terminal,
/// agent, and UI layers noticing.
abstract class SshTransport {
  Future<SshConnection> connect(HostConfig host);
}

/// An authenticated connection to a host.
///
/// Separate from [TerminalSession] because a connection outlives any one
/// session and can do things a PTY cannot. Probing which agents are installed
/// needs a one-shot command *before* the user has chosen what to launch, and
/// re-authenticating for that would mean a second handshake — and a second
/// passphrase or biometric prompt — for a question we could have asked over
/// the connection we already have.
abstract class SshConnection {
  /// Runs a one-shot command and returns its stdout.
  ///
  /// This is a non-login, non-interactive shell, exactly as sshd provides it.
  /// Commands that depend on the user's profile — anything involving `PATH`
  /// set up by nvm, pyenv, or similar — must invoke a login shell explicitly.
  Future<String> run(String command);

  /// Opens a PTY, launching the agent in [request] if one is named.
  Future<TerminalSession> openSession(SessionRequest request);

  /// Drops the connection. Any multiplexed work on the host keeps running.
  Future<void> close();
}
