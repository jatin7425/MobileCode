import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Storage for material that must never appear in the app database, logs, or
/// a backup: SSH private keys, host passwords, provider API keys, OAuth
/// tokens.
abstract class CredentialStore {
  Future<void> write(String ref, String secret);
  Future<String?> read(String ref);
  Future<void> delete(String ref);

  /// Reference for a host's password or private key.
  static String hostCredentialRef(String hostId) => 'host.$hostId.credential';

  /// Reference for a host key's passphrase, stored separately so the key can
  /// be read for display without unlocking the passphrase.
  static String hostPassphraseRef(String hostId) => 'host.$hostId.passphrase';

  /// Reference for a provider API key, e.g. `agent.claude.apiKey`.
  static String agentApiKeyRef(String agentId) => 'agent.$agentId.apiKey';

  /// Reference for the GitHub OAuth token.
  static const githubTokenRef = 'github.token';
}

/// Platform-backed implementation: iOS Keychain, Android Keystore.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore()
      : _storage = const FlutterSecureStorage(
          iOptions: IOSOptions(
            // Device-only, and only while unlocked. Without this the Keychain
            // may sync entries to iCloud and include them in encrypted
            // backups — an SSH private key silently replicating to the user's
            // other devices is not what they agreed to when they pasted it in.
            accessibility: KeychainAccessibility.unlocked_this_device,
            synchronizable: false,
          ),
          aOptions: AndroidOptions(
            // AES-GCM content encryption under a Keystore-wrapped key.
            resetOnError: false,
          ),
        );

  SecureCredentialStore.withStorage(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String ref, String secret) =>
      _storage.write(key: ref, value: secret);

  @override
  Future<String?> read(String ref) => _storage.read(key: ref);

  @override
  Future<void> delete(String ref) => _storage.delete(key: ref);
}

/// In-memory store for tests and previews. Never use in a shipped build.
class InMemoryCredentialStore implements CredentialStore {
  final _values = <String, String>{};

  @override
  Future<void> write(String ref, String secret) async => _values[ref] = secret;

  @override
  Future<String?> read(String ref) async => _values[ref];

  @override
  Future<void> delete(String ref) async => _values.remove(ref);
}
