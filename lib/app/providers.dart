import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/data/db/host_repository.dart';
import 'package:mobilecode/data/db/known_host_repository.dart';
import 'package:mobilecode/data/models/host.dart';
import 'package:mobilecode/data/secure/credential_store.dart';
import 'package:mobilecode/features/ssh/direct_ssh_transport.dart';
import 'package:mobilecode/features/ssh/host_key_verifier.dart';
import 'package:mobilecode/features/ssh/ssh_transport.dart';

/// Overridden in `main` once the database is open. Reading one of these
/// without the override is a wiring bug, not a runtime condition, so they
/// throw rather than returning a fallback.
Never _notInitialised(String name) =>
    throw StateError('$name was read before bootstrap overrode it');

final credentialStoreProvider = Provider<CredentialStore>(
  (ref) => _notInitialised('credentialStoreProvider'),
);

final hostRepositoryProvider = Provider<HostRepository>(
  (ref) => _notInitialised('hostRepositoryProvider'),
);

final knownHostRepositoryProvider = Provider<KnownHostRepository>(
  (ref) => _notInitialised('knownHostRepositoryProvider'),
);

/// The app's saved hosts.
final hostsProvider = FutureProvider<List<HostConfig>>(
  (ref) => ref.watch(hostRepositoryProvider).list(),
);

/// Key needed so the trust prompt can find a navigator: host key verification
/// happens deep inside the SSH handshake, far from any widget's context.
final navigatorKeyProvider = Provider((ref) => GlobalKey<NavigatorState>());

final sshTransportProvider = Provider<SshTransport>((ref) {
  final knownHosts = ref.watch(knownHostRepositoryProvider);
  final navigatorKey = ref.watch(navigatorKeyProvider);

  return DirectSshTransport(
    credentials: ref.watch(credentialStoreProvider),
    verifierFactory: (host) => HostKeyVerifier(
      hostId: host.id,
      knownHosts: knownHosts,
      onUnknownKey: (fingerprint) =>
          _promptToTrust(navigatorKey, host.displayAddress, fingerprint),
    ),
  );
});

Future<HostKeyDecision> _promptToTrust(
  GlobalKey<NavigatorState> navigatorKey,
  String address,
  HostKeyFingerprint fingerprint,
) async {
  final context = navigatorKey.currentContext;
  // No UI to ask with means we cannot get informed consent, and silently
  // trusting an unverified key is exactly the failure this prompt exists to
  // prevent.
  if (context == null) return HostKeyDecision.reject;

  final decision = await showDialog<HostKeyDecision>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Unrecognised host'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$address presented this key:'),
          const SizedBox(height: 12),
          SelectableText(
            fingerprint.value,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(fingerprint.type,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          const Text(
            'Compare it against `ssh-keyscan` on a machine you trust before '
            'accepting. Once trusted, this key is pinned and a change will '
            'block the connection.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, HostKeyDecision.reject),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, HostKeyDecision.trust),
          child: const Text('Trust'),
        ),
      ],
    ),
  );

  return decision ?? HostKeyDecision.reject;
}
