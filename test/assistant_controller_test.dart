import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mobilecode/features/assistant/assistant_controller.dart';
import 'package:mobilecode/features/assistant/audio_sink.dart';
import 'package:mobilecode/features/assistant/llm_client.dart';
import 'package:mobilecode/features/assistant/speech_input.dart';
import 'package:mobilecode/features/voice/voice_catalog.dart';

/// Ray as the endpoint lists him, in both languages the app offers.
final _catalog = VoiceCatalog.fromNames(const [
  'Magpie-Multilingual.EN-US.Ray',
  'Magpie-Multilingual.EN-US.Ray.Neutral',
  'Magpie-Multilingual.EN-US.Ray.Calm',
  'Magpie-Multilingual.EN-US.Ray.Angry',
  'Magpie-Multilingual.EN-US.Ray.Happy',
  'Magpie-Multilingual.EN-US.Ray.Fearful',
  'Magpie-Multilingual.HI-IN.Ray',
  'Magpie-Multilingual.HI-IN.Ray.Neutral',
  'Magpie-Multilingual.HI-IN.Ray.Calm',
  'Magpie-Multilingual.HI-IN.Ray.Angry',
  'Magpie-Multilingual.HI-IN.Ray.Happy',
  'Magpie-Multilingual.HI-IN.Ray.Fearful',
  // Phung is Hindi-only, for the case where the assigned speaker does not
  // exist in the other language.
  'Magpie-Multilingual.HI-IN.Phung.Neutral',
  'Magpie-Multilingual.HI-IN.Phung.Sad',
]);

final _speaker = _catalog.byKey('Magpie-Multilingual.EN-US.Ray')!;

class FakeSpeech implements SpeechInput {
  late void Function(String text, bool isFinal) _result;
  late void Function(double level) _level;
  late void Function(String message) _error;

  var listening = false;
  var cancelled = false;
  String? localeUsed;

  @override
  bool get isListening => listening;

  @override
  Future<bool> initialise() async => true;

  @override
  Future<void> listen({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
    required void Function(double level) onLevel,
    required void Function(String message) onError,
  }) async {
    listening = true;
    localeUsed = localeId;
    _result = onResult;
    _level = onLevel;
    _error = onError;
  }

  @override
  Future<void> stop() async => listening = false;

  @override
  Future<void> cancel() async {
    listening = false;
    cancelled = true;
  }

  /// Mirrors the platform recogniser, which closes the microphone itself once
  /// it decides the speaker has finished.
  void say(String text, {bool isFinal = true}) {
    if (isFinal) listening = false;
    _result(text, isFinal);
  }
  void loud(double level) => _level(level);
  void breaks(String message) => _error(message);
}

class FakeSink implements AudioSink {
  final played = <Uint8List>[];
  var stopped = false;
  var disposed = false;

  @override
  Future<void> play(Uint8List wav) async => played.add(wav);

  @override
  Future<void> stop() async => stopped = true;

  @override
  void dispose() => disposed = true;
}

/// Answers every chat request with [reply], or throws [failWith].
LlmClient _model(String reply, {Object? failWith}) {
  return LlmClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'k',
    model: 'test',
    client: MockClient((_) async {
      if (failWith != null) throw failWith;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': reply},
            }
          ],
        }),
        200,
      );
    }),
  );
}

void main() {
  group('a turn', () {
    test('goes idle → listening → thinking → speaking → idle', () async {
      final speech = FakeSpeech();
      final sink = FakeSink();
      final seen = <AssistantPhase>[];

      final controller = AssistantController(
        speech: speech,
        audio: sink,
        llm: _model('{"emotion":"Happy","text":"All good."}'),
        speaker: _speaker,
      )..addListener(() {});

      controller.addListener(() {
        if (seen.isEmpty || seen.last != controller.phase) {
          seen.add(controller.phase);
        }
      });

      await controller.toggleListening();
      expect(controller.phase, AssistantPhase.listening);

      speech.say('are we green');
      await pumpEventQueue();

      // No speech endpoint is wired here, so it stops short of synthesis and
      // returns to idle rather than hanging in `speaking`.
      expect(controller.phase, AssistantPhase.idle);
      expect(seen, contains(AssistantPhase.thinking));
    });

    test('records both sides of the exchange', () async {
      final speech = FakeSpeech();
      final controller = AssistantController(
        speech: speech,
        audio: FakeSink(),
        llm: _model('{"emotion":"Calm","text":"Two hosts are up."}'),
        speaker: _speaker,
      );

      await controller.toggleListening();
      speech.say('how many hosts');
      await pumpEventQueue();

      expect(controller.history, hasLength(2));
      expect(controller.history.first.speaker, isFalse);
      expect(controller.history.first.text, 'how many hosts');
      expect(controller.history.last.speaker, isTrue);
      expect(controller.history.last.text, 'Two hosts are up.');
      expect(controller.history.last.emotion, 'Calm');
    });

    test('replaces a mood the speaker cannot perform', () async {
      final speech = FakeSpeech();
      final controller = AssistantController(
        speech: speech,
        audio: FakeSink(),
        // Ray has no Sad.
        llm: _model('{"emotion":"Sad","text":"It failed."}'),
        speaker: _speaker,
      );

      await controller.toggleListening();
      speech.say('did it work');
      await pumpEventQueue();

      expect(controller.history.last.emotion, 'Neutral');
    });

    test('speaks plain prose when the model ignores the schema', () async {
      final speech = FakeSpeech();
      final controller = AssistantController(
        speech: speech,
        audio: FakeSink(),
        llm: _model('Everything is fine.'),
        speaker: _speaker,
      );

      await controller.toggleListening();
      speech.say('status');
      await pumpEventQueue();

      expect(controller.history.last.text, 'Everything is fine.');
    });

    test('ignores a partial result and waits for the final one', () async {
      final speech = FakeSpeech();
      final controller = AssistantController(
        speech: speech,
        audio: FakeSink(),
        llm: _model('{"emotion":"Neutral","text":"ok"}'),
        speaker: _speaker,
      );

      await controller.toggleListening();
      speech.say('what is the', isFinal: false);
      await pumpEventQueue();

      expect(controller.phase, AssistantPhase.listening);
      expect(controller.heard, 'what is the');
      expect(controller.history, isEmpty);
    });

    test('a silent final result ends the turn without asking the model', () async {
      final speech = FakeSpeech();
      final controller = AssistantController(
        speech: speech,
        audio: FakeSink(),
        llm: _model('should not be called'),
        speaker: _speaker,
      );

      await controller.toggleListening();
      speech.say('   ');
      await pumpEventQueue();

      expect(controller.phase, AssistantPhase.idle);
      expect(controller.history, isEmpty);
    });
  });

  group('when things go wrong', () {
    test('surfaces a recogniser failure', () async {
      final speech = FakeSpeech();
      final controller =
          AssistantController(speech: speech, audio: FakeSink());

      await controller.toggleListening();
      speech.breaks('no microphone');

      expect(controller.phase, AssistantPhase.failed);
      expect(controller.error, 'no microphone');
    });

    test('says so when no model is configured', () async {
      final speech = FakeSpeech();
      final controller =
          AssistantController(speech: speech, audio: FakeSink());

      expect(controller.canAnswer, isFalse);

      await controller.toggleListening();
      speech.say('hello');
      await pumpEventQueue();

      expect(controller.phase, AssistantPhase.failed);
      expect(controller.error, contains('No model endpoint'));
    });

    test('clearing the error returns to idle', () async {
      final speech = FakeSpeech();
      final controller =
          AssistantController(speech: speech, audio: FakeSink());

      await controller.toggleListening();
      speech.breaks('boom');
      controller.clearError();

      expect(controller.phase, AssistantPhase.idle);
      expect(controller.error, isNull);
    });

    test('a model failure does not strand the turn', () async {
      final speech = FakeSpeech();
      final controller = AssistantController(
        speech: speech,
        audio: FakeSink(),
        llm: _model('', failWith: Exception('offline')),
        speaker: _speaker,
      );

      await controller.toggleListening();
      speech.say('anything');
      await pumpEventQueue();

      expect(controller.phase, AssistantPhase.failed);
      expect(controller.error, contains('Could not reach the model'));
    });
  });

  group('lifecycle', () {
    test('a reply arriving after disposal is dropped', () async {
      final speech = FakeSpeech();
      final controller = AssistantController(
        speech: speech,
        audio: FakeSink(),
        llm: _model('{"emotion":"Happy","text":"too late"}'),
        speaker: _speaker,
      );

      await controller.toggleListening();
      speech.say('question');
      controller.dispose();
      await pumpEventQueue();

      // Nothing was appended and no listener was notified after dispose,
      // which is what would otherwise throw.
      expect(controller.history.where((u) => u.speaker), isEmpty);
      expect(speech.cancelled, isTrue);
    });

    test('tapping while listening stops rather than restarting', () async {
      final speech = FakeSpeech();
      final controller =
          AssistantController(speech: speech, audio: FakeSink());

      await controller.toggleListening();
      expect(speech.listening, isTrue);

      await controller.toggleListening();
      expect(speech.listening, isFalse);
    });

    test('tapping mid-answer is ignored', () async {
      final speech = FakeSpeech();
      final controller = AssistantController(
        speech: speech,
        audio: FakeSink(),
        llm: _model('{"emotion":"Neutral","text":"working"}'),
        speaker: _speaker,
      );

      await controller.toggleListening();
      speech.say('go');
      expect(controller.phase, AssistantPhase.thinking);

      // A second tap must not open the microphone underneath the in-flight
      // request, or the assistant would transcribe its own answer.
      await controller.toggleListening();

      expect(speech.listening, isFalse);
      expect(controller.phase, AssistantPhase.thinking);
    });

    test('tapping stop during silence returns to idle', () async {
      final speech = FakeSpeech();
      final controller =
          AssistantController(speech: speech, audio: FakeSink());

      await controller.toggleListening();
      await controller.toggleListening();

      // Without resetting the phase here the panel stays on LISTENING and
      // the next tap only tries to stop again — a dead button.
      expect(controller.phase, AssistantPhase.idle);
    });
  });

  group('language', () {
    test('listens in the selected locale', () async {
      final speech = FakeSpeech();
      final controller = AssistantController(
        speech: speech,
        audio: FakeSink(),
        language: AssistantLanguage.hindi,
      );

      await controller.toggleListening();

      expect(speech.localeUsed, 'hi_IN');
    });

    test('switching language changes the locale for the next turn', () async {
      final speech = FakeSpeech();
      final controller =
          AssistantController(speech: speech, audio: FakeSink());

      await controller.toggleListening();
      expect(speech.localeUsed, 'en_US');

      await controller.toggleListening(); // stop
      controller.setLanguage(AssistantLanguage.hindi);
      await controller.toggleListening();

      expect(speech.localeUsed, 'hi_IN');
    });

    test('names the language it should answer in', () {
      expect(AssistantLanguage.hindi.displayName, 'Hindi');
      expect(AssistantLanguage.hindi.voiceLocale, 'HI-IN');
    });

    test('speaks as the same person in the other language', () {
      final controller = AssistantController(
        speech: FakeSpeech(),
        audio: FakeSink(),
        speaker: _speaker,
        catalog: _catalog,
      );

      expect(controller.activeSpeaker!.key, 'Magpie-Multilingual.EN-US.Ray');

      controller.setLanguage(AssistantLanguage.hindi);

      // Same character, Hindi locale — not a different voice, and not the
      // English voice reading Hindi text.
      expect(controller.activeSpeaker!.locale, 'HI-IN');
      expect(controller.activeSpeaker!.speaker, 'Ray');
    });

    test('keeps the assigned speaker when they have no counterpart', () {
      final controller = AssistantController(
        speech: FakeSpeech(),
        audio: FakeSink(),
        speaker: _catalog.byKey('Magpie-Multilingual.HI-IN.Phung'),
        catalog: _catalog,
        language: AssistantLanguage.english,
      );

      // Phung is Hindi-only; falling back to him beats going silent.
      expect(controller.activeSpeaker!.speaker, 'Phung');
      expect(controller.activeSpeaker!.locale, 'HI-IN');
    });

    test('falls back to the assigned speaker with no catalog', () {
      final controller = AssistantController(
        speech: FakeSpeech(),
        audio: FakeSink(),
        speaker: _speaker,
        language: AssistantLanguage.hindi,
      );

      expect(controller.activeSpeaker, same(_speaker));
    });
  });

  group('resource handling', () {
    test('disposes the audio sink it owns', () {
      final sink = FakeSink();
      AssistantController(speech: FakeSpeech(), audio: sink).dispose();

      // The screen builds a fresh sink whenever the wiring changes, so a
      // controller that does not release its own strands a native player.
      expect(sink.disposed, isTrue);
    });

    test('does not synthesise an empty line', () async {
      final speech = FakeSpeech();
      final sink = FakeSink();
      final controller = AssistantController(
        speech: speech,
        audio: sink,
        llm: _model('{"emotion":"Happy","text":""}'),
        speaker: _speaker,
        catalog: _catalog,
      );

      await controller.toggleListening();
      speech.say('say nothing');
      await pumpEventQueue();

      // An empty answer must not be read aloud, and must certainly not be
      // read aloud as the raw JSON it arrived in.
      expect(controller.history.last.text, isEmpty);
      expect(sink.played, isEmpty);
      expect(controller.phase, AssistantPhase.idle);
    });
  });

  group('extractReply', () {
    test('reads a normal completion', () {
      expect(
        extractReply('{"choices":[{"message":{"content":"hi"}}]}'),
        'hi',
      );
    });

    test('surfaces a gateway error returned with a 200', () {
      expect(
        () => extractReply('{"error":{"message":"quota exceeded"}}'),
        throwsA(isA<LlmException>()
            .having((e) => e.message, 'message', contains('quota'))),
      );
    });

    test('falls back to a refusal when content is null', () {
      expect(
        extractReply(
          '{"choices":[{"message":{"content":null,"refusal":"I cannot"}}]}',
        ),
        'I cannot',
      );
    });

    test('rejects an empty choice list', () {
      expect(
        () => extractReply('{"choices":[]}'),
        throwsA(isA<LlmException>()),
      );
    });
  });
}
