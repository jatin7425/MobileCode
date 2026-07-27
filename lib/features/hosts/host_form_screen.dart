import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/data/models/host.dart';
import 'package:mobilecode/data/secure/credential_store.dart';

class HostFormScreen extends ConsumerStatefulWidget {
  const HostFormScreen({super.key});

  @override
  ConsumerState<HostFormScreen> createState() => _HostFormScreenState();
}

class _HostFormScreenState extends ConsumerState<HostFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _label = TextEditingController();
  final _hostname = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _secret = TextEditingController();
  final _passphrase = TextEditingController();
  final _workingDirectory = TextEditingController();

  var _authMethod = SshAuthMethod.privateKey;
  var _saving = false;

  @override
  void dispose() {
    for (final controller in [
      _label,
      _hostname,
      _port,
      _username,
      _secret,
      _passphrase,
      _workingDirectory,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final usesKey = _authMethod == SshAuthMethod.privateKey;

    return Scaffold(
      appBar: AppBar(title: const Text('Add host')),
      body: Form(
        key: _formKey,
        child: ListView(
          // Ends above the system navigation bar. Without this inset the Save
          // button sits under the gesture bar and cannot be tapped.
          padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
          children: [
            TextFormField(
              controller: _label,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'work laptop',
              ),
              validator: _required,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _hostname,
              decoration: const InputDecoration(labelText: 'Host'),
              autocorrect: false,
              keyboardType: TextInputType.url,
              validator: _required,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _port,
              decoration: const InputDecoration(labelText: 'Port'),
              keyboardType: TextInputType.number,
              validator: _validPort,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: 'Username'),
              autocorrect: false,
              validator: _required,
            ),
            const SizedBox(height: 20),
            SegmentedButton<SshAuthMethod>(
              segments: const [
                ButtonSegment(
                  value: SshAuthMethod.privateKey,
                  label: Text('Private key'),
                ),
                ButtonSegment(
                  value: SshAuthMethod.password,
                  label: Text('Password'),
                ),
              ],
              selected: {_authMethod},
              onSelectionChanged: (selection) =>
                  setState(() => _authMethod = selection.first),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _secret,
              decoration: InputDecoration(
                labelText: usesKey ? 'Private key (PEM)' : 'Password',
                helperText: 'Stored in the device keychain, never uploaded.',
              ),
              obscureText: !usesKey,
              autocorrect: false,
              maxLines: usesKey ? 6 : 1,
              validator: _required,
            ),
            if (usesKey) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _passphrase,
                decoration: const InputDecoration(
                  labelText: 'Key passphrase (optional)',
                ),
                obscureText: true,
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _workingDirectory,
              decoration: const InputDecoration(
                labelText: 'Start directory (optional)',
                hintText: '~/code/myproject',
              ),
              autocorrect: false,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save host'),
            ),
          ],
        ),
      ),
    );
  }

  String? _required(String? value) =>
      (value == null || value.trim().isEmpty) ? 'Required' : null;

  String? _validPort(String? value) {
    final port = int.tryParse(value?.trim() ?? '');
    if (port == null || port < 1 || port > 65535) return '1–65535';
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);

    final id = const Uuid().v4();
    final credentials = ref.read(credentialStoreProvider);

    // Secret first: a host row pointing at a credential that was never
    // written would fail at connect time with a confusing error.
    await credentials.write(
      CredentialStore.hostCredentialRef(id),
      _secret.text,
    );
    if (_authMethod == SshAuthMethod.privateKey &&
        _passphrase.text.isNotEmpty) {
      await credentials.write(
        CredentialStore.hostPassphraseRef(id),
        _passphrase.text,
      );
    }

    await ref.read(hostRepositoryProvider).save(
          HostConfig(
            id: id,
            label: _label.text.trim(),
            hostname: _hostname.text.trim(),
            port: int.parse(_port.text.trim()),
            username: _username.text.trim(),
            authMethod: _authMethod,
            credentialRef: CredentialStore.hostCredentialRef(id),
            defaultWorkingDirectory: _workingDirectory.text.trim().isEmpty
                ? null
                : _workingDirectory.text.trim(),
          ),
        );

    if (mounted) Navigator.of(context).pop(true);
  }
}
