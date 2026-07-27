import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Microphone-to-text, behind an interface.
///
/// The assistant's turn logic is worth testing and the platform recogniser is
/// not mockable, so everything the controller needs is expressed here and the
/// plugin sits behind [PlatformSpeechInput].
abstract class SpeechInput {
  /// Asks for permission and checks a recogniser exists. False means the
  /// device cannot do this at all — on Android, usually no Google app.
  Future<bool> initialise();

  Future<void> listen({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
    required void Function(double level) onLevel,
    required void Function(String message) onError,
  });

  Future<void> stop();

  Future<void> cancel();

  bool get isListening;
}

class PlatformSpeechInput implements SpeechInput {
  PlatformSpeechInput([SpeechToText? speech]) : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;
  var _ready = false;

  /// The handler belonging to the turn currently listening.
  ///
  /// `initialize` may only be called once per app session and its callbacks
  /// cannot be replaced afterwards, so the plugin's error channel is global
  /// while ours is per-turn. Holding the active handler here bridges the two.
  void Function(String message)? _onError;

  @override
  bool get isListening => _speech.isListening;

  @override
  Future<bool> initialise() async {
    if (_ready) return true;
    _ready = await _speech.initialize(
      // Recogniser failures arrive here, not on the listen() callback. Left
      // as a no-op this swallows them, and because `cancelOnError` ends the
      // session anyway the caller is never told — it waits on a microphone
      // that has already stopped.
      onError: (SpeechRecognitionError error) =>
          _onError?.call(_describe(error)),
      onStatus: (_) {},
      debugLogging: false,
    );
    return _ready;
  }

  /// Turns a plugin error code into something worth showing a person.
  static String _describe(SpeechRecognitionError error) {
    return switch (error.errorMsg) {
      'error_permission' || 'error_permission_denied' =>
        'Microphone permission was denied.',
      'error_no_match' => 'Nothing was recognised — try again.',
      'error_speech_timeout' => 'No speech detected.',
      'error_network' || 'error_network_timeout' =>
        'Speech recognition needs a network connection.',
      'error_busy' => 'The recogniser is busy.',
      final other => 'Speech recognition failed: $other',
    };
  }

  @override
  Future<void> listen({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
    required void Function(double level) onLevel,
    required void Function(String message) onError,
  }) async {
    _onError = onError;

    if (!await initialise()) {
      onError('No speech recogniser is available on this device.');
      return;
    }

    await _speech.listen(
      onResult: (result) => onResult(result.recognizedWords, result.finalResult),
      onSoundLevelChange: (level) => onLevel(_normalise(level)),
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        partialResults: true,
        cancelOnError: true,
        // Dictation keeps the recogniser open through short pauses, which is
        // what a spoken question needs; the default stops at the first gap.
        listenMode: ListenMode.dictation,
        // A question is short. Without a cap the recogniser can sit open
        // until the platform times it out, leaving the HUD stuck listening.
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Future<void> stop() {
    _onError = null;
    return _speech.stop();
  }

  @override
  Future<void> cancel() {
    _onError = null;
    return _speech.cancel();
  }

  /// Android reports roughly -2..10 dB and iOS a different range again.
  /// Squashed to 0..1 so the HUD does not have to know which platform it is on.
  static double _normalise(double level) {
    final scaled = (level + 2) / 12;
    return scaled.isNaN ? 0 : scaled.clamp(0.0, 1.0);
  }
}
