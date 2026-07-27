import 'dart:convert';
import 'dart:typed_data';

import 'package:mobilecode/data/db/known_host_repository.dart';
import 'package:mobilecode/data/models/known_host.dart';

/// What the app should do about a host key it has not seen before.
enum HostKeyDecision { trust, reject }

/// Asks the user whether to trust a first-seen host key. Returning
/// [HostKeyDecision.reject] aborts the connection.
typedef HostKeyPrompt = Future<HostKeyDecision> Function(
  HostKeyFingerprint fingerprint,
);

/// A host key as offered during handshake.
class HostKeyFingerprint {
  const HostKeyFingerprint({required this.type, required this.value});

  /// Host key algorithm, e.g. `ssh-ed25519`.
  final String type;

  /// OpenSSH-style fingerprint, `SHA256:<base64>`.
  final String value;
}

/// Raised when a host presents a key that does not match the pinned one.
class HostKeyMismatch implements Exception {
  const HostKeyMismatch({
    required this.hostId,
    required this.expected,
    required this.actual,
  });

  final String hostId;
  final String expected;
  final String actual;

  @override
  String toString() =>
      'Host key mismatch for $hostId: pinned $expected, host offered $actual';
}

/// Trust-on-first-use host key verification.
///
/// The first time we connect to a host we show its fingerprint and pin the
/// user's answer. Every connection after that must present the same key.
///
/// There is deliberately no "connect anyway" path for a mismatch. A changed
/// host key means either the host was rebuilt or someone is sitting between
/// the phone and the machine — and in the second case, continuing hands them
/// every keystroke, the user's SSH key, and the contents of the repository. A
/// mismatch is resolved by the user deleting the pin explicitly, in settings,
/// having read what that means.
class HostKeyVerifier {
  HostKeyVerifier({
    required this.hostId,
    required this.knownHosts,
    required this.onUnknownKey,
  });

  final String hostId;
  final KnownHostRepository knownHosts;
  final HostKeyPrompt onUnknownKey;

  /// Set when verification failed because the key changed, so the connection
  /// layer can report the real reason rather than a generic auth failure.
  HostKeyMismatch? mismatch;

  /// Matches the `SSHHostkeyVerifyHandler` signature of dartssh2, which hands
  /// us the algorithm name and the fingerprint as a UTF-8 encoded
  /// `SHA256:<base64>` string.
  Future<bool> verify(String type, Uint8List fingerprintBytes) async {
    final fingerprint = HostKeyFingerprint(
      type: type,
      value: utf8.decode(fingerprintBytes),
    );

    final pinned = await knownHosts.find(hostId);

    if (pinned == null) {
      final decision = await onUnknownKey(fingerprint);
      if (decision == HostKeyDecision.reject) return false;
      await knownHosts.pin(
        KnownHost(
          hostId: hostId,
          keyType: fingerprint.type,
          fingerprint: fingerprint.value,
          firstSeen: DateTime.now().toUtc(),
        ),
      );
      return true;
    }

    if (pinned.fingerprint == fingerprint.value) return true;

    mismatch = HostKeyMismatch(
      hostId: hostId,
      expected: pinned.fingerprint,
      actual: fingerprint.value,
    );
    return false;
  }
}
