import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/features/agents/agent_probe.dart';
import 'package:mobilecode/features/agents/agent_spec.dart';

void main() {
  const probe = AgentProbe();

  group('probe command', () {
    test('runs through a login shell', () {
      // sshd runs one-shot commands in a non-login shell, so nvm's PATH setup
      // in ~/.profile never happens. Without -l the probe reports "missing"
      // for agents that work fine when the user logs in.
      expect(probe.command, contains('-lc'));
      expect(probe.command, contains(r'${SHELL:-/bin/sh}'));
    });

    test('asks about every registered agent', () {
      for (final agent in AgentRegistry.all) {
        expect(probe.command, contains("'${agent.binary}'"));
      }
    });

    test('quotes binaries and suppresses probe noise', () {
      expect(probe.command, contains('>/dev/null 2>&1'));
    });
  });

  group('parsing', () {
    test('reads a mixed result', () {
      final result = probe.parse('claude:yes\ncodex:no\ngemini:yes\n');
      expect(result.has(AgentRegistry.claude), isTrue);
      expect(result.has(AgentRegistry.codex), isFalse);
      expect(result.has(AgentRegistry.gemini), isTrue);
    });

    test('ignores login banners and MOTD around the output', () {
      // A login shell may print anything before our lines; none of it should
      // become a bogus availability result.
      const output = '''
Welcome to Ubuntu 24.04 LTS
Last login: Mon Jul 27 09:14:02 2026 from 10.0.0.4
* Documentation:  https://help.ubuntu.com
claude:yes
codex:no
gemini:no
''';
      final result = probe.parse(output);
      expect(result.installedIds, {'claude'});
    });

    test('ignores binaries we never asked about', () {
      final result = probe.parse('claude:yes\nrm:yes\n');
      expect(result.installedIds, {'claude'});
    });

    test('treats an empty or failed probe as nothing installed', () {
      expect(probe.parse('').isEmpty, isTrue);
      expect(probe.parse('bash: line 1: syntax error').isEmpty, isTrue);
    });

    test('tolerates carriage returns from a PTY-ish channel', () {
      final result = probe.parse('claude:yes\r\ncodex:yes\r\n');
      expect(result.installedIds, {'claude', 'codex'});
    });

    test('installedFrom preserves registry order', () {
      final result = probe.parse('gemini:yes\nclaude:yes\n');
      expect(
        result.installedFrom(AgentRegistry.all).map((a) => a.id),
        ['claude', 'gemini'],
      );
    });
  });
}
