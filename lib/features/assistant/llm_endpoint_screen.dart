import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/data/db/settings_repository.dart';
import 'package:mobilecode/data/secure/credential_store.dart';
import 'package:mobilecode/features/assistant/llm_client.dart';

/// Where the chat model is configured.
class LlmEndpointScreen extends ConsumerStatefulWidget {
  const LlmEndpointScreen({super.key});

  @override
  ConsumerState<LlmEndpointScreen> createState() => _LlmEndpointScreenState();
}

class _LlmEndpointScreenState extends ConsumerState<LlmEndpointScreen> {
  final _url = TextEditingController();
  final _model = TextEditingController();
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
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsRepositoryProvider);
    final url = await settings.read(SettingsRepository.llmEndpoint);
    final model = await settings.read(SettingsRepository.llmModel);
    final key = await ref
        .read(credentialStoreProvider)
        .read(CredentialStore.llmApiKeyRef);
    if (!mounted) return;
    setState(() {
      _url.text = url ?? '';
      _model.text = model ?? '';
      _key.text = key ?? '';
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Model endpoint')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
              children: [
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://your-litellm-host',
                    helperText: 'With or without the /v1 — either works.',
                  ),
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _model,
                  decoration: const InputDecoration(
                    labelText: 'Model',
                    hintText: 'the name your proxy routes on',
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _key,
                  decoration: const InputDecoration(
                    labelText: 'API key (optional)',
                    helperText: 'Stored in the device keychain. Leave empty '
                        'for a proxy that does not check one.',
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
              ],
            ),
    );
  }

  Future<void> _test() async {
    final url = _url.text.trim();
    final model = _model.text.trim();
    if (url.isEmpty || model.isEmpty) {
      setState(() {
        _failed = true;
        _result = 'Enter both the URL and the model name first.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _result = null;
    });

    final client =
        LlmClient(baseUrl: url, apiKey: _key.text.trim(), model: model);
    try {
      final reply = await client.complete(
        messages: [
          {'role': 'user', 'content': 'Reply with the single word: ready'},
        ],
      );
      if (!mounted) return;
      setState(() {
        _failed = false;
        _result = 'Answered: ${reply.length > 80 ? reply.substring(0, 80) : reply}';
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

    try {
      await _writeOrClear(
          settings, SettingsRepository.llmEndpoint, _url.text.trim());
      await _writeOrClear(
          settings, SettingsRepository.llmModel, _model.text.trim());

      final key = _key.text.trim();
      if (key.isEmpty) {
        await credentials.delete(CredentialStore.llmApiKeyRef);
      } else {
        await credentials.write(CredentialStore.llmApiKeyRef, key);
      }

      ref.invalidate(llmClientProvider);
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

  Future<void> _writeOrClear(
    SettingsRepository settings,
    String key,
    String value,
  ) =>
      value.isEmpty ? settings.delete(key) : settings.write(key, value);
}
