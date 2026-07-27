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

/// Opens sessions on a host.
///
/// The app connects directly from the device, but everything above this
/// interface is written against it rather than against dartssh2. If we ever
/// need a relay — the one thing direct connections cannot do is wake the
/// phone when an agent finishes — it slots in here without the terminal,
/// agent, and UI layers noticing.
abstract class SshTransport {
  Future<TerminalSession> connect(HostConfig host, SessionRequest request);
}
