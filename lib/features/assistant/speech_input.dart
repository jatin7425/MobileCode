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

  @override
  bool get isListening => _speech.isListening;

  @override
  Future<bool> initialise() async {
    if (_ready) return true;
    _ready = await _speech.initialize(
      onError: (SpeechRecognitionError error) {},
      onStatus: (_) {},
      debugLogging: false,
    );
    return _ready;
  }

  @override
  Future<void> listen({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
    required void Function(double level) onLevel,
    required void Function(String message) onError,
  }) async {
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
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();

  /// Android reports roughly -2..10 dB and iOS a different range again.
  /// Squashed to 0..1 so the HUD does not have to know which platform it is on.
  static double _normalise(double level) {
    final scaled = (level + 2) / 12;
    return scaled.isNaN ? 0 : scaled.clamp(0.0, 1.0);
  }
}
