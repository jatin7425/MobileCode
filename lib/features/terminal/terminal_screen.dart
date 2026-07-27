import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'package:mobilecode/data/models/host.dart';
import 'package:mobilecode/features/agents/agent_spec.dart';
import 'package:mobilecode/features/ssh/ssh_transport.dart';
import 'package:mobilecode/features/ssh/tmux.dart';
import 'package:mobilecode/features/terminal/accessory_bar.dart';
import 'package:mobilecode/features/terminal/session_controller.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.host,
    required this.transport,
    this.agent,
  });

  final HostConfig host;
  final SshTransport transport;
  final AgentSpec? agent;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with WidgetsBindingObserver {
  late final SessionController _controller;
  final _terminalController = TerminalController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _controller = SessionController(
      host: widget.host,
      transport: widget.transport,
      request: SessionRequest(
        // One session per host+agent pair, so returning to the same agent on
        // the same machine lands back in the work already in progress.
        sessionName: TmuxLauncher.sessionName(
          '${widget.host.label}-${widget.agent?.id ?? 'shell'}',
        ),
        agent: widget.agent,
      ),
    );
    _controller.connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // iOS would tear the socket down within seconds anyway. Detaching
        // deliberately keeps tmux holding the agent and stops us draining the
        // battery on a connection that is about to die.
        _controller.detach();
      case AppLifecycleState.resumed:
        _controller.reattach();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _terminalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 64,
            title: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.agent?.displayName ?? widget.host.label),
                Text(
                  _statusLine(),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              PopupMenuButton<_SessionAction>(
                onSelected: _onAction,
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: _SessionAction.detach,
                    child: Text('Detach (leave running)'),
                  ),
                  PopupMenuItem(
                    value: _SessionAction.terminate,
                    child: Text('End session'),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              if (_controller.isEphemeral) const _EphemeralBanner(),
              Expanded(child: _body()),
              if (_controller.status == SessionStatus.connected)
                AccessoryBar(controller: _controller),
            ],
          ),
        );
      },
    );
  }

  Widget _body() {
    switch (_controller.status) {
      case SessionStatus.idle:
      case SessionStatus.connecting:
        return const Center(child: CircularProgressIndicator());

      case SessionStatus.failed:
        return _ErrorView(
          message: _controller.errorMessage ?? 'Connection failed.',
          onRetry: _controller.connect,
        );

      case SessionStatus.detached:
        return _ErrorView(
          message: 'Detached. Your session is still running on '
              '${widget.host.label}.',
          retryLabel: 'Reattach',
          onRetry: _controller.reattach,
        );

      case SessionStatus.closed:
        return const _ErrorView(message: 'Session ended.');

      case SessionStatus.connected:
        return TerminalView(
          _controller.terminal,
          controller: _terminalController,
          autofocus: true,
          backgroundOpacity: 1,
          textStyle: const TerminalStyle(fontSize: 13),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        );
    }
  }

  String _statusLine() {
    switch (_controller.status) {
      case SessionStatus.connecting:
        return 'Connecting to ${widget.host.displayAddress}…';
      case SessionStatus.connected:
        return _controller.multiplexer.isDurable
            ? '${widget.host.displayAddress} · session persists'
            : widget.host.displayAddress;
      case SessionStatus.detached:
        return 'Detached · still running';
      case SessionStatus.closed:
        return 'Ended';
      case SessionStatus.failed:
        return 'Not connected';
      case SessionStatus.idle:
        return widget.host.displayAddress;
    }
  }

  Future<void> _onAction(_SessionAction action) async {
    switch (action) {
      case _SessionAction.detach:
        await _controller.detach();
      case _SessionAction.terminate:
        final confirmed = await _confirmTerminate();
        if (confirmed) await _controller.terminate();
    }
  }

  Future<bool> _confirmTerminate() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End this session?'),
        content: const Text(
          'This kills the remote session and anything running inside it, '
          'including work an agent has not finished. Detaching instead leaves '
          'it running.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End session'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

enum _SessionAction { detach, terminate }

class _EphemeralBanner extends StatelessWidget {
  const _EphemeralBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(
        'No tmux or screen on this host — this session ends if you leave the '
        'app. Install tmux to keep agents running in the background.',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onErrorContainer),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    this.onRetry,
    this.retryLabel = 'Retry',
  });

  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: Text(retryLabel)),
            ],
          ],
        ),
      ),
    );
  }
}
