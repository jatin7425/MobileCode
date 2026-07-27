import 'package:mobilecode/core/shell.dart';

/// How we authenticate to a host.
enum SshAuthMethod { password, privateKey }

/// A remote machine the user can connect to.
///
/// This record is *not* secret and lives in the local database. The password
/// or private key it refers to lives in the platform secure store, addressed
/// by [credentialRef]; secret bytes never touch this class.
class HostConfig {
  const HostConfig({
    required this.id,
    required this.label,
    required this.hostname,
    required this.username,
    this.port = 22,
    this.authMethod = SshAuthMethod.privateKey,
    this.credentialRef,
    this.defaultWorkingDirectory,
  });

  final String id;

  /// Display name, e.g. "work laptop".
  final String label;
  final String hostname;
  final int port;
  final String username;
  final SshAuthMethod authMethod;

  /// Key into the secure credential store. Never the secret itself.
  final String? credentialRef;

  /// Directory new sessions start in. Defaults to the login directory.
  final String? defaultWorkingDirectory;

  String get displayAddress =>
      port == 22 ? '$username@$hostname' : '$username@$hostname:$port';

  /// Quoted `cd` target for new sessions, or null to stay in the login dir.
  String? get quotedWorkingDirectory {
    final dir = defaultWorkingDirectory;
    return (dir == null || dir.isEmpty) ? null : shellQuote(dir);
  }

  HostConfig copyWith({
    String? label,
    String? hostname,
    int? port,
    String? username,
    SshAuthMethod? authMethod,
    String? credentialRef,
    String? defaultWorkingDirectory,
  }) {
    return HostConfig(
      id: id,
      label: label ?? this.label,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      credentialRef: credentialRef ?? this.credentialRef,
      defaultWorkingDirectory:
          defaultWorkingDirectory ?? this.defaultWorkingDirectory,
    );
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'label': label,
        'hostname': hostname,
        'port': port,
        'username': username,
        'auth_method': authMethod.name,
        'credential_ref': credentialRef,
        'working_directory': defaultWorkingDirectory,
      };

  factory HostConfig.fromRow(Map<String, Object?> row) => HostConfig(
        id: row['id']! as String,
        label: row['label']! as String,
        hostname: row['hostname']! as String,
        port: row['port']! as int,
        username: row['username']! as String,
        authMethod: SshAuthMethod.values.byName(row['auth_method']! as String),
        credentialRef: row['credential_ref'] as String?,
        defaultWorkingDirectory: row['working_directory'] as String?,
      );
}
