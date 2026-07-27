import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/data/secure/credential_store.dart';
import 'package:mobilecode/features/github/github_auth.dart';

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
    setState(() {
      _hasStoredKey = stored != null && stored.isNotEmpty;
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
                  'One key is shared by every Codespace: they are disposable '
                  'and numerous, and the setup script authorises a single '
                  'public key. Paste the private half here and give the '
                  'public half to tools/codespace-bridge.sh.',
                  style: theme.textTheme.bodySmall,
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
                const SizedBox(height: 16),

                Row(
                  children: [
                    FilledButton(onPressed: _save, child: const Text('Save')),
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
    );
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_key.text.trim().isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Paste a private key first')),
      );
      return;
    }

    await ref
        .read(credentialStoreProvider)
        .write(CredentialStore.codespaceKeyRef, _key.text.trim());

    if (!mounted) return;
    setState(() {
      _hasStoredKey = true;
      _key.clear();
    });
    messenger.showSnackBar(const SnackBar(content: Text('Key saved')));
  }

  Future<void> _clear() async {
    await ref
        .read(credentialStoreProvider)
        .delete(CredentialStore.codespaceKeyRef);
    if (!mounted) return;
    setState(() => _hasStoredKey = false);
  }
}
