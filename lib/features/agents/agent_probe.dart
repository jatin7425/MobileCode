import 'dart:convert';

import 'package:mobilecode/core/shell.dart';
import 'package:mobilecode/features/agents/agent_spec.dart';

/// Which agents a host actually has installed.
class AgentAvailability {
  const AgentAvailability(this.installedIds);

  /// Ids of agents found on the host.
  final Set<String> installedIds;

  static const unknown = AgentAvailability(<String>{});

  bool has(AgentSpec agent) => installedIds.contains(agent.id);

  bool get isEmpty => installedIds.isEmpty;

  List<AgentSpec> installedFrom(List<AgentSpec> agents) =>
      agents.where(has).toList();
}

/// Asks a host which agent CLIs it has, in one round trip.
///
/// ## Why this runs through a login shell
///
/// sshd executes a one-shot command with the user's shell in **non-login,
/// non-interactive** mode, so `~/.profile`, `~/.bash_profile`, and
/// `~/.zprofile` are never sourced. Agent CLIs are commonly installed through
/// npm under nvm, whose `PATH` entry is set up in exactly those files. A bare
/// `command -v claude` would therefore report "not installed" on a machine
/// where `claude` works perfectly when the user logs in — the worst kind of
/// wrong answer, because it looks authoritative.
///
/// Running the probe as `$SHELL -lc` reproduces the environment the agent will
/// actually be launched in, which is the only environment whose answer means
/// anything.
class AgentProbe {
  const AgentProbe([this.agents = AgentRegistry.all]);

  final List<AgentSpec> agents;

  /// Emits one `binary:yes` or `binary:no` line per agent.
  String get command {
    final targets = agents.map((a) => shellQuote(a.binary)).join(' ');
    final script = 'for b in $targets; do '
        r'if command -v "$b" >/dev/null 2>&1; then echo "$b:yes"; '
        r'else echo "$b:no"; fi; '
        'done';
    // Fall back to /bin/sh for accounts with no SHELL set.
    const loginShell = r'${SHELL:-/bin/sh}';
    return '$loginShell -lc ${shellQuote(script)}';
  }

  /// Reads the probe output.
  ///
  /// Deliberately tolerant: a login shell may print a MOTD, a version banner,
  /// or a warning before our output, and none of that should turn into a
  /// bogus result. Only well-formed lines naming an agent we asked about
  /// count; everything else is ignored.
  AgentAvailability parse(String output) {
    final byBinary = {for (final agent in agents) agent.binary: agent};
    final pattern = RegExp(r'^(\S+):(yes|no)$');
    final installed = <String>{};

    for (final line in const LineSplitter().convert(output)) {
      final match = pattern.firstMatch(line.trim());
      if (match == null || match.group(2) != 'yes') continue;
      final agent = byBinary[match.group(1)];
      if (agent != null) installed.add(agent.id);
    }

    return AgentAvailability(installed);
  }
}
