/// Lifecycle state of a Codespace, as GitHub reports it.
enum CodespaceState {
  available,
  shutdown,
  starting,
  provisioning,
  /// Anything GitHub adds that we do not model yet.
  other;

  static CodespaceState parse(String? raw) => switch (raw) {
        'Available' => CodespaceState.available,
        'Shutdown' => CodespaceState.shutdown,
        'Starting' || 'Awaiting' || 'Queued' => CodespaceState.starting,
        'Provisioning' || 'Created' || 'Rebuilding' =>
          CodespaceState.provisioning,
        _ => CodespaceState.other,
      };

  /// Whether a connection could succeed right now.
  bool get isRunning => this == CodespaceState.available;

  /// Whether starting it is worth offering.
  bool get isResumable => this == CodespaceState.shutdown;
}

class Codespace {
  const Codespace({
    required this.name,
    required this.displayName,
    required this.state,
    required this.repository,
    this.machine,
  });

  /// GitHub's identifier, e.g. `jatin7425-mobilecode-9q4x7v`. This is also the
  /// hostname prefix for forwarded ports, so it is not merely cosmetic.
  final String name;

  final String displayName;
  final CodespaceState state;

  /// `owner/repo` this Codespace was created from.
  final String repository;

  final String? machine;

  /// URL of a forwarded port.
  ///
  /// Codespaces publishes forwarded ports at a derived hostname rather than
  /// through an API you can query, so this pattern *is* the lookup:
  /// `https://<codespace-name>-<port>.app.github.dev`.
  Uri forwardedPortUrl(int port) =>
      Uri.parse('https://$name-$port.app.github.dev');

  factory Codespace.fromJson(Map<String, dynamic> json) => Codespace(
        name: json['name'] as String,
        displayName: json['display_name'] as String? ??
            json['name'] as String,
        state: CodespaceState.parse(json['state'] as String?),
        repository:
            (json['repository'] as Map<String, dynamic>?)?['full_name']
                    as String? ??
                'unknown',
        machine: (json['machine'] as Map<String, dynamic>?)?['display_name']
            as String?,
      );
}
