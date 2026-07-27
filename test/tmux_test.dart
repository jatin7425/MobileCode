import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/core/shell.dart';
import 'package:mobilecode/features/agents/agent_spec.dart';
import 'package:mobilecode/features/ssh/tmux.dart';

void main() {
  group('shellQuote', () {
    test('quotes plain values', () {
      expect(shellQuote('hello'), "'hello'");
    });

    test('neutralises spaces and expansions', () {
      expect(shellQuote(r'~/my code/$HOME'), r"'~/my code/$HOME'");
    });

    test('escapes embedded single quotes', () {
      expect(shellQuote("it's"), r"'it'\''s'");
    });

    test('quotes the empty string to a real empty argument', () {
      expect(shellQuote(''), "''");
    });

    test('contains a command substitution attempt', () {
      // The point of quoting: this must arrive as literal text, not run.
      expect(shellQuote(r'$(rm -rf /)'), r"'$(rm -rf /)'");
    });
  });

  group('sessionName', () {
    test('prefixes and lowercases', () {
      expect(TmuxLauncher.sessionName('WorkLaptop'), 'mobilecode-worklaptop');
    });

    test('strips characters tmux treats as target separators', () {
      // `.` and `:` would make the session unaddressable as session:window.pane
      final name = TmuxLauncher.sessionName('web.example.com:2222');
      expect(name, isNot(contains('.')));
      expect(name, isNot(contains(':')));
      expect(name, 'mobilecode-web-example-com-2222');
    });

    test('collapses whitespace runs', () {
      expect(TmuxLauncher.sessionName('my   box'), 'mobilecode-my-box');
    });

    test('falls back to the bare prefix when nothing survives', () {
      expect(TmuxLauncher.sessionName('...'), 'mobilecode');
    });

    test('never leaves a trailing separator', () {
      expect(TmuxLauncher.sessionName('box.'), 'mobilecode-box');
    });
  });

  group('attachOrCreate', () {
    const launcher = TmuxLauncher();

    test('uses attach-or-create so reconnecting resumes the session', () {
      final command = launcher.attachOrCreate(name: 'mobilecode-box');
      expect(command, contains('new-session'));
      expect(command, contains('-A'));
      expect(command, contains("-s 'mobilecode-box'"));
    });

    test('quotes the working directory', () {
      final command = launcher.attachOrCreate(
        name: 'mobilecode-box',
        workingDirectory: '~/my code',
      );
      expect(command, contains("-c '~/my code'"));
    });

    test('leaves a shell behind when the agent exits', () {
      final command = launcher.attachOrCreate(
        name: 'mobilecode-box',
        agent: AgentRegistry.claude,
      );
      expect(command, contains("'claude'"));
      expect(command, contains(r'exec "$SHELL"'));
    });

    test('falls back to screen with reattach semantics', () {
      final command = launcher.attachOrCreate(
        name: 'mobilecode-box',
        multiplexer: MultiplexerKind.screen,
      );
      expect(command, startsWith('screen -D -R'));
    });

    test('returns an empty command for a bare shell with no multiplexer', () {
      final command = launcher.attachOrCreate(
        name: 'mobilecode-box',
        multiplexer: MultiplexerKind.none,
      );
      expect(command, isEmpty);
    });
  });

  group('parseDetectOutput', () {
    test('prefers tmux', () {
      expect(TmuxLauncher.parseDetectOutput('tmux\n'), MultiplexerKind.tmux);
    });

    test('recognises screen', () {
      expect(
        TmuxLauncher.parseDetectOutput(' screen \n'),
        MultiplexerKind.screen,
      );
    });

    test('treats anything unexpected as no multiplexer', () {
      expect(TmuxLauncher.parseDetectOutput('bash: tmux: not found'),
          MultiplexerKind.none);
      expect(MultiplexerKind.none.isDurable, isFalse);
      expect(MultiplexerKind.tmux.isDurable, isTrue);
    });
  });
}
