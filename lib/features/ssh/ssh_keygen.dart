import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A generated SSH key pair.
class GeneratedSshKey {
  const GeneratedSshKey({required this.privateKeyPem, required this.publicKey});

  /// OpenSSH private key, `-----BEGIN OPENSSH PRIVATE KEY-----`. Stays on the
  /// device.
  final String privateKeyPem;

  /// One-line `ssh-ed25519 AAAA… comment`, for `authorized_keys`.
  final String publicKey;
}

/// Generates Ed25519 keys in OpenSSH format, on the device.
///
/// The point is that the private half is never transmitted or displayed. The
/// alternative — generating on the remote machine and copying the private key
/// into the phone — puts the one secret that matters through a terminal, a
/// clipboard, and whatever app is used to ferry it. Generating locally means
/// only the *public* half ever travels, which is what public keys are for.
///
/// Ed25519 rather than RSA: keys are 32 bytes, generation is instant on a
/// phone where RSA-4096 would stall the UI, and the OpenSSH private key body
/// is simply the seed followed by the public key.
class SshKeygen {
  const SshKeygen();

  static const _keyType = 'ssh-ed25519';

  Future<GeneratedSshKey> generate({String comment = 'mobilecode'}) async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final seed = Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    final publicKey = Uint8List.fromList(
      (await keyPair.extractPublicKey()).bytes,
    );

    return GeneratedSshKey(
      privateKeyPem: _encodePrivateKey(seed, publicKey, comment),
      publicKey: _encodePublicKey(publicKey, comment),
    );
  }

  String _encodePublicKey(Uint8List publicKey, String comment) {
    final blob = _blob([_string(_keyType), _string(publicKey)]);
    return '$_keyType ${base64.encode(blob)} $comment';
  }

  /// Builds the `openssh-key-v1` container.
  ///
  /// Format is fixed: a magic string, then cipher/kdf fields (all "none" here,
  /// since we do not encrypt the key — the platform keychain is what protects
  /// it), the public key, and a private section that is checksummed by two
  /// identical random integers. OpenSSH uses those to detect a wrong
  /// passphrase; with no encryption they simply have to match.
  String _encodePrivateKey(
    Uint8List seed,
    Uint8List publicKey,
    String comment,
  ) {
    final publicBlob = _blob([_string(_keyType), _string(publicKey)]);

    final checkInt = Random.secure().nextInt(0xFFFFFFFF);
    final privatePart = <int>[
      ..._uint32(checkInt),
      ..._uint32(checkInt),
      ..._string(_keyType),
      ..._string(publicKey),
      // The Ed25519 "private key" here is seed followed by public key, which
      // is what OpenSSH stores and what signing implementations expect.
      ..._string(Uint8List.fromList([...seed, ...publicKey])),
      ..._string(comment),
    ];

    // Pad to the cipher block size with 1, 2, 3… For "none" the block size is
    // 8. OpenSSH rejects a key whose padding is not this exact sequence.
    for (var i = 1; privatePart.length % 8 != 0; i++) {
      privatePart.add(i);
    }

    final body = <int>[
      ...utf8.encode('openssh-key-v1'),
      0,
      ..._string('none'), // ciphername
      ..._string('none'), // kdfname
      ..._string(Uint8List(0)), // kdfoptions
      ..._uint32(1), // number of keys
      ..._string(publicBlob),
      ..._string(Uint8List.fromList(privatePart)),
    ];

    final encoded = base64.encode(body);
    final lines = <String>[];
    for (var i = 0; i < encoded.length; i += 70) {
      lines.add(encoded.substring(i, min(i + 70, encoded.length)));
    }

    return [
      '-----BEGIN OPENSSH PRIVATE KEY-----',
      ...lines,
      '-----END OPENSSH PRIVATE KEY-----',
      '',
    ].join('\n');
  }

  Uint8List _blob(List<List<int>> parts) =>
      Uint8List.fromList([for (final part in parts) ...part]);

  /// SSH wire format string: a big-endian length followed by the bytes.
  List<int> _string(Object value) {
    final bytes = value is String
        ? utf8.encode(value)
        : (value as List<int>);
    return [..._uint32(bytes.length), ...bytes];
  }

  List<int> _uint32(int value) =>
      [(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF];
}
