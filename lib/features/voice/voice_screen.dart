import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/data/models/persona.dart';
import 'package:mobilecode/features/assistant/llm_endpoint_screen.dart';
import 'package:mobilecode/features/voice/voice_catalog.dart';
import 'package:mobilecode/features/voice/voice_endpoint_screen.dart';
import 'package:mobilecode/features/voice/voice_picker_screen.dart';

/// Lists the speaking characters and what each one sounds like.
class VoiceScreen extends ConsumerWidget {
  const VoiceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final personas = ref.watch(personasProvider);
    final catalog = ref.watch(voiceCatalogProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice'),
        actions: [
          IconButton(
            tooltip: 'Model endpoint',
            icon: const Icon(Icons.psychology_outlined),
            onPressed: () => _openModel(context, ref),
          ),
          IconButton(
            tooltip: 'Speech endpoint',
            icon: const Icon(Icons.graphic_eq),
            onPressed: () => _openEndpoint(context, ref),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addPersona(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add persona'),
      ),
      body: personas.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (list) => ListView(
          padding: EdgeInsets.only(
            bottom: 88 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            _CatalogBanner(
              catalog: catalog,
              onConfigure: () => _openEndpoint(context, ref),
              onRetry: () => ref.invalidate(voiceCatalogProvider),
            ),
            for (final persona in list)
              _PersonaTile(
                persona: persona,
                catalog: catalog.valueOrNull,
                onTap: () => _assignVoice(context, ref, persona),
                onDelete: () => _deletePersona(context, ref, persona),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openModel(BuildContext context, WidgetRef ref) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LlmEndpointScreen()),
    );
  }

  Future<void> _openEndpoint(BuildContext context, WidgetRef ref) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const VoiceEndpointScreen()),
    );
    if (changed ?? false) {
      ref.invalidate(voiceClientProvider);
      ref.invalidate(voiceCatalogProvider);
    }
  }

  Future<void> _assignVoice(
    BuildContext context,
    WidgetRef ref,
    Persona persona,
  ) async {
    final assigned = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => VoicePickerScreen(persona: persona)),
    );
    if (assigned ?? false) ref.invalidate(personasProvider);
  }

  Future<void> _addPersona(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NamePersonaDialog(),
    );
    if (name == null || name.isEmpty) return;

    await ref.read(personaRepositoryProvider).save(
          Persona(id: const Uuid().v4(), name: name),
        );
    ref.invalidate(personasProvider);
  }

  /// Confirms first: deleting is one tap on a small icon, it cannot be undone,
  /// and the seeded personas cannot be recreated with their original settings
  /// once they are gone.
  Future<void> _deletePersona(
    BuildContext context,
    WidgetRef ref,
    Persona persona,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${persona.name}?'),
        content: const Text('The persona and its voice assignment are removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(personaRepositoryProvider).delete(persona.id);
    ref.invalidate(personasProvider);
  }
}

/// Explains why the picker has nothing in it, when that is the case.
class _CatalogBanner extends StatelessWidget {
  const _CatalogBanner({
    required this.catalog,
    required this.onConfigure,
    required this.onRetry,
  });

  final AsyncValue<VoiceCatalog?> catalog;
  final VoidCallback onConfigure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return catalog.when(
      loading: () => const ListTile(
        leading: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text('Loading voices…'),
      ),
      error: (error, _) => ListTile(
        leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
        title: const Text('Could not load voices'),
        subtitle: Text('$error'),
        trailing: TextButton(onPressed: onRetry, child: const Text('Retry')),
        isThreeLine: true,
      ),
      data: (catalog) {
        if (catalog == null) {
          return ListTile(
            leading: const Icon(Icons.link_off),
            title: const Text('No speech endpoint yet'),
            subtitle: const Text(
              'Add your NVCF invocation URL and API key to hear anything.',
            ),
            trailing: FilledButton(
              onPressed: onConfigure,
              child: const Text('Set up'),
            ),
            isThreeLine: true,
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '${catalog.speakers.length} speakers · ${catalog.voiceCount} voices '
            '· ${catalog.locales.length} languages',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }
}

class _PersonaTile extends StatelessWidget {
  const _PersonaTile({
    required this.persona,
    required this.catalog,
    required this.onTap,
    required this.onDelete,
  });

  final Persona persona;
  final VoiceCatalog? catalog;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final speaker = catalog?.byKey(persona.voiceKey);

    final String subtitle;
    if (!persona.hasVoice) {
      subtitle = persona.role.isEmpty ? 'No voice assigned' : persona.role;
    } else if (speaker == null) {
      // Assigned against a catalog this endpoint does not serve. Saying so
      // beats showing a name that will fail at synthesis time.
      subtitle = '${persona.voiceKey} · not on this endpoint';
    } else {
      subtitle = '${speaker.speaker} · ${speaker.locale} · '
          '${persona.defaultEmotion}';
    }

    return ListTile(
      leading: CircleAvatar(
        child: Text(
          persona.name.characters.first.toUpperCase(),
        ),
      ),
      title: Text(persona.name),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (persona.hasVoice && speaker == null)
            Icon(Icons.warning_amber, color: Theme.of(context).colorScheme.error),
          IconButton(
            tooltip: 'Delete ${persona.name}',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _NamePersonaDialog extends StatefulWidget {
  const _NamePersonaDialog();

  @override
  State<_NamePersonaDialog> createState() => _NamePersonaDialogState();
}

class _NamePersonaDialogState extends State<_NamePersonaDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New persona'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Name',
          hintText: 'Jarvis',
        ),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
