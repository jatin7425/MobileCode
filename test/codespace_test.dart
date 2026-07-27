import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/features/codespaces/codespace.dart';

void main() {
  group('state parsing', () {
    test('maps the states we act on', () {
      expect(CodespaceState.parse('Available'), CodespaceState.available);
      expect(CodespaceState.parse('Shutdown'), CodespaceState.shutdown);
      expect(CodespaceState.parse('Starting'), CodespaceState.starting);
      expect(CodespaceState.parse('Provisioning'), CodespaceState.provisioning);
    });

    test('folds the queueing states into starting', () {
      // These all mean "wait", and the UI should not need to know the
      // difference between them.
      expect(CodespaceState.parse('Queued'), CodespaceState.starting);
      expect(CodespaceState.parse('Awaiting'), CodespaceState.starting);
    });

    test('degrades unknown states instead of throwing', () {
      // GitHub adds states over time; an unrecognised one must not crash the
      // list, it just is not connectable.
      expect(CodespaceState.parse('SomeFutureState'), CodespaceState.other);
      expect(CodespaceState.parse(null), CodespaceState.other);
      expect(CodespaceState.other.isRunning, isFalse);
      expect(CodespaceState.other.isResumable, isFalse);
    });

    test('only Available counts as connectable', () {
      expect(CodespaceState.available.isRunning, isTrue);
      expect(CodespaceState.starting.isRunning, isFalse);
      expect(CodespaceState.shutdown.isResumable, isTrue);
      expect(CodespaceState.available.isResumable, isFalse);
    });
  });

  group('forwarded port URL', () {
    const codespace = Codespace(
      name: 'jatin7425-mobilecode-9q4x7v',
      displayName: 'literate space parakeet',
      state: CodespaceState.available,
      repository: 'jatin7425/MobileCode',
    );

    test('derives the documented hostname pattern', () {
      // There is no API to look this up — the derived hostname is the lookup.
      expect(
        codespace.forwardedPortUrl(2222).toString(),
        'https://jatin7425-mobilecode-9q4x7v-2222.app.github.dev',
      );
    });

    test('uses https so the socket layer upgrades it to wss', () {
      expect(codespace.forwardedPortUrl(2222).scheme, 'https');
    });
  });

  group('json', () {
    test('reads a codespace payload', () {
      final codespace = Codespace.fromJson(const {
        'name': 'jatin7425-mobilecode-9q4x7v',
        'display_name': 'literate space parakeet',
        'state': 'Available',
        'repository': {'full_name': 'jatin7425/MobileCode'},
        'machine': {'display_name': '2 cores'},
      });

      expect(codespace.name, 'jatin7425-mobilecode-9q4x7v');
      expect(codespace.displayName, 'literate space parakeet');
      expect(codespace.state, CodespaceState.available);
      expect(codespace.repository, 'jatin7425/MobileCode');
      expect(codespace.machine, '2 cores');
    });

    test('falls back when optional fields are absent', () {
      final codespace = Codespace.fromJson(const {
        'name': 'solo',
        'state': 'Shutdown',
      });

      expect(codespace.displayName, 'solo');
      expect(codespace.repository, 'unknown');
      expect(codespace.machine, isNull);
    });
  });
}
