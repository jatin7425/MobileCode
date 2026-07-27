import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// An [SSHSocket] carried over a WebSocket instead of a raw TCP connection.
///
/// For hosts that expose no TCP endpoint — only an HTTPS URL that accepts a
/// WebSocket upgrade. SSH needs an ordered, reliable byte stream and nothing
/// more, so it runs inside a WebSocket perfectly well.
///
/// Message boundaries are irrelevant here. SSH frames itself, and dartssh2's
/// transport reassembles from a byte stream, so a WebSocket message carrying
/// half a packet is fine as long as order is preserved — which the protocol
/// guarantees.
class WebSocketSshSocket implements SSHSocket {
  WebSocketSshSocket._(this._socket) {
    _subscription = _socket.listen(
      (message) {
        // Binary frames are the expected case. A text frame means something
        // upstream is mangling the stream — a proxy, or a bridge configured
        // for text mode — so take the bytes rather than dropping them, since
        // dropping would look like an inexplicable protocol error later.
        if (message is List<int>) {
          _incoming.add(Uint8List.fromList(message));
        } else if (message is String) {
          _incoming.add(Uint8List.fromList(message.codeUnits));
        }
      },
      onError: (Object error, StackTrace stack) {
        _incoming.addError(error, stack);
        _finish(error);
      },
      onDone: () => _finish(null),
      cancelOnError: false,
    );

    _outgoing.stream.listen(
      (data) {
        if (_closed) return;
        _socket.add(data);
      },
      onDone: () => unawaited(close()),
    );
  }

  /// Opens a WebSocket and wraps it.
  ///
  /// [headers] carries the bearer token for a private forwarded port; a public
  /// one needs none.
  static Future<WebSocketSshSocket> connect(
    Uri url, {
    Map<String, dynamic> headers = const {},
    Duration? timeout,
  }) async {
    final scheme = switch (url.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      final other => other,
    };
    final target = url.replace(scheme: scheme);

    var pending = WebSocket.connect(
      target.toString(),
      headers: headers.isEmpty ? null : headers,
    );
    if (timeout != null) pending = pending.timeout(timeout);

    return WebSocketSshSocket._(await pending);
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;

  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();
  var _closed = false;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      await _socket.close();
    }
    return _done.future;
  }

  @override
  Future<void> flush() async {
    // No-op: dart:io's WebSocket queues each frame for immediate delivery and
    // exposes no buffer to drain.
  }

  @override
  void destroy() {
    _closed = true;
    unawaited(_subscription.cancel());
    unawaited(_socket.close());
    _finish(null);
  }

  void _finish(Object? error) {
    if (_done.isCompleted) return;
    _closed = true;
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_outgoing.isClosed) unawaited(_outgoing.close());
    // A transport that ends is a normal outcome even when it ends badly; the
    // error already went to listeners of [stream], and completing [done] with
    // an error too would surface it twice as an unhandled exception.
    _done.complete();
  }
}
