import 'package:mobilecode/core/shell.dart';
import 'package:mobilecode/features/agents/agent_spec.dart';

/// Which multiplexer we found on the host, if any.
enum MultiplexerKind {
  tmux,
  screen,

  /// Nothing available — the session dies with the connection.
  none;

  bool get isDurable => this != MultiplexerKind.none;
}

/// Builds the remote command lines that put every session inside a
/// multiplexer.
///
/// This is the mechanism that makes a direct phone-to-host connection usable.
/// iOS suspends a backgrounded app within seconds and tears down its sockets;
/// without a multiplexer the agent — a child of our SSH channel — dies with
/// it, potentially halfway through editing the user's files. Run it under tmux
/// instead and the agent is a child of the tmux server: the connection drops,
/// the work continues, and reattaching restores the scrollback and repaints
/// the TUI.
class TmuxLauncher {
  const TmuxLauncher();

  /// Prefix marking sessions this app owns, so we never list or reattach
  /// someone's unrelated work.
  static const sessionPrefix = 'mobilecode';

  /// Shell snippet that reports which multiplexer the host has.
  ///
  /// Prints one of `tmux`, `screen`, or `none`. Preference order matters:
  /// tmux has the better attach semantics and is what the rest of this class
  /// targets.
  static const detectCommand =
      'if command -v tmux >/dev/null 2>&1; then echo tmux; '
      'elif command -v screen >/dev/null 2>&1; then echo screen; '
      'else echo none; fi';

  static MultiplexerKind parseDetectOutput(String output) {
    switch (output.trim()) {
      case 'tmux':
        return MultiplexerKind.tmux;
      case 'screen':
        return MultiplexerKind.screen;
      default:
        return MultiplexerKind.none;
    }
  }

  /// Makes [raw] safe to use as a tmux session name.
  ///
  /// tmux treats `.` and `:` as separators in target specifiers like
  /// `session:window.pane`, so a name containing them is unaddressable.
  /// Whitespace survives quoting but makes every manual `tmux attach` on the
  /// host painful, so it goes too.
  static String sessionName(String raw) {
    final cleaned = raw
        .trim()
        .replaceAll(RegExp(r'[.:\s]+'), '-')
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '')
        .replaceAll(RegExp('-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return cleaned.isEmpty
        ? sessionPrefix
        : '$sessionPrefix-${cleaned.toLowerCase()}';
  }

  /// The command to run on the host to start or resume a session.
  ///
  /// `new-session -A` is attach-if-exists, create-otherwise, so the same
  /// command covers the first connection and every reconnect after it. When
  /// the session already exists tmux ignores [workingDirectory] and [agent]
  /// and simply attaches, which is what we want — reattaching must never
  /// relaunch an agent that is already running.
  String attachOrCreate({
    required String name,
    String? workingDirectory,
    AgentSpec? agent,
    MultiplexerKind multiplexer = MultiplexerKind.tmux,
  }) {
    switch (multiplexer) {
      case MultiplexerKind.tmux:
        final parts = <String>[
          'tmux',
          '-u', // force UTF-8; agent TUIs draw box-drawing characters
          'new-session',
          '-A',
          '-s',
          shellQuote(name),
        ];
        if (workingDirectory != null && workingDirectory.isNotEmpty) {
          parts..add('-c')..add(shellQuote(workingDirectory));
        }
        if (agent != null) {
          parts.add(_windowCommand(agent));
        }
        return parts.join(' ');

      case MultiplexerKind.screen:
        // -D -R: detach the session elsewhere if attached, then reattach,
        // creating it if absent. The closest screen gets to `new-session -A`.
        final parts = <String>['screen', '-D', '-R', shellQuote(name)];
        if (agent != null) {
          parts.add(_windowCommand(agent));
        }
        return parts.join(' ');

      case MultiplexerKind.none:
        // No durability available. Run the agent directly and let the caller
        // warn the user that the session dies with the connection.
        if (agent == null) return '';
        return _windowCommand(agent);
    }
  }

  /// Lists this app's sessions on the host, one `name<TAB>attached` per line.
  String listSessions() =>
      "tmux list-sessions -F '#{session_name}\t#{session_attached}' "
      '2>/dev/null | grep ${shellQuote('^$sessionPrefix')} || true';

  /// Ends a session and everything running inside it.
  String killSession(String name) =>
      'tmux kill-session -t ${shellQuote(name)} 2>/dev/null || true';

  /// Wraps the agent so quitting it leaves a login shell rather than ending
  /// the session — the user is still on the machine and usually wants to keep
  /// working there.
  String _windowCommand(AgentSpec agent) {
    final launch = shellJoin([agent.binary, ...agent.launchArgs]);
    return 'sh -lc ${shellQuote('$launch; exec "\$SHELL" -l')}';
  }
}
