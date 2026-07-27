/// A voice, spelled the way the Magpie TTS endpoint spells it.
///
///     Magpie-Multilingual.HI-IN.Phung.Neutral
///     └───── family ────┘ └lo─┘ └spk┘ └emotion┘
///
/// Riva's older built-in voices use a shorter form (`English-US.Female-1`),
/// and NVIDIA adds speakers, locales, and emotions between releases. So
/// parsing keeps [name] exactly as the API returned it and never discards a
/// voice it failed to understand: a voice the endpoint offers but the app
/// refuses to show is a bug the user has no way to work around.
class VoiceId {
  const VoiceId({
    required this.name,
    required this.family,
    required this.locale,
    required this.speaker,
    this.emotion,
  });

  /// Splits a dotted voice name into its parts.
  ///
  /// The last segment of a four-part name is taken as the emotion. That is
  /// positional rather than checked against a known list, because NVIDIA ships
  /// new emotions without notice and an unrecognised one should still appear
  /// in the picker.
  factory VoiceId.parse(String raw) {
    final name = raw.trim();
    final parts = name.split('.');

    if (parts.length >= 4) {
      return VoiceId(
        name: name,
        family: parts.first,
        locale: parts[1],
        speaker: parts.sublist(2, parts.length - 1).join('.'),
        emotion: parts.last,
      );
    }
    if (parts.length == 3) {
      return VoiceId(
        name: name,
        family: parts[0],
        locale: parts[1],
        speaker: parts[2],
      );
    }
    if (parts.length == 2) {
      // Riva built-ins: `English-US.Female-1`. No family, no emotion.
      return VoiceId(name: name, family: '', locale: parts[0], speaker: parts[1]);
    }
    return VoiceId(name: name, family: '', locale: '', speaker: name);
  }

  /// Exactly what the API returned. This is what goes back over the wire.
  final String name;

  /// e.g. `Magpie-Multilingual`. Empty for voices that carry no family.
  final String family;

  /// e.g. `HI-IN`. Empty when the name could not be split.
  final String locale;

  /// e.g. `Phung`.
  final String speaker;

  /// e.g. `Neutral`. Null for voices with no emotional variants.
  final String? emotion;

  /// Identifies the speaker independent of emotion, so all six emotional
  /// takes on one voice collapse to a single entry in the picker.
  String get speakerKey =>
      family.isEmpty ? '$locale.$speaker' : '$family.$locale.$speaker';

  /// The same speaker in a different mood, or null if this voice has no
  /// emotion segment to swap.
  VoiceId? withEmotion(String emotion) {
    if (this.emotion == null) return null;
    return VoiceId(
      name: '$family.$locale.$speaker.$emotion',
      family: family,
      locale: locale,
      speaker: speaker,
      emotion: emotion,
    );
  }

  /// The BCP-47-ish language tag the synthesize endpoint wants, derived from
  /// the locale segment: `HI-IN` becomes `hi-IN`.
  ///
  /// Riva's legacy voices carry a display name rather than a code in that
  /// position (`English-US.Female-1`), and reformatting one produces
  /// `english-US`, which the endpoint rejects. An ISO 639 language subtag is
  /// two or three letters, so anything longer is left alone.
  String get languageCode {
    final parts = locale.split('-');
    if (parts.length != 2 || parts[0].length > 3) return locale.toLowerCase();
    return '${parts[0].toLowerCase()}-${parts[1].toUpperCase()}';
  }

  /// The rate this voice's model actually renders at.
  ///
  /// Magpie renders at 22.05 kHz. Asking for a different rate and then
  /// stamping that number into the WAV header is only safe if the server
  /// resamples; if it returns native audio instead, the header misdescribes
  /// it and the clip plays at the wrong speed. Requesting the native rate is
  /// correct either way.
  int get nativeSampleRateHz =>
      family.startsWith('Magpie') ? 22050 : 44100;

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) => other is VoiceId && other.name == name;

  @override
  int get hashCode => name.hashCode;
}
