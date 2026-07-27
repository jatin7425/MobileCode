import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/data/models/host.dart';
import 'package:mobilecode/data/secure/credential_store.dart';
import 'package:mobilecode/features/agents/agent_picker_screen.dart';
import 'package:mobilecode/features/codespaces/codespace.dart';
import 'package:mobilecode/features/github/github_auth.dart';

/// Port the bridge listens on inside the Codespace. Must match
/// `tools/codespace-bridge.sh`.
const codespaceBridgePort = 2224;

class CodespacesScreen extends ConsumerWidget {
  const CodespacesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(githubAuthProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Codespaces'),
        actions: [
          if (auth.status == GithubAuthStatus.signedIn)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(codespacesProvider),
            ),
        ],
      ),
      body: switch (auth.status) {
        GithubAuthStatus.signedIn => const _CodespaceList(),
        _ => const _SignIn(),
      },
    );
  }
}

class _SignIn extends ConsumerWidget {
  const _SignIn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(githubAuthProvider);
    final theme = Theme.of(context);

    if (!auth.isConfigured) {
      return const _Notice(
        icon: Icons.settings_outlined,
        title: 'No GitHub client id',
        body: 'This build has no GITHUB_CLIENT_ID. Register a GitHub OAuth '
            'App with device flow enabled and rebuild with '
            '--dart-define=GITHUB_CLIENT_ID=… — see the README.',
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (auth.status == GithubAuthStatus.awaitingUser &&
                auth.grant != null) ...[
              Text('Enter this code on GitHub',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              // Big and selectable: the user is reading this off one screen
              // and typing it into another.
              SelectableText(
                auth.grant!.userCode,
                style: theme.textTheme.displaySmall?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy code'),
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: auth.grant!.userCode),
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                auth.grant!.verificationUri,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text('Waiting for you to authorise…',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              TextButton(
                onPressed: ref.read(githubAuthProvider).cancel,
                child: const Text('Cancel'),
              ),
            ] else ...[
              const Icon(Icons.cloud_outlined, size: 48),
              const SizedBox(height: 16),
              Text('Connect GitHub', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Sign in to list your Codespaces and open a terminal on one.',
                textAlign: TextAlign.center,
              ),
              if (auth.errorMessage != null) ...[
                const SizedBox(height: 16),
                Text(
                  auth.errorMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: auth.status == GithubAuthStatus.requestingCode
                    ? null
                    : ref.read(githubAuthProvider).signIn,
                child: auth.status == GithubAuthStatus.requestingCode
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Sign in with GitHub'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CodespaceList extends ConsumerWidget {
  const _CodespaceList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final codespaces = ref.watch(codespacesProvider);

    return codespaces.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _Notice(
        icon: Icons.error_outline,
        title: 'Could not list Codespaces',
        body: '$error',
      ),
      data: (list) => list.isEmpty
          ? const _Notice(
              icon: Icons.cloud_off_outlined,
              title: 'No Codespaces',
              body: 'Create one on github.com and it will appear here.',
            )
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(codespacesProvider),
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) => _CodespaceTile(list[i]),
              ),
            ),
    );
  }
}

class _CodespaceTile extends ConsumerWidget {
  const _CodespaceTile(this.codespace);

  final Codespace codespace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = codespace.state.isRunning;

    return ListTile(
      leading: Icon(
        running ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
      ),
      title: Text(codespace.displayName),
      subtitle: Text(
        '${codespace.repository} · ${_stateLabel(codespace.state)}'
        '${codespace.machine == null ? '' : ' · ${codespace.machine}'}',
      ),
      trailing: switch (codespace.state) {
        CodespaceState.shutdown => TextButton(
            onPressed: () => _start(context, ref),
            child: const Text('Start'),
          ),
        CodespaceState.available => const Icon(Icons.chevron_right),
        _ => const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      },
      onTap: running ? () => _connect(context, ref) : null,
    );
  }

  String _stateLabel(CodespaceState state) => switch (state) {
        CodespaceState.available => 'Running',
        CodespaceState.shutdown => 'Stopped',
        CodespaceState.starting => 'Starting…',
        CodespaceState.provisioning => 'Provisioning…',
        CodespaceState.other => 'Unavailable',
      };

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final client = ref.read(codespacesClientProvider);
    if (client == null) return;
    final messenger = ScaffoldMessenger.of(context);

    try {
      await client.start(codespace.name);
      // Booting takes tens of seconds, so refreshing now shows "Starting"
      // rather than a machine that is ready.
      ref.invalidate(codespacesProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('Starting — pull to refresh in a moment')),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _connect(BuildContext context, WidgetRef ref) async {
    final key = await ref
        .read(credentialStoreProvider)
        .read(CredentialStore.codespaceKeyRef);

    if (!context.mounted) return;

    if (key == null || key.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('No Codespace key'),
          content: const Text(
            'Add a private key in Settings, run tools/codespace-bridge.sh '
            'inside the Codespace with its public half, and try again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    // A synthetic host: not saved to the host list, because Codespaces come
    // and go with GitHub rather than with the user. The id is stable across
    // rebuilds though, so host key pinning still catches a changed machine.
    final host = HostConfig(
      id: 'codespace:${codespace.name}',
      label: codespace.displayName,
      hostname: codespace.name,
      username: ref.read(codespaceUsernameProvider),
      credentialRef: CredentialStore.codespaceKeyRef,
      websocketUrl:
          codespace.forwardedPortUrl(codespaceBridgePort).toString(),
    );

    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AgentPickerScreen(host: host)),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
