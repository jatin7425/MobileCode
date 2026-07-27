/// A host key we have pinned for a given host, in the style of `known_hosts`.
class KnownHost {
  const KnownHost({
    required this.hostId,
    required this.keyType,
    required this.fingerprint,
    required this.firstSeen,
  });

  final String hostId;

  /// SSH host key algorithm, e.g. `ssh-ed25519`.
  final String keyType;

  /// OpenSSH-style fingerprint, `SHA256:<base64>`.
  final String fingerprint;

  final DateTime firstSeen;

  Map<String, Object?> toRow() => {
        'host_id': hostId,
        'key_type': keyType,
        'fingerprint': fingerprint,
        'first_seen': firstSeen.toUtc().millisecondsSinceEpoch,
      };

  factory KnownHost.fromRow(Map<String, Object?> row) => KnownHost(
        hostId: row['host_id']! as String,
        keyType: row['key_type']! as String,
        fingerprint: row['fingerprint']! as String,
        firstSeen: DateTime.fromMillisecondsSinceEpoch(
          row['first_seen']! as int,
          isUtc: true,
        ),
      );
}
