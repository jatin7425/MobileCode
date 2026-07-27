import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/data/models/host.dart';
import 'package:mobilecode/features/agents/agent_spec.dart';
import 'package:mobilecode/features/hosts/host_form_screen.dart';
import 'package:mobilecode/features/terminal/terminal_screen.dart';

class HostsScreen extends ConsumerWidget {
  const HostsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('MobileCode')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addHost(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add host'),
      ),
      body: hosts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (hosts) => hosts.isEmpty
            ? const _EmptyState()
            : ListView.builder(
                itemCount: hosts.length,
                itemBuilder: (context, index) => _HostTile(host: hosts[index]),
              ),
      ),
    );
  }

  Future<void> _addHost(BuildContext context, WidgetRef ref) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const HostFormScreen()),
    );
    if (saved ?? false) ref.invalidate(hostsProvider);
  }
}

class _HostTile extends ConsumerWidget {
  const _HostTile({required this.host});

  final HostConfig host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.dns_outlined),
      title: Text(host.label),
      subtitle: Text(host.displayAddress),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _pickAgent(context, ref),
    );
  }

  Future<void> _pickAgent(BuildContext context, WidgetRef ref) async {
    final agent = await showModalBottomSheet<_AgentChoice>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final agent in AgentRegistry.all)
              ListTile(
                leading: const Icon(Icons.auto_awesome_outlined),
                title: Text(agent.displayName),
                onTap: () =>
                    Navigator.pop(context, _AgentChoice(agent)),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.terminal),
              title: const Text('Plain shell'),
              onTap: () => Navigator.pop(context, const _AgentChoice(null)),
            ),
          ],
        ),
      ),
    );

    if (agent == null || !context.mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TerminalScreen(
          host: host,
          transport: ref.read(sshTransportProvider),
          agent: agent.spec,
        ),
      ),
    );
  }
}

/// Wrapper so "plain shell" (a null spec) is distinguishable from a dismissed
/// sheet (a null result).
class _AgentChoice {
  const _AgentChoice(this.spec);
  final AgentSpec? spec;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              'Add the machine your code lives on',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'A dev box, a VPS, or your laptop — anything you can reach over '
              'SSH. Install tmux on it so agents keep working while your '
              'phone is locked.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
