@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/features/ssh/ssh_keygen.dart';

/// Checks the generated keys against real OpenSSH rather than against our own
/// idea of the format. A key that only our encoder agrees with is worthless —
/// the whole point is that `sshd` on a remote machine accepts it.
void main() {
  const keygen = SshKeygen();

  final hasSshKeygen = ['/usr/bin/ssh-keygen', '/bin/ssh-keygen']
      .any(FileSystemEntity.isFileSync);

  test('produces a private key OpenSSH can read', () async {
    final key = await keygen.generate();

    final dir = Directory.systemTemp.createTempSync('mobilecode-keygen');
    addTearDown(() => dir.deleteSync(recursive: true));

    final file = File('${dir.path}/id_ed25519')
      ..writeAsStringSync(key.privateKeyPem);
    // ssh-keygen refuses a world-readable private key.
    Process.runSync('chmod', ['600', file.path]);

    // -y derives the public key from the private one. It parses the full
    // container to do that, so success means our encoding is correct.
    final result = await Process.run('ssh-keygen', ['-y', '-f', file.path]);
    expect(
      result.exitCode,
      0,
      reason: 'ssh-keygen rejected the key: ${result.stderr}',
    );

    // And the derived key must match the public half we handed out — a
    // mismatch would mean authorized_keys gets a key that cannot authenticate.
    final derived = (result.stdout as String).trim().split(' ');
    final ours = key.publicKey.split(' ');
    expect(derived[0], ours[0]);
    expect(derived[1], ours[1]);
  }, skip: hasSshKeygen ? null : 'ssh-keygen not installed');

  test('produces a public key line fit for authorized_keys', () async {
    final key = await keygen.generate(comment: 'phone');
    final parts = key.publicKey.split(' ');

    expect(parts, hasLength(3));
    expect(parts[0], 'ssh-ed25519');
    expect(parts[2], 'phone');
    expect(key.publicKey, isNot(contains('\n')));
  });

  test('dartssh2 can load the key for authentication', () async {
    final key = await keygen.generate();
    // Our own client has to parse it too, not just OpenSSH.
    final pairs = SSHKeyPair.fromPem(key.privateKeyPem);
    expect(pairs, isNotEmpty);
    expect(pairs.first.type, 'ssh-ed25519');
  });

  test('generates a different key each time', () async {
    final a = await keygen.generate();
    final b = await keygen.generate();
    expect(a.publicKey, isNot(b.publicKey));
    expect(a.privateKeyPem, isNot(b.privateKeyPem));
  });

  test('emits a well-formed PEM envelope', () async {
    final key = await keygen.generate();
    final lines = key.privateKeyPem.trim().split('\n');
    expect(lines.first, '-----BEGIN OPENSSH PRIVATE KEY-----');
    expect(lines.last, '-----END OPENSSH PRIVATE KEY-----');
    // Body wrapped, as OpenSSH writes it.
    expect(lines[1].length, lessThanOrEqualTo(70));
  });
}
