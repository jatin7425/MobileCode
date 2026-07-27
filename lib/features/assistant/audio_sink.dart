import 'dart:async';
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

  /// Longest a single spoken answer may take before the wait is abandoned.
  ///
  /// Answers are capped at a few hundred tokens, so anything approaching this
  /// is a stuck player rather than a long sentence.
  static const _limit = Duration(minutes: 2);

  @override
  Future<void> play(Uint8List wav) async {
    await _player.stop();

    // Subscribed before playback starts, or a short clip can finish between
    // the two calls and the completion event is missed entirely.
    final finished = _player.onPlayerComplete.first;

    await _player.play(BytesSource(wav));

    // Waiting for completion rather than returning immediately is what stops
    // the microphone reopening while the speaker is still talking and the
    // assistant transcribing itself.
    //
    // Bounded, because the event does not always arrive: a failed decode
    // emits nothing, and Android's low-latency path is documented not to
    // fire it at all. An unbounded await there would strand the turn in
    // `speaking` with no way back.
    try {
      await finished.timeout(_limit);
    } on TimeoutException {
      await _player.stop();
    }
  }

  @override
  Future<void> stop() => _player.stop();

  @override
  void dispose() => _player.dispose();
}
