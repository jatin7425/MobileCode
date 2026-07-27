
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/data/db/host_repository.dart';
import 'package:mobilecode/data/db/known_host_repository.dart';
import 'package:mobilecode/data/db/persona_repository.dart';
import 'package:mobilecode/data/db/settings_repository.dart';
import 'package:mobilecode/data/models/host.dart';
import 'package:mobilecode/data/models/persona.dart';
import 'package:mobilecode/data/secure/credential_store.dart';
import 'package:mobilecode/features/ssh/direct_ssh_transport.dart';
import 'package:mobilecode/features/ssh/host_key_verifier.dart';
import 'package:mobilecode/features/ssh/ssh_transport.dart';
import 'package:mobilecode/features/assistant/assistant_identity.dart';
import 'package:mobilecode/features/assistant/llm_client.dart';
import 'package:mobilecode/features/voice/nvcf_voice_client.dart';
import 'package:mobilecode/features/voice/voice_catalog.dart';

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

final personaRepositoryProvider = Provider<PersonaRepository>(
  (ref) => _notInitialised('personaRepositoryProvider'),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => _notInitialised('settingsRepositoryProvider'),
);

/// The app's saved hosts.
final hostsProvider = FutureProvider<List<HostConfig>>(
  (ref) => ref.watch(hostRepositoryProvider).list(),
);

/// The speaking characters the user has defined.
final personasProvider = FutureProvider<List<Persona>>(
  (ref) => ref.watch(personaRepositoryProvider).list(),
);

/// Configured speech endpoint, or null until the user enters one.
final voiceClientProvider = FutureProvider<NvcfVoiceClient?>((ref) async {
  final endpoint =
      await ref.watch(settingsRepositoryProvider).read(SettingsRepository.voiceEndpoint);
  final key =
      await ref.watch(credentialStoreProvider).read(CredentialStore.voiceApiKeyRef);

  if (endpoint == null || endpoint.isEmpty) return null;
  if (key == null || key.isEmpty) return null;

  final client = NvcfVoiceClient(baseUrl: endpoint, apiKey: key);
  ref.onDispose(client.close);
  return client;
});

/// Configured chat model, or null until an endpoint is entered.
final llmClientProvider = FutureProvider<LlmClient?>((ref) async {
  final settings = ref.watch(settingsRepositoryProvider);
  final endpoint = await settings.read(SettingsRepository.llmEndpoint);
  final model = await settings.read(SettingsRepository.llmModel);
  final key = await ref
      .watch(credentialStoreProvider)
      .read(CredentialStore.llmApiKeyRef);

  if (endpoint == null || endpoint.isEmpty) return null;
  if (model == null || model.isEmpty) return null;

  final client = LlmClient(
    baseUrl: endpoint,
    // A local proxy may not check one, and refusing to work without a key
    // would lock out exactly that setup.
    apiKey: key ?? '',
    model: model,
  );
  ref.onDispose(client.close);
  return client;
});

/// The speaker the assistant talks as.
///
/// Resolved from the Vikram persona if one has been assigned, otherwise the
/// default speaker for whichever locale the catalog offers — so the assistant
/// has a voice on first run without the user configuring anything.
final assistantSpeakerProvider = FutureProvider<VoiceSpeaker?>((ref) async {
  final catalog = await ref.watch(voiceCatalogProvider.future);
  if (catalog == null) return null;

  final personas = await ref.watch(personasProvider.future);
  for (final persona in personas) {
    if (persona.id == AssistantIdentity.personaId && persona.hasVoice) {
      final assigned = catalog.byKey(persona.voiceKey);
      if (assigned != null) return assigned;
    }
  }

  return catalog.byKey(AssistantIdentity.defaultSpeakerKey) ??
      catalog.byKey(AssistantIdentity.defaultHindiSpeakerKey) ??
      (catalog.isEmpty ? null : catalog.speakers.first);
});

/// Voices the configured endpoint offers.
///
/// Kept alive across screens: the list costs a network round trip and never
/// changes within a session, so re-fetching it every time the picker opens
/// would burn the free tier's request budget for nothing.
final voiceCatalogProvider = FutureProvider<VoiceCatalog?>((ref) async {
  final client = await ref.watch(voiceClientProvider.future);
  return client?.listVoices();
});

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
