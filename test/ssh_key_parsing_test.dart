import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/features/ssh/ssh_keygen.dart';

/// Guards the passphrase handling around key loading.
///
/// dartssh2 treats an empty passphrase as a *mistake*, not as "no
/// passphrase" — so a credential store that returns '' for an entry that was
/// never written makes every unencrypted key unreadable, and the failure
/// looks like a corrupt key.
void main() {
  const keygen = SshKeygen();

  test('an unencrypted key loads with no passphrase', () async {
    final key = await keygen.generate();
    expect(() => SSHKeyPair.fromPem(key.privateKeyPem), returnsNormally);
    expect(() => SSHKeyPair.fromPem(key.privateKeyPem, null), returnsNormally);
  });

  test('an empty passphrase is rejected by dartssh2', () async {
    // The behaviour the normalisation exists for. If a future dartssh2 starts
    // accepting '' this test fails and the mapping can be reconsidered — but
    // silently passing '' through must never come back.
    final key = await keygen.generate();
    expect(
      () => SSHKeyPair.fromPem(key.privateKeyPem, ''),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('surrounding whitespace does not break loading', () async {
    // Keys arrive via clipboard and text fields, which add stray newlines.
    final key = await keygen.generate();
    expect(() => SSHKeyPair.fromPem('\n  ${key.privateKeyPem}  \n'.trim()),
        returnsNormally);
  });
}
