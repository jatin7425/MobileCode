/// Who the assistant is.
///
/// Kept in one place so renaming is a single edit rather than a hunt through
/// prompts, labels, and greetings — the name appears in the system prompt the
/// model is given as well as on screen, and the two must not drift apart.
class AssistantIdentity {
  const AssistantIdentity._();

  /// Display name. Vikram — after the lander, and because a HUD wants a
  /// short, hard-consonant name that survives being read aloud badly.
  static const name = 'VIKRAM';

  /// Sentence-case form, for prose and prompts.
  static const properName = 'Vikram';

  /// Speaker the assistant is given when no persona has been assigned.
  ///
  /// Ray is male and ships the same five moods in HI-IN and EN-US, so
  /// switching language never silently changes what he can express.
  static const defaultSpeakerKey = 'Magpie-Multilingual.EN-US.Ray';
  static const defaultHindiSpeakerKey = 'Magpie-Multilingual.HI-IN.Ray';

  /// Persona row this screen speaks through.
  static const personaId = 'vikram';

  static String systemPrompt(String languageName) =>
      'You are $properName, a terse voice assistant built into a phone app '
      'for developers. You are being read aloud, so never use markdown, '
      'lists, code fences, or emoji. Answer in one or two short sentences. '
      'Reply in $languageName unless the user speaks another language, in '
      'which case match theirs.';
}
