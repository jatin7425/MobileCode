import 'dart:convert';

import 'package:mobilecode/features/voice/voice_catalog.dart';

/// What the model said, and how it should be said.
class SpokenLine {
  const SpokenLine({
    required this.text,
    required this.emotion,
    this.clamped = false,
  });

  final String text;

  /// A mood the assigned speaker can actually perform, or null when the
  /// speaker ships no emotional variants at all.
  final String? emotion;

  /// True when the model asked for a mood this speaker does not have and it
  /// was replaced with the default. Worth surfacing in logs: a model that
  /// keeps asking for Sad on a speaker without it is a prompt problem, not a
  /// runtime one.
  final bool clamped;
}

/// Holds an LLM to the moods one speaker can actually perform.
///
/// Emotion sets are per speaker, not global — Ray has five, Phung six, Long
/// seven, and only some have Calm. A fixed enum would therefore ask for moods
/// that do not exist, and the synthesis call would quietly fall back to
/// Neutral, making the model look like it never emotes.
///
/// So the allowed set is derived from the catalog at request time and applied
/// twice: as a JSON schema the endpoint enforces, and again on the way back,
/// because not every model or proxy honours the schema.
class EmotionDirector {
  const EmotionDirector(this.speaker);

  final VoiceSpeaker speaker;

  List<String> get allowed => speaker.emotions;

  String? get fallback => allowed.isEmpty ? null : speaker.defaultEmotionName;

  /// An OpenAI-compatible `response_format`, which is what LiteLLM proxies.
  ///
  /// The enum is the whole point: it is the only part of this that the model
  /// is structurally prevented from violating.
  Map<String, Object?> responseFormat({String name = 'spoken_line'}) {
    final properties = <String, Object?>{
      'text': {
        'type': 'string',
        'description': 'What to say. Plain prose — it will be read aloud, so '
            'no markdown, code fences, or bullet characters.',
      },
    };
    if (allowed.isNotEmpty) {
      properties['emotion'] = {
        'type': 'string',
        'enum': allowed,
        'description': 'The tone to speak in.',
      };
    }

    return {
      'type': 'json_schema',
      'json_schema': {
        'name': name,
        'strict': true,
        'schema': {
          'type': 'object',
          'properties': properties,
          'required': [if (allowed.isNotEmpty) 'emotion', 'text'],
          'additionalProperties': false,
        },
      },
    };
  }

  /// System-prompt wording for models that ignore schemas, and for endpoints
  /// that do not support structured output at all.
  String get instruction {
    if (allowed.isEmpty) {
      return 'Reply as JSON: {"text": "<what to say>"}. The text is read '
          'aloud, so write plain prose with no markdown.';
    }
    return 'Reply as JSON: {"emotion": "<one of: ${allowed.join(', ')}>", '
        '"text": "<what to say>"}. Use exactly one of those emotion values — '
        'any other value will be discarded. The text is read aloud, so write '
        'plain prose with no markdown.';
  }

  /// Reads a reply, forcing the emotion into the allowed set.
  ///
  /// Deliberately forgiving about everything except the emotion: a model that
  /// wraps its JSON in a code fence or adds a sentence before it should still
  /// get its line spoken, but a mood the speaker cannot perform is never
  /// passed through.
  SpokenLine parse(String reply) {
    final decoded = _decodeObject(reply);

    if (decoded == null) {
      // No JSON at all — speak the whole reply rather than nothing.
      return SpokenLine(text: reply.trim(), emotion: fallback);
    }

    final text = decoded['text']?.toString().trim();
    final requested = decoded['emotion']?.toString().trim();

    return SpokenLine(
      text: (text == null || text.isEmpty) ? reply.trim() : text,
      emotion: _resolve(requested),
      clamped: allowed.isNotEmpty &&
          requested != null &&
          _match(requested) == null,
    );
  }

  String? _resolve(String? requested) {
    if (allowed.isEmpty) return null;
    if (requested == null || requested.isEmpty) return fallback;
    return _match(requested) ?? fallback;
  }

  /// Case-insensitive so `"happy"` matches `Happy` — models rarely reproduce
  /// the capitalisation, and rejecting on case alone would flatten every
  /// reply to the default.
  String? _match(String requested) {
    final needle = requested.toLowerCase();
    for (final emotion in allowed) {
      if (emotion.toLowerCase() == needle) return emotion;
    }
    return null;
  }

  /// Finds a JSON object in a reply that may be fenced or prefaced with prose.
  static Map<String, Object?>? _decodeObject(String reply) {
    final candidates = <String>[];
    final trimmed = reply.trim();
    candidates.add(trimmed);

    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(trimmed);
    if (fence != null) candidates.add(fence.group(1)!.trim());

    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start != -1 && end > start) {
      candidates.add(trimmed.substring(start, end + 1));
    }

    for (final candidate in candidates) {
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map) return decoded.cast<String, Object?>();
      } catch (_) {
        // Try the next shape.
      }
    }
    return null;
  }
}
