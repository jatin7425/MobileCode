import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/data/secure/credential_store.dart';
import 'package:mobilecode/features/github/github_auth.dart';
import 'package:mobilecode/features/ssh/ssh_keygen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _key = TextEditingController();
  final _username = TextEditingController();
  var _loaded = false;
  var _hasStoredKey = false;
  var _generating = false;
  String? _publicKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _key.dispose();
    _username.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final stored = await ref
        .read(credentialStoreProvider)
        .read(CredentialStore.codespaceKeyRef);
    if (!mounted) return;
    final pub = await ref
        .read(credentialStoreProvider)
        .read(CredentialStore.codespacePublicKeyRef);
    if (!mounted) return;
    final hasPrivate = stored != null && stored.isNotEmpty;
    setState(() {
      _hasStoredKey = hasPrivate;
      // Never show a public key whose private half is missing. Displaying one
      // implies a usable key and hides the Generate button behind
      // "Regenerate", while connecting fails with "no Codespace key".
      _publicKey = hasPrivate ? pub : null;
      _username.text = ref.read(codespaceUsernameProvider);
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(githubAuthProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('GitHub', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    auth.status == GithubAuthStatus.signedIn
                        ? Icons.check_circle_outline
                        : Icons.cancel_outlined,
                  ),
                  title: Text(
                    auth.status == GithubAuthStatus.signedIn
                        ? 'Signed in'
                        : 'Not signed in',
                  ),
                  trailing: auth.status == GithubAuthStatus.signedIn
                      ? TextButton(
                          onPressed: () async {
                            await ref.read(githubAuthProvider).signOut();
                            ref.invalidate(codespacesProvider);
                          },
                          child: const Text('Sign out'),
                        )
                      : null,
                ),

                const Divider(height: 32),
                Text('Codespaces', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'Generate a key here and the private half never leaves this '
                  'phone. Add the public half as a Codespaces secret named '
                  'MOBILECODE_PUBLIC_KEY and every Codespace configures '
                  'itself on start.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),

                if (_publicKey != null) ...[
                  Text('Public key', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  SelectableText(
                    _publicKey!,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy public key'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _publicKey!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Public key copied')),
                          );
                        },
                      ),
                      TextButton(
                        onPressed: _generating ? null : _generate,
                        child: const Text('Regenerate'),
                      ),
                    ],
                  ),
                ] else
                  FilledButton.icon(
                    icon: const Icon(Icons.vpn_key_outlined),
                    label: Text(
                      _generating ? 'Generating…' : 'Generate key on this phone',
                    ),
                    onPressed: _generating ? null : _generate,
                  ),

                const SizedBox(height: 16),

                TextField(
                  controller: _username,
                  decoration: const InputDecoration(
                    labelText: 'Username inside the Codespace',
                    helperText: 'Varies by image — the setup script prints it.',
                  ),
                  autocorrect: false,
                  onChanged: (value) => ref
                      .read(codespaceUsernameProvider.notifier)
                      .state = value.trim(),
                ),
                const SizedBox(height: 16),

                // Kept as an escape hatch for an existing key the user already
                // trusts on their machines. Generating is the better path, so
                // it is tucked away rather than presented first.
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    'Or paste an existing private key',
                    style: theme.textTheme.bodyMedium,
                  ),
                  children: [
                    TextField(
                      controller: _key,
                      decoration: InputDecoration(
                        labelText: 'Private key (PEM)',
                        helperText: _hasStoredKey
                            ? 'A key is stored. Paste a new one to replace it.'
                            : 'Stored in the device keychain, never uploaded.',
                      ),
                      maxLines: 5,
                      autocorrect: false,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton(
                          onPressed: _save,
                          child: const Text('Save'),
                        ),
                        const SizedBox(width: 12),
                        if (_hasStoredKey)
                          TextButton(
                            onPressed: _clear,
                            child: const Text('Remove key'),
                          ),
                      ],
                    ),
                  ],
                ),

                const Divider(height: 32),
                const _VersionLine(),
              ],
            ),
    );
  }

  /// Mints a key pair on the device. The private half goes straight into the
  /// keychain and is never displayed — only the public half is shown, because
  /// only the public half needs to travel.
  Future<void> _generate() async {
    setState(() => _generating = true);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final key = await const SshKeygen().generate();
      final credentials = ref.read(credentialStoreProvider);
      await credentials.write(
        CredentialStore.codespaceKeyRef,
        key.privateKeyPem,
      );
      await credentials.write(
        CredentialStore.codespacePublicKeyRef,
        key.publicKey,
      );

      if (!mounted) return;
      setState(() {
        _publicKey = key.publicKey;
        _hasStoredKey = true;
        _generating = false;
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Key generated on this device')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _generating = false);
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final pasted = _key.text.trim();

    if (pasted.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Paste a private key first')),
      );
      return;
    }

    // Public keys are what the user has just been copying around, so pasting
    // one here is the easy mistake. Storing it produces "that private key
    // could not be read" at connect time, far from the cause.
    if (pasted.startsWith('ssh-') || pasted.startsWith('ecdsa-')) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'That is a public key. This field wants the private half — the '
            'block beginning "-----BEGIN".',
          ),
        ),
      );
      return;
    }

    if (!pasted.contains('PRIVATE KEY')) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('That does not look like a private key.'),
        ),
      );
      return;
    }

    await ref
        .read(credentialStoreProvider)
        .write(CredentialStore.codespaceKeyRef, pasted);

    if (!mounted) return;
    setState(() {
      _hasStoredKey = true;
      _key.clear();
    });
    messenger.showSnackBar(const SnackBar(content: Text('Key saved')));
  }

  Future<void> _clear() async {
    // Both halves, or the display keeps showing a public key that no longer
    // has a private one behind it.
    final credentials = ref.read(credentialStoreProvider);
    await credentials.delete(CredentialStore.codespaceKeyRef);
    await credentials.delete(CredentialStore.codespacePublicKeyRef);
    if (!mounted) return;
    setState(() {
      _hasStoredKey = false;
      _publicKey = null;
    });
  }
}

/// Shows the installed version.
///
/// Worth having because APKs are sideloaded here rather than delivered by a
/// store: two builds look identical on the home screen, and the build number
/// is the only way to tell which CI run a phone is actually running.
class _VersionLine extends StatelessWidget {
  const _VersionLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Text(
          info == null
              ? 'MobileCode'
              : 'MobileCode ${info.version} (build ${info.buildNumber})',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        );
      },
    );
  }
}
