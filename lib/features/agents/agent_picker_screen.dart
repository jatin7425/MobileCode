import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/data/models/host.dart';
import 'package:mobilecode/features/agents/agent_probe.dart';
import 'package:mobilecode/features/agents/agent_spec.dart';
import 'package:mobilecode/features/ssh/ssh_transport.dart';
import 'package:mobilecode/features/terminal/terminal_screen.dart';

enum _PickerStatus { connecting, ready, failed }

/// Connects to a host, asks which agents it has, and launches one.
///
/// The connection opened here is handed to the terminal rather than closed,
/// so choosing an agent does not cost a second handshake — or a second
/// passphrase prompt.
class AgentPickerScreen extends ConsumerStatefulWidget {
  const AgentPickerScreen({super.key, required this.host});

  final HostConfig host;

  @override
  ConsumerState<AgentPickerScreen> createState() => _AgentPickerScreenState();
}

class _AgentPickerScreenState extends ConsumerState<AgentPickerScreen> {
  static const _probe = AgentProbe();

  var _status = _PickerStatus.connecting;
  AgentAvailability _availability = AgentAvailability.unknown;
  SshConnection? _connection;
  String? _error;

  /// Set once the connection belongs to the terminal, so disposing this
  /// screen does not tear down a session the user just started.
  var _handedOff = false;

  @override
  void initState() {
    super.initState();
    _connectAndProbe();
  }

  @override
  void dispose() {
    if (!_handedOff) _connection?.close();
    super.dispose();
  }

  Future<void> _connectAndProbe() async {
    setState(() {
      _status = _PickerStatus.connecting;
      _error = null;
    });

    try {
      final connection =
          await ref.read(sshTransportProvider).connect(widget.host);
      final availability = _probe.parse(await connection.run(_probe.command));
      if (!mounted) {
        await connection.close();
        return;
      }
      setState(() {
        _connection = connection;
        _availability = availability;
        _status = _PickerStatus.ready;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _status = _PickerStatus.failed;
      });
    }
  }

  void _launch(AgentSpec? agent) {
    final connection = _connection;
    if (connection == null) return;
    _handedOff = true;

    // Replace rather than push: the picker has given away its connection and
    // has nothing left to show if the user comes back to it.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => TerminalScreen(
          host: widget.host,
          transport: ref.read(sshTransportProvider),
          connection: connection,
          agent: agent,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.host.label),
        bottom: _status == _PickerStatus.connecting
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: switch (_status) {
        _PickerStatus.connecting => Center(
            child: Text('Connecting to ${widget.host.displayAddress}…'),
          ),
        _PickerStatus.failed => _FailureView(
            message: _error ?? 'Could not connect.',
            onRetry: _connectAndProbe,
          ),
        _PickerStatus.ready => _agentList(),
      },
    );
  }

  Widget _agentList() {
    final installed = _availability.installedFrom(AgentRegistry.all);

    return ListView(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: [
        if (installed.isEmpty) const _NoAgentsNotice(),
        for (final agent in AgentRegistry.all)
          ListTile(
            enabled: _availability.has(agent),
            leading: Icon(
              _availability.has(agent)
                  ? Icons.auto_awesome_outlined
                  : Icons.remove_circle_outline,
            ),
            title: Text(agent.displayName),
            subtitle: Text(
              _availability.has(agent)
                  ? agent.binary
                  : 'Not installed on this host',
            ),
            onTap: _availability.has(agent) ? () => _launch(agent) : null,
          ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.terminal),
          title: const Text('Plain shell'),
          subtitle: const Text('No agent, just a terminal'),
          onTap: () => _launch(null),
        ),
      ],
    );
  }
}

class _NoAgentsNotice extends StatelessWidget {
  const _NoAgentsNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(16),
      child: Text(
        'No agent CLIs found. The check runs through a login shell, so this '
        'reflects what you would get by logging in — if an agent works when '
        'you SSH in yourself but is missing here, its PATH is probably set in '
        'a file only interactive shells read, such as ~/.bashrc.',
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}

class _FailureView extends StatelessWidget {
  const _FailureView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
