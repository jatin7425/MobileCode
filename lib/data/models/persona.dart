import 'package:mobilecode/features/voice/voice_catalog.dart';
import 'package:mobilecode/features/voice/voice_id.dart';

/// A named character the app speaks as.
///
/// A persona owns a *speaker*, not a voice name. The endpoint ships six
/// emotional takes on each speaker, and which one to use is a property of the
/// moment — a failed deploy should sound different from a finished one —
/// not of the character. So the persona stores who is talking and the caller
/// picks the mood at speech time.
class Persona {
  const Persona({
    required this.id,
    required this.name,
    this.role = '',
    this.voiceKey,
    this.defaultEmotion = 'Neutral',
  });

  final String id;

  /// What the user calls this persona, e.g. "Jarvis".
  final String name;

  /// One line on what it is for, e.g. "build and deploy status".
  final String role;

  /// [VoiceSpeaker.key] of the assigned speaker, or null when unassigned.
  /// Stored as the key rather than a full voice name so the assignment
  /// survives NVIDIA adding or removing emotional variants.
  final String? voiceKey;

  /// Mood this persona speaks in unless the caller asks for another.
  final String defaultEmotion;

  bool get hasVoice => voiceKey != null && voiceKey!.isNotEmpty;

  /// Resolves to a concrete voice against a catalog, or null when the
  /// assigned speaker is not in it — which happens when the endpoint changes
  /// or the persona was assigned against a different function.
  VoiceId? resolve(VoiceCatalog catalog, {String? emotion}) =>
      catalog.byKey(voiceKey)?.forEmotion(emotion ?? defaultEmotion);

  Persona copyWith({
    String? name,
    String? role,
    String? voiceKey,
    String? defaultEmotion,
  }) {
    return Persona(
      id: id,
      name: name ?? this.name,
      role: role ?? this.role,
      voiceKey: voiceKey ?? this.voiceKey,
      defaultEmotion: defaultEmotion ?? this.defaultEmotion,
    );
  }

  /// Clears the voice assignment. Separate from [copyWith] because that
  /// cannot express "set this back to null".
  Persona withoutVoice() =>
      Persona(id: id, name: name, role: role, defaultEmotion: defaultEmotion);

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'role': role,
        'voice_key': voiceKey,
        'default_emotion': defaultEmotion,
      };

  factory Persona.fromRow(Map<String, Object?> row) => Persona(
        id: row['id']! as String,
        name: row['name']! as String,
        role: (row['role'] as String?) ?? '',
        voiceKey: row['voice_key'] as String?,
        defaultEmotion: (row['default_emotion'] as String?) ?? 'Neutral',
      );

  /// Seeded on first run so the feature has something to show and the user
  /// can hear a voice before inventing a character of their own.
  ///
  /// The first entry is the one the assistant screen speaks through; its id
  /// must stay in step with `AssistantIdentity.personaId`.
  static const seeds = [
    Persona(id: 'vikram', name: 'Vikram', role: 'The assistant'),
    Persona(id: 'ops', name: 'Ops', role: 'Build and deploy status'),
    Persona(id: 'alert', name: 'Alert', role: 'Failures and warnings',
        defaultEmotion: 'Fearful'),
  ];
}
