import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/data/db/known_host_repository.dart';
import 'package:mobilecode/data/models/known_host.dart';
import 'package:mobilecode/features/ssh/host_key_verifier.dart';

Uint8List fingerprint(String value) =>
    Uint8List.fromList(utf8.encode('SHA256:$value'));

void main() {
  late InMemoryKnownHostRepository knownHosts;

  setUp(() => knownHosts = InMemoryKnownHostRepository());

  HostKeyVerifier verifierWith(HostKeyPrompt prompt) => HostKeyVerifier(
        hostId: 'host-1',
        knownHosts: knownHosts,
        onUnknownKey: prompt,
      );

  test('pins the key when the user trusts a first-seen host', () async {
    var prompted = 0;
    final verifier = verifierWith((_) async {
      prompted++;
      return HostKeyDecision.trust;
    });

    expect(
      await verifier.verify('ssh-ed25519', fingerprint('abc')),
      isTrue,
    );
    expect(prompted, 1);

    final pinned = await knownHosts.find('host-1');
    expect(pinned?.fingerprint, 'SHA256:abc');
    expect(pinned?.keyType, 'ssh-ed25519');
  });

  test('rejects and pins nothing when the user declines', () async {
    final verifier = verifierWith((_) async => HostKeyDecision.reject);

    expect(await verifier.verify('ssh-ed25519', fingerprint('abc')), isFalse);
    expect(await knownHosts.find('host-1'), isNull);
  });

  test('accepts a matching pinned key without prompting again', () async {
    await knownHosts.pin(
      KnownHost(
        hostId: 'host-1',
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:abc',
        firstSeen: DateTime.utc(2026),
      ),
    );

    final verifier = verifierWith(
      (_) async => fail('must not prompt for an already-trusted key'),
    );

    expect(await verifier.verify('ssh-ed25519', fingerprint('abc')), isTrue);
  });

  test('refuses a changed key and does not ask the user to override',
      () async {
    await knownHosts.pin(
      KnownHost(
        hostId: 'host-1',
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:abc',
        firstSeen: DateTime.utc(2026),
      ),
    );

    // A mismatch is either a rebuilt host or an interception. Prompting here
    // would train users to click through the one warning that matters.
    final verifier = verifierWith(
      (_) async => fail('must not offer a trust prompt on mismatch'),
    );

    expect(await verifier.verify('ssh-ed25519', fingerprint('evil')), isFalse);
    expect(verifier.mismatch, isNotNull);
    expect(verifier.mismatch!.expected, 'SHA256:abc');
    expect(verifier.mismatch!.actual, 'SHA256:evil');

    // The original pin survives, so the next honest connection still works.
    expect((await knownHosts.find('host-1'))!.fingerprint, 'SHA256:abc');
  });
}
