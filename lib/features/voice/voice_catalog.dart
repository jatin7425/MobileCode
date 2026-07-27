import 'package:mobilecode/features/voice/voice_id.dart';

/// Every emotional take on one speaker, collapsed into a single entry.
///
/// The endpoint lists `Phung.Neutral`, `Phung.Angry`, `Phung.Sad` and three
/// more as six separate voices. Users do not pick a mood when they pick a
/// voice — they pick *who is talking*, and the mood is chosen later, per
/// utterance. So the picker offers speakers, not names.
class VoiceSpeaker {
  VoiceSpeaker._(this.family, this.locale, this.speaker, this._byEmotion);

  final String family;
  final String locale;
  final String speaker;
  final Map<String?, VoiceId> _byEmotion;

  String get key => family.isEmpty ? '$locale.$speaker' : '$family.$locale.$speaker';

  /// Neutral first — it is the default a persona speaks in — then the rest
  /// alphabetically so the list does not reshuffle between API responses.
  List<String> get emotions {
    final named = _byEmotion.keys.whereType<String>().toList()..sort();
    named.remove(_neutral);
    return [if (_byEmotion.containsKey(_neutral)) _neutral, ...named];
  }

  bool get hasEmotions => emotions.isNotEmpty;

  /// The voice to use for [emotion], falling back to this speaker's default
  /// when they have no take on that mood. Never returns null for a speaker
  /// that exists, so a persona set to Angry still speaks on a voice that only
  /// ships Neutral.
  VoiceId forEmotion(String? emotion) =>
      _byEmotion[emotion] ?? defaultVoice;

  VoiceId get defaultVoice =>
      _byEmotion[_neutral] ?? _byEmotion[null] ?? _byEmotion.values.first;

  String get languageCode => defaultVoice.languageCode;

  static const _neutral = 'Neutral';
}

/// The voices one endpoint offers, grouped for display.
class VoiceCatalog {
  VoiceCatalog._(this._speakers, this.voiceCount);

  factory VoiceCatalog.fromNames(Iterable<String> names) {
    final grouped = <String, Map<String?, VoiceId>>{};
    final order = <String, VoiceId>{};
    var count = 0;

    for (final raw in names) {
      if (raw.trim().isEmpty) continue;
      final voice = VoiceId.parse(raw);
      count++;
      grouped.putIfAbsent(voice.speakerKey, () => {})[voice.emotion] = voice;
      order.putIfAbsent(voice.speakerKey, () => voice);
    }

    final speakers = <VoiceSpeaker>[];
    for (final entry in grouped.entries) {
      final first = order[entry.key]!;
      speakers.add(
        VoiceSpeaker._(first.family, first.locale, first.speaker, entry.value),
      );
    }

    speakers.sort((a, b) {
      final byLocale = a.locale.compareTo(b.locale);
      return byLocale != 0 ? byLocale : a.speaker.compareTo(b.speaker);
    });

    return VoiceCatalog._(speakers, count);
  }

  final List<VoiceSpeaker> _speakers;

  /// How many individual voice names the endpoint returned, before grouping.
  final int voiceCount;

  List<VoiceSpeaker> get speakers => List.unmodifiable(_speakers);

  bool get isEmpty => _speakers.isEmpty;

  List<String> get locales {
    final seen = <String>{for (final s in _speakers) s.locale};
    return seen.toList()..sort();
  }

  List<VoiceSpeaker> inLocale(String locale) =>
      _speakers.where((s) => s.locale == locale).toList();

  VoiceSpeaker? byKey(String? key) {
    if (key == null) return null;
    for (final s in _speakers) {
      if (s.key == key) return s;
    }
    return null;
  }
}

/// Pulls voice names out of whatever shape `/v1/audio/list_voices` returns.
///
/// The response format is not documented and has changed between Riva
/// releases: it has been a bare array of strings, an object keyed by locale,
/// and an array of objects with a `name` field. Rather than pin one shape and
/// break on the next deploy, this walks the decoded JSON and collects every
/// string that looks like a voice name.
List<String> parseVoiceNames(Object? json) {
  final found = <String>[];
  final seen = <String>{};

  void walk(Object? node) {
    if (node is String) {
      final value = node.trim();
      // A voice name is dotted and has no spaces around the dots. This filters
      // out sibling metadata like language tags and model versions that share
      // the response.
      if (value.contains('.') && !value.contains(' ') && value.length > 3) {
        if (seen.add(value)) found.add(value);
      }
      return;
    }
    if (node is List) {
      for (final item in node) {
        walk(item);
      }
      return;
    }
    if (node is Map) {
      for (final entry in node.entries) {
        // Prefer explicit name fields, but still walk everything: a response
        // that nests voices under an undocumented key must not come back empty.
        walk(entry.value);
      }
    }
  }

  walk(json);
  return found;
}
