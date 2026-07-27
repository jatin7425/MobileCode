import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import 'package:mobilecode/data/models/host.dart';
import 'package:mobilecode/features/ssh/ssh_transport.dart';
import 'package:mobilecode/features/ssh/tmux.dart';

enum SessionStatus { idle, connecting, connected, detached, closed, failed }

/// Owns one terminal and the remote session behind it, and keeps the two
/// wired together.
class SessionController extends ChangeNotifier {
  SessionController({
    required this.host,
    required this.request,
    required this.transport,
  }) {
    terminal
      ..onOutput = _handleInput
      ..onResize = _handleResize;
  }

  final HostConfig host;
  final SessionRequest request;
  final SshTransport transport;

  /// 4000 lines of scrollback: enough to page back through an agent's
  /// reasoning without holding a session's whole history in memory.
  final terminal = Terminal(maxLines: 4000);

  TerminalSession? _session;
  StreamSubscription<String>? _outputSubscription;

  SessionStatus status = SessionStatus.idle;
  String? errorMessage;
  MultiplexerKind multiplexer = MultiplexerKind.none;

  /// True when the remote work would not survive a dropped connection, so the
  /// UI can say so rather than letting the user find out the hard way.
  bool get isEphemeral =>
      status == SessionStatus.connected && !multiplexer.isDurable;

  Future<void> connect() async {
    if (status == SessionStatus.connecting) return;
    _setStatus(SessionStatus.connecting);

    try {
      final session = await transport.connect(host, request);
      _session = session;
      multiplexer = session.multiplexer;

      // Decoding through the stream converter, not per chunk: a UTF-8
      // sequence split across two network reads must not turn into a
      // replacement character mid-glyph.
      _outputSubscription = const Utf8Decoder(allowMalformed: true)
          .bind(session.output)
          .listen(terminal.write);

      unawaited(session.done.then((_) {
        if (status == SessionStatus.connected) _setStatus(SessionStatus.closed);
      }));

      _setStatus(SessionStatus.connected);
    } catch (error) {
      errorMessage = error.toString();
      _setStatus(SessionStatus.failed);
    }
  }

  /// Drops the connection but leaves the agent running on the host. Called
  /// when the app goes to the background, where iOS would tear the socket
  /// down anyway — better to do it deliberately and stop draining the battery
  /// holding a radio open.
  Future<void> detach() async {
    final session = _session;
    if (session == null || status != SessionStatus.connected) return;
    await _outputSubscription?.cancel();
    _outputSubscription = null;
    await session.detach();
    _session = null;
    _setStatus(SessionStatus.detached);
  }

  /// Reconnects after [detach]. `tmux new-session -A` reattaches us to the
  /// same session, and the TUI repaints itself.
  Future<void> reattach() async {
    if (status != SessionStatus.detached) return;
    await connect();
  }

  /// Ends the remote session and everything running in it.
  Future<void> terminate() async {
    await _outputSubscription?.cancel();
    _outputSubscription = null;
    await _session?.close();
    _session = null;
    _setStatus(SessionStatus.closed);
  }

  /// Sends a control character, e.g. `sendControl('c')` for Ctrl-C.
  void sendControl(String letter) {
    final sequence = _toControl(letter);
    if (sequence != null) _send(sequence);
  }

  /// Sends a literal escape sequence such as `\x1b[A` for the up arrow.
  void sendRaw(String sequence) => _send(sequence);

  // --- Sticky modifiers -----------------------------------------------
  //
  // A phone keyboard has no Ctrl or Alt. The accessory bar arms one instead,
  // and it applies to the next character the user types on the soft keyboard.
  // All terminal input funnels through [_handleInput], so this is the one
  // place that has to know about it.

  bool ctrlArmed = false;
  bool altArmed = false;

  void toggleCtrl() {
    ctrlArmed = !ctrlArmed;
    if (ctrlArmed) altArmed = false;
    notifyListeners();
  }

  void toggleAlt() {
    altArmed = !altArmed;
    if (altArmed) ctrlArmed = false;
    notifyListeners();
  }

  void _handleInput(String data) {
    if (data.length == 1 && (ctrlArmed || altArmed)) {
      final sequence = ctrlArmed ? _toControl(data) : '\x1b$data';
      ctrlArmed = false;
      altArmed = false;
      notifyListeners();
      if (sequence != null) {
        _send(sequence);
        return;
      }
    }
    _send(data);
  }

  /// Maps a letter to its control code: `c` -> 0x03. Returns null for
  /// characters that have no control form, so we send them unchanged rather
  /// than swallowing the keystroke.
  String? _toControl(String letter) {
    if (letter.length != 1) return null;
    final code = letter.toUpperCase().codeUnitAt(0);
    if (code < 0x40 || code > 0x5F) return null;
    return String.fromCharCode(code - 0x40);
  }

  void _send(String data) {
    final session = _session;
    if (session == null) return;
    session.write(Uint8List.fromList(utf8.encode(data)));
  }

  void _handleResize(int width, int height, int pixelWidth, int pixelHeight) {
    _session?.resize(
      width,
      height,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
  }

  void _setStatus(SessionStatus next) {
    status = next;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_outputSubscription?.cancel());
    // Detach rather than kill: disposing the screen should not destroy work
    // running on the user's machine.
    unawaited(_session?.detach());
    super.dispose();
  }
}
