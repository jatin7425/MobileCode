import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/data/db/settings_repository.dart';
import 'package:mobilecode/data/secure/credential_store.dart';
import 'package:mobilecode/features/voice/nvcf_voice_client.dart';

/// Where the speech endpoint is entered.
class VoiceEndpointScreen extends ConsumerStatefulWidget {
  const VoiceEndpointScreen({super.key});

  @override
  ConsumerState<VoiceEndpointScreen> createState() =>
      _VoiceEndpointScreenState();
}

class _VoiceEndpointScreenState extends ConsumerState<VoiceEndpointScreen> {
  final _url = TextEditingController();
  final _key = TextEditingController();

  var _loading = true;
  var _busy = false;
  String? _result;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final url = await ref
        .read(settingsRepositoryProvider)
        .read(SettingsRepository.voiceEndpoint);
    final key = await ref
        .read(credentialStoreProvider)
        .read(CredentialStore.voiceApiKeyRef);
    if (!mounted) return;
    setState(() {
      _url.text = url ?? '';
      _key.text = key ?? '';
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Speech endpoint')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
              children: [
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: 'Invocation URL',
                    hintText: 'https://<id>.invocation.api.nvcf.nvidia.com',
                    helperText: 'Without the /v1/audio path.',
                  ),
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _key,
                  decoration: const InputDecoration(
                    labelText: 'API key',
                    hintText: 'nvapi-…',
                    helperText: 'Stored in the device keychain, never in the '
                        'database or a backup.',
                  ),
                  autocorrect: false,
                  obscureText: true,
                  maxLines: 1,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : _test,
                        child: const Text('Test'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy ? null : _save,
                        child: _busy
                            ? const SizedBox.square(
                                dimension: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Save'),
                      ),
                    ),
                  ],
                ),
                if (_result != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _result!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _failed
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'The key is sent from this device straight to NVIDIA. '
                  'Anyone who extracts it from the app can spend your credits, '
                  'so rotate it at build.nvidia.com if it ever leaks.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }

  /// Fetches the voice list as a connectivity check. Cheaper and safer than
  /// synthesising: it spends no meaningful credit and still proves the URL,
  /// the key, and that this function is a TTS one.
  Future<void> _test() async {
    final url = _url.text.trim();
    final key = _key.text.trim();
    if (url.isEmpty || key.isEmpty) {
      setState(() {
        _failed = true;
        _result = 'Enter both the URL and the key first.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _result = null;
    });

    final client = NvcfVoiceClient(baseUrl: url, apiKey: key);
    try {
      final catalog = await client.listVoices();
      if (!mounted) return;
      setState(() {
        _failed = false;
        _result = 'Reached it — ${catalog.speakers.length} speakers across '
            '${catalog.locales.join(', ')}.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _result = '$error';
      });
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);

    final settings = ref.read(settingsRepositoryProvider);
    final credentials = ref.read(credentialStoreProvider);
    final url = _url.text.trim();
    final key = _key.text.trim();

    // The keychain can refuse a write — a locked device, a wiped Keystore
    // entry. Without this the spinner would run forever with both buttons
    // disabled, and the only escape would be leaving the screen.
    try {
      if (url.isEmpty) {
        await settings.delete(SettingsRepository.voiceEndpoint);
      } else {
        await settings.write(SettingsRepository.voiceEndpoint, url);
      }
      if (key.isEmpty) {
        await credentials.delete(CredentialStore.voiceApiKeyRef);
      } else {
        await credentials.write(CredentialStore.voiceApiKeyRef, key);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _result = 'Could not save: $error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
