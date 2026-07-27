/// How an agent CLI on the remote host gets its credentials.
enum AgentAuthMode {
  /// The CLI is already logged in on the host (`claude login` and friends).
  /// Nothing sensitive touches the phone. This is the paved path.
  delegated,

  /// The app holds an API key and injects it into the session environment.
  /// See [AgentSpec.apiKeyEnvVar].
  apiKey,
}

/// Declarative description of a coding agent CLI.
///
/// Supporting a new agent should be a data change, not a code change — so
/// everything that varies between `claude`, `codex`, and `gemini` lives here
/// rather than in the session or terminal layers.
class AgentSpec {
  const AgentSpec({
    required this.id,
    required this.displayName,
    required this.binary,
    this.launchArgs = const [],
    this.apiKeyEnvVar,
    this.usesAlternateScreen = true,
  });

  final String id;
  final String displayName;

  /// Executable name, resolved on the host's `PATH`.
  final String binary;

  final List<String> launchArgs;

  /// Environment variable carrying the API key, when [AgentAuthMode.apiKey] is
  /// used. Null means the agent offers no key-based path we support.
  final String? apiKeyEnvVar;

  /// Whether the CLI paints a full-screen TUI on the alternate screen buffer.
  /// These need accurate terminal dimensions or they repaint into garbage.
  final bool usesAlternateScreen;

  bool get supportsApiKey => apiKeyEnvVar != null;
}

/// Agents we know how to launch.
class AgentRegistry {
  const AgentRegistry._();

  static const claude = AgentSpec(
    id: 'claude',
    displayName: 'Claude Code',
    binary: 'claude',
    apiKeyEnvVar: 'ANTHROPIC_API_KEY',
  );

  static const codex = AgentSpec(
    id: 'codex',
    displayName: 'Codex',
    binary: 'codex',
    apiKeyEnvVar: 'OPENAI_API_KEY',
  );

  static const gemini = AgentSpec(
    id: 'gemini',
    displayName: 'Gemini CLI',
    binary: 'gemini',
    apiKeyEnvVar: 'GEMINI_API_KEY',
  );

  static const all = <AgentSpec>[claude, codex, gemini];

  static AgentSpec? byId(String id) {
    for (final agent in all) {
      if (agent.id == id) return agent;
    }
    return null;
  }
}
