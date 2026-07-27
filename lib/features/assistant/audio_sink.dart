import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

/// Plays synthesised speech. Behind an interface so the assistant's turn
/// logic can be tested without an audio device.
abstract class AudioSink {
  /// Completes when playback finishes, so the caller knows when the assistant
  /// has stopped talking and may listen again.
  Future<void> play(Uint8List wav);

  Future<void> stop();

  void dispose();
}

class PlayerAudioSink implements AudioSink {
  PlayerAudioSink([AudioPlayer? player]) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Future<void> play(Uint8List wav) async {
    await _player.stop();
    await _player.play(BytesSource(wav));
    // Waiting for the completion event rather than returning immediately is
    // what stops the microphone reopening while the speaker is still talking
    // and the assistant transcribing itself.
    await _player.onPlayerComplete.first;
  }

  @override
  Future<void> stop() => _player.stop();

  @override
  void dispose() => _player.dispose();
}
