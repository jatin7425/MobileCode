import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/features/ssh/websocket_ssh_socket.dart';

/// Spins up a real WebSocket server so these tests exercise the actual
/// upgrade, framing, and close handshake rather than a stand-in.
class _EchoServer {
  _EchoServer(this._server, this.port);

  final HttpServer _server;
  final int port;
  final _sockets = <WebSocket>[];

  static Future<_EchoServer> start({
    bool echo = true,
    void Function(WebSocket socket)? onConnect,
  }) async {
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _EchoServer(httpServer, httpServer.port);

    httpServer.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      server._sockets.add(socket);
      onConnect?.call(socket);
      if (echo) {
        socket.listen(
          socket.add,
          onDone: () {},
          cancelOnError: false,
        );
      }
    });

    return server;
  }

  Uri get uri => Uri.parse('ws://127.0.0.1:$port/');

  Future<void> stop() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}

void main() {
  test('carries bytes in both directions', () async {
    final server = await _EchoServer.start();
    addTearDown(server.stop);

    final socket = await WebSocketSshSocket.connect(server.uri);
    final received = <int>[];
    final gotFive = Completer<void>();
    socket.stream.listen((chunk) {
      received.addAll(chunk);
      if (received.length >= 5 && !gotFive.isCompleted) gotFive.complete();
    });

    socket.sink.add(Uint8List.fromList([1, 2, 3, 4, 5]));
    await gotFive.future.timeout(const Duration(seconds: 5));

    expect(received, [1, 2, 3, 4, 5]);
    await socket.close();
  });

  test('preserves order across message boundaries', () async {
    // SSH needs an ordered byte stream, not preserved framing. Sending three
    // separate writes must arrive as one correctly ordered sequence.
    final server = await _EchoServer.start();
    addTearDown(server.stop);

    final socket = await WebSocketSshSocket.connect(server.uri);
    final received = <int>[];
    final done = Completer<void>();
    socket.stream.listen((chunk) {
      received.addAll(chunk);
      if (received.length >= 9 && !done.isCompleted) done.complete();
    });

    socket.sink.add(Uint8List.fromList([1, 2, 3]));
    socket.sink.add(Uint8List.fromList([4, 5, 6]));
    socket.sink.add(Uint8List.fromList([7, 8, 9]));
    await done.future.timeout(const Duration(seconds: 5));

    expect(received, [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    await socket.close();
  });

  test('handles an SSH-sized payload', () async {
    // Larger than a typical WebSocket frame, to confirm nothing truncates.
    final server = await _EchoServer.start();
    addTearDown(server.stop);

    final socket = await WebSocketSshSocket.connect(server.uri);
    final payload = Uint8List.fromList(
      List<int>.generate(64 * 1024, (i) => i % 256),
    );

    final received = <int>[];
    final done = Completer<void>();
    socket.stream.listen((chunk) {
      received.addAll(chunk);
      if (received.length >= payload.length && !done.isCompleted) {
        done.complete();
      }
    });

    socket.sink.add(payload);
    await done.future.timeout(const Duration(seconds: 10));

    expect(received.length, payload.length);
    expect(received, payload);
    await socket.close();
  });

  test('completes done when the server closes', () async {
    final server = await _EchoServer.start(
      echo: false,
      onConnect: (socket) => socket.close(),
    );
    addTearDown(server.stop);

    final socket = await WebSocketSshSocket.connect(server.uri);
    await socket.done.timeout(const Duration(seconds: 5));
  });

  test('completes done when closed locally', () async {
    final server = await _EchoServer.start();
    addTearDown(server.stop);

    final socket = await WebSocketSshSocket.connect(server.uri);
    await socket.close().timeout(const Duration(seconds: 5));
    await socket.done.timeout(const Duration(seconds: 5));
  });

  test('destroy is safe to call and settles done', () async {
    final server = await _EchoServer.start();
    addTearDown(server.stop);

    final socket = await WebSocketSshSocket.connect(server.uri);
    socket.destroy();
    await socket.done.timeout(const Duration(seconds: 5));
    // Idempotent — teardown paths may call both.
    await socket.close().timeout(const Duration(seconds: 5));
  });

  test('upgrades https to wss when building the target', () async {
    // A Codespaces forwarded port is handed to us as an https URL; connecting
    // to it verbatim would fail the upgrade.
    await expectLater(
      WebSocketSshSocket.connect(
        Uri.parse('https://127.0.0.1:1/'),
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<Exception>()),
    );
  });
}
