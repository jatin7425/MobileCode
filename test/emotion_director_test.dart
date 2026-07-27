import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/features/voice/emotion_director.dart';
import 'package:mobilecode/features/voice/voice_catalog.dart';

/// Real names from a live `list_voices` response. The emotion sets differ by
/// speaker on purpose — that difference is what this file exists to defend.
final _catalog = VoiceCatalog.fromNames(const [
  'Magpie-Multilingual.HI-IN.Ray',
  'Magpie-Multilingual.HI-IN.Ray.Neutral',
  'Magpie-Multilingual.HI-IN.Ray.Calm',
  'Magpie-Multilingual.HI-IN.Ray.Angry',
  'Magpie-Multilingual.HI-IN.Ray.Happy',
  'Magpie-Multilingual.HI-IN.Ray.Fearful',
  'Magpie-Multilingual.HI-IN.Phung.Neutral',
  'Magpie-Multilingual.HI-IN.Phung.Sad',
  'Magpie-Multilingual.EN-US.Solo',
]);

EmotionDirector _for(String key) =>
    EmotionDirector(_catalog.byKey(key)!);

void main() {
  final ray = _for('Magpie-Multilingual.HI-IN.Ray');
  final phung = _for('Magpie-Multilingual.HI-IN.Phung');
  final solo = _for('Magpie-Multilingual.EN-US.Solo');

  group('allowed set', () {
    test('is the speaker\'s own moods, not a fixed list', () {
      expect(ray.allowed, ['Neutral', 'Angry', 'Calm', 'Fearful', 'Happy']);
      expect(phung.allowed, ['Neutral', 'Sad']);
    });

    test('is empty for a speaker with no emotional variants', () {
      expect(solo.allowed, isEmpty);
      expect(solo.fallback, isNull);
    });
  });

  group('responseFormat', () {
    test('constrains emotion to an enum of this speaker\'s moods', () {
      final schema = ray.responseFormat()['json_schema'] as Map<String, Object?>;
      final properties =
          (schema['schema'] as Map)['properties'] as Map<String, Object?>;
      final emotion = properties['emotion'] as Map<String, Object?>;

      expect(emotion['enum'], ray.allowed);
      expect((schema['schema'] as Map)['required'], ['emotion', 'text']);
      expect(schema['strict'], isTrue);
    });

    test('omits emotion entirely when the speaker has none', () {
      final schema = solo.responseFormat()['json_schema'] as Map<String, Object?>;
      final inner = schema['schema'] as Map<String, Object?>;

      expect((inner['properties'] as Map).containsKey('emotion'), isFalse);
      expect(inner['required'], ['text']);
    });

    test('forbids extra keys so the reply stays parseable', () {
      final schema = ray.responseFormat()['json_schema'] as Map<String, Object?>;

      expect((schema['schema'] as Map)['additionalProperties'], isFalse);
    });
  });

  group('instruction', () {
    test('names every allowed mood', () {
      for (final mood in ray.allowed) {
        expect(ray.instruction, contains(mood));
      }
    });

    test('never offers a mood the speaker lacks', () {
      // Phung has no Calm; the prompt must not suggest it.
      expect(phung.instruction, isNot(contains('Calm')));
    });
  });

  group('parse', () {
    test('accepts a clean reply', () {
      final line = ray.parse('{"emotion":"Happy","text":"Build passed."}');

      expect(line.emotion, 'Happy');
      expect(line.text, 'Build passed.');
      expect(line.clamped, isFalse);
    });

    test('replaces a mood the speaker cannot perform', () {
      // Ray has no Sad. Passing it through would synthesise on a voice that
      // does not exist.
      final line = ray.parse('{"emotion":"Sad","text":"Build failed."}');

      expect(line.emotion, 'Neutral');
      expect(line.clamped, isTrue);
      expect(line.text, 'Build failed.');
    });

    test('matches regardless of capitalisation', () {
      final line = ray.parse('{"emotion":"happy","text":"Done."}');

      expect(line.emotion, 'Happy');
      expect(line.clamped, isFalse);
    });

    test('unwraps a fenced code block', () {
      final line = ray.parse('```json\n{"emotion":"Calm","text":"Ready."}\n```');

      expect(line.emotion, 'Calm');
      expect(line.text, 'Ready.');
    });

    test('finds JSON after a preamble', () {
      final line = ray.parse(
        'Sure! Here you go:\n{"emotion":"Angry","text":"It broke."}',
      );

      expect(line.emotion, 'Angry');
      expect(line.text, 'It broke.');
    });

    test('speaks a plain-text reply rather than dropping it', () {
      final line = ray.parse('The deploy finished.');

      expect(line.text, 'The deploy finished.');
      expect(line.emotion, 'Neutral');
    });

    test('falls back when emotion is missing', () {
      final line = ray.parse('{"text":"No mood given."}');

      expect(line.emotion, 'Neutral');
      expect(line.clamped, isFalse,
          reason: 'omitting a mood is not the same as asking for a bad one');
    });

    test('uses the whole reply when text is empty', () {
      final line = ray.parse('{"emotion":"Happy","text":""}');

      expect(line.text, isNotEmpty);
    });

    test('returns no emotion for a speaker that has none', () {
      final line = solo.parse('{"emotion":"Happy","text":"Hello."}');

      expect(line.emotion, isNull);
      expect(line.text, 'Hello.');
    });

    test('falls back to the first mood when Neutral is absent', () {
      final catalog = VoiceCatalog.fromNames(const [
        'Magpie-Multilingual.EN-US.Moody.Angry',
        'Magpie-Multilingual.EN-US.Moody.Happy',
      ]);
      final moody = EmotionDirector(
        catalog.byKey('Magpie-Multilingual.EN-US.Moody')!,
      );

      expect(moody.fallback, 'Angry');
      expect(moody.parse('{"emotion":"Sad","text":"x"}').emotion, 'Angry');
    });
  });
}
