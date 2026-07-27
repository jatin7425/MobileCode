import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/features/voice/nvcf_voice_client.dart';
import 'package:mobilecode/features/voice/voice_catalog.dart';
import 'package:mobilecode/features/voice/voice_id.dart';

/// Names copied from a live `list_voices` response, so the parser is tested
/// against what the endpoint actually returns rather than what the docs say.
const _live = [
  'Magpie-Multilingual.HI-IN.Phung.Neutral',
  'Magpie-Multilingual.HI-IN.Phung.Angry',
  'Magpie-Multilingual.HI-IN.Phung.Disgusted',
  'Magpie-Multilingual.HI-IN.Phung.Fearful',
  'Magpie-Multilingual.HI-IN.Phung.Happy',
  'Magpie-Multilingual.HI-IN.Phung.Sad',
  'Magpie-Multilingual.HI-IN.Jason.Neutral',
  'Magpie-Multilingual.EN-US.Jason.Neutral',
  'Magpie-Multilingual.EN-US.Jason.Happy',
];

void main() {
  group('VoiceId', () {
    test('splits a four-part Magpie name', () {
      final voice = VoiceId.parse('Magpie-Multilingual.HI-IN.Phung.Neutral');

      expect(voice.family, 'Magpie-Multilingual');
      expect(voice.locale, 'HI-IN');
      expect(voice.speaker, 'Phung');
      expect(voice.emotion, 'Neutral');
    });

    test('handles a name with no emotion segment', () {
      final voice = VoiceId.parse('Magpie-Multilingual.EN-US.Aria');

      expect(voice.speaker, 'Aria');
      expect(voice.emotion, isNull);
      expect(voice.withEmotion('Happy'), isNull,
          reason: 'a voice with no emotion segment cannot gain one');
    });

    test("keeps Riva's two-part built-in names usable", () {
      final voice = VoiceId.parse('English-US.Female-1');

      expect(voice.family, isEmpty);
      expect(voice.locale, 'English-US');
      expect(voice.speaker, 'Female-1');
    });

    test('round-trips the original string', () {
      for (final name in _live) {
        expect(VoiceId.parse(name).name, name);
      }
    });

    test('lower-cases the language and upper-cases the region', () {
      expect(VoiceId.parse('Magpie-Multilingual.HI-IN.Phung.Sad').languageCode,
          'hi-IN');
      expect(VoiceId.parse('Magpie-Multilingual.EN-US.Jason.Happy').languageCode,
          'en-US');
    });

    test('rebuilds the full name when swapping emotion', () {
      final angry = VoiceId.parse('Magpie-Multilingual.HI-IN.Phung.Neutral')
          .withEmotion('Angry');

      expect(angry!.name, 'Magpie-Multilingual.HI-IN.Phung.Angry');
    });
  });

  group('VoiceCatalog', () {
    test('collapses emotional variants into one speaker', () {
      final catalog = VoiceCatalog.fromNames(_live);

      // Phung ×6, Jason HI-IN ×1, Jason EN-US ×2 => three speakers.
      expect(catalog.speakers, hasLength(3));
      expect(catalog.voiceCount, _live.length);
    });

    test('treats the same speaker in two locales as two entries', () {
      final catalog = VoiceCatalog.fromNames(_live);

      expect(catalog.inLocale('HI-IN').map((s) => s.speaker),
          containsAll(['Phung', 'Jason']));
      expect(catalog.inLocale('EN-US').map((s) => s.speaker), ['Jason']);
    });

    test('puts Neutral first and sorts the rest', () {
      final phung = VoiceCatalog.fromNames(_live)
          .byKey('Magpie-Multilingual.HI-IN.Phung')!;

      expect(phung.emotions,
          ['Neutral', 'Angry', 'Disgusted', 'Fearful', 'Happy', 'Sad']);
    });

    test('falls back to the default voice for a mood a speaker lacks', () {
      final jason = VoiceCatalog.fromNames(_live)
          .byKey('Magpie-Multilingual.HI-IN.Jason')!;

      // Jason has only Neutral in Hindi; asking for Angry must still yield a
      // usable voice rather than nothing to say.
      expect(jason.forEmotion('Angry').name,
          'Magpie-Multilingual.HI-IN.Jason.Neutral');
    });

    test('sorts locales for a stable picker', () {
      expect(VoiceCatalog.fromNames(_live).locales, ['EN-US', 'HI-IN']);
    });

    test('ignores blank entries', () {
      expect(VoiceCatalog.fromNames(['', '   ']).isEmpty, isTrue);
    });
  });

  group('parseVoiceNames', () {
    test('reads a bare array', () {
      expect(parseVoiceNames(jsonDecode('["A.B.C.D","A.B.C.E"]')), hasLength(2));
    });

    test('reads voices nested under a key', () {
      final json = jsonDecode('{"voices":["Magpie-Multilingual.HI-IN.Phung.Sad"]}');

      expect(parseVoiceNames(json), ['Magpie-Multilingual.HI-IN.Phung.Sad']);
    });

    test('reads an array of objects', () {
      final json = jsonDecode(
        '[{"name":"Magpie-Multilingual.EN-US.Jason.Happy","gender":"male"}]',
      );

      expect(parseVoiceNames(json), ['Magpie-Multilingual.EN-US.Jason.Happy']);
    });

    test('reads a map keyed by locale', () {
      final json = jsonDecode(
        '{"hi-IN":["Magpie-Multilingual.HI-IN.Phung.Sad"],'
        '"en-US":["Magpie-Multilingual.EN-US.Jason.Happy"]}',
      );

      expect(parseVoiceNames(json), hasLength(2));
    });

    test('drops metadata that is not a voice name', () {
      final json = jsonDecode(
        '{"model":"magpie","version":"2602",'
        '"voices":["Magpie-Multilingual.HI-IN.Phung.Sad"]}',
      );

      // "magpie" and "2602" have no dot; a language tag like "hi-IN" has none
      // either. Only the dotted name survives.
      expect(parseVoiceNames(json), ['Magpie-Multilingual.HI-IN.Phung.Sad']);
    });

    test('de-duplicates a name that appears twice', () {
      final json = jsonDecode(
        '{"a":["X.Y.Z.W"],"b":["X.Y.Z.W"]}',
      );

      expect(parseVoiceNames(json), hasLength(1));
    });
  });

  group('wrapPcmAsWav', () {
    test('prefixes a 44-byte RIFF header onto raw PCM', () {
      final pcm = Uint8List.fromList([1, 2, 3, 4]);

      final wav = wrapPcmAsWav(pcm, sampleRateHz: 44100);

      expect(wav.length, 44 + pcm.length);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(wav.sublist(44), pcm);
    });

    test('leaves audio that already has a header alone', () {
      final wav = wrapPcmAsWav(Uint8List.fromList([1, 2, 3, 4]));

      // A second pass must not stack another header on the first.
      expect(wrapPcmAsWav(wav), same(wav));
    });

    test('writes the sample rate the caller asked for', () {
      final wav = wrapPcmAsWav(Uint8List.fromList([0, 0]), sampleRateHz: 22050);

      // Bytes 24..27 are the sample rate, little-endian.
      final rate = wav[24] | (wav[25] << 8) | (wav[26] << 16) | (wav[27] << 24);
      expect(rate, 22050);
    });

    test('declares mono 16-bit PCM', () {
      final wav = wrapPcmAsWav(Uint8List.fromList([0, 0]));

      expect(wav[20] | (wav[21] << 8), 1, reason: 'format tag 1 = PCM');
      expect(wav[22] | (wav[23] << 8), 1, reason: 'one channel');
      expect(wav[34] | (wav[35] << 8), 16, reason: '16 bits per sample');
    });
  });
}
