import 'package:flutter/foundation.dart';

import 'package:mobilecode/features/assistant/assistant_identity.dart';
import 'package:mobilecode/features/assistant/audio_sink.dart';
import 'package:mobilecode/features/assistant/llm_client.dart';
import 'package:mobilecode/features/assistant/speech_input.dart';
import 'package:mobilecode/features/voice/emotion_director.dart';
import 'package:mobilecode/features/voice/nvcf_voice_client.dart';
import 'package:mobilecode/features/voice/voice_catalog.dart';

/// Where the assistant is in a turn.
enum AssistantPhase { idle, listening, thinking, speaking, failed }

/// One line of the conversation, for the transcript on screen.
class Utterance {
  const Utterance(this.speaker, this.text, {this.emotion});

  final bool speaker; // true when the assistant said it
  final String text;
  final String? emotion;
}

/// Drives one listen → think → speak turn.
///
/// Everything with a platform dependency — microphone, network, audio device —
/// arrives through an interface, so the sequencing that actually goes wrong
/// (double-starts, replies arriving after disposal, a failure mid-turn) is
/// testable without a device.
class AssistantController extends ChangeNotifier {
  AssistantController({
    required this.speech,
    required this.audio,
    this.llm,
    this.voice,
    this.speaker,
    this.language = AssistantLanguage.english,
  });

  final SpeechInput speech;
  final AudioSink audio;

  /// Null until a model endpoint is configured. The assistant still listens
  /// without one — it just cannot answer.
  final LlmClient? llm;

  /// Null until a speech endpoint is configured.
  final NvcfVoiceClient? voice;

  /// The speaker this assistant talks as, if one has been assigned.
  final VoiceSpeaker? speaker;

  AssistantLanguage language;

  var _phase = AssistantPhase.idle;
  var _heard = '';
  var _level = 0.0;
  String? _error;
  final _history = <Utterance>[];

  /// Guards against a reply from an abandoned turn landing on the screen.
  var _turn = 0;
  var _disposed = false;

  AssistantPhase get phase => _phase;

  /// What the microphone has picked up so far this turn.
  String get heard => _heard;

  /// Smoothed input loudness, 0..1, for the reactor to breathe with.
  double get level => _level;

  String? get error => _error;

  List<Utterance> get history => List.unmodifiable(_history);

  bool get canAnswer => llm != null;
  bool get canSpeak => voice != null && speaker != null;

  /// Starts a turn, or ends one early if already listening.
  Future<void> toggleListening() async {
    if (_phase == AssistantPhase.listening) {
      await speech.stop();
      // Stopping does not always produce a final result — a tap during
      // silence produces none at all — so the phase has to be reset here or
      // the panel sits on LISTENING and the next tap only tries to stop
      // again. A final result that does arrive still takes over from idle.
      if (_phase == AssistantPhase.listening) _setPhase(AssistantPhase.idle);
      return;
    }
    if (_phase == AssistantPhase.thinking || _phase == AssistantPhase.speaking) {
      return;
    }
    await _startListening();
  }

  Future<void> _startListening() async {
    final turn = ++_turn;

    _heard = '';
    _error = null;
    _setPhase(AssistantPhase.listening);

    await speech.listen(
      localeId: language.sttLocale,
      onResult: (text, isFinal) {
        if (turn != _turn || _disposed) return;
        _heard = text;
        notifyListeners();
        // The recogniser reports a final result when the speaker stops; that
        // is the cue to answer, not a separate button press.
        if (isFinal && text.trim().isNotEmpty) _respondTo(text.trim(), turn);
        if (isFinal && text.trim().isEmpty) _setPhase(AssistantPhase.idle);
      },
      onLevel: (level) {
        if (turn != _turn || _disposed) return;
        // Smoothed, or the reactor jitters on every frame of silence.
        _level = _level * 0.7 + level * 0.3;
        notifyListeners();
      },
      onError: (message) {
        if (turn != _turn || _disposed) return;
        _fail(message);
      },
    );
  }

  Future<void> _respondTo(String question, int turn) async {
    _history.add(Utterance(false, question));
    _setPhase(AssistantPhase.thinking);

    final model = llm;
    if (model == null) {
      _fail('No model endpoint is configured yet.');
      return;
    }

    try {
      final director = speaker == null ? null : EmotionDirector(speaker!);
      final reply = await model.complete(
        messages: _messages(question, director),
        responseFormat: director?.responseFormat(),
      );
      if (turn != _turn || _disposed) return;

      final line = director?.parse(reply) ??
          SpokenLine(text: reply, emotion: null);

      _history.add(Utterance(true, line.text, emotion: line.emotion));
      _heard = '';
      notifyListeners();

      await _speak(line, turn);
    } catch (error) {
      if (turn != _turn || _disposed) return;
      _fail('$error');
    }
  }

  Future<void> _speak(SpokenLine line, int turn) async {
    final client = voice;
    final speakerVoice = speaker;
    if (client == null || speakerVoice == null) {
      // Nothing to speak with — the answer is still on screen, which is a
      // better outcome than treating this as a failed turn.
      _setPhase(AssistantPhase.idle);
      return;
    }

    _setPhase(AssistantPhase.speaking);
    try {
      final clip = await client.synthesize(
        text: line.text,
        voice: speakerVoice.forEmotion(line.emotion),
      );
      if (turn != _turn || _disposed) return;
      await audio.play(clip);
      if (turn != _turn || _disposed) return;
      _setPhase(AssistantPhase.idle);
    } catch (error) {
      if (turn != _turn || _disposed) return;
      _fail('$error');
    }
  }

  /// Recent turns plus the new question.
  ///
  /// Trimmed to the last few exchanges: this is a voice assistant, the
  /// endpoint is metered, and nobody refers back twenty turns by speech.
  List<Map<String, String>> _messages(String question, EmotionDirector? director) {
    final instruction = StringBuffer(
      AssistantIdentity.systemPrompt(language.displayName),
    );
    if (director != null) {
      instruction
        ..write(' ')
        ..write(director.instruction);
    }

    final recent = _history.length <= 7
        ? _history
        : _history.sublist(_history.length - 7);

    return [
      {'role': 'system', 'content': instruction.toString()},
      for (final line in recent.take(recent.length - 1))
        {'role': line.speaker ? 'assistant' : 'user', 'content': line.text},
      {'role': 'user', 'content': question},
    ];
  }

  void _fail(String message) {
    _error = message;
    _setPhase(AssistantPhase.failed);
  }

  void _setPhase(AssistantPhase phase) {
    _phase = phase;
    if (phase != AssistantPhase.listening) _level = 0;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    if (_phase == AssistantPhase.failed) _setPhase(AssistantPhase.idle);
  }

  void setLanguage(AssistantLanguage value) {
    language = value;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _turn++; // abandons anything still in flight
    speech.cancel();
    audio.stop();
    super.dispose();
  }
}

/// The two languages this build listens and answers in.
enum AssistantLanguage {
  english('English', 'en_US', 'EN-US'),
  hindi('Hindi', 'hi_IN', 'HI-IN');

  const AssistantLanguage(this.displayName, this.sttLocale, this.voiceLocale);

  /// Shown on the toggle and named in the system prompt.
  final String displayName;

  /// Underscored, as the platform recogniser expects.
  final String sttLocale;

  /// Upper-cased, as Magpie voice names spell it.
  final String voiceLocale;

  String get shortLabel => this == AssistantLanguage.hindi ? 'हिं' : 'EN';
}
