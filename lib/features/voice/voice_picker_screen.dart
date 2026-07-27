import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/data/models/persona.dart';
import 'package:mobilecode/features/voice/voice_catalog.dart';

/// Assigns a speaker — and a default mood — to one persona.
class VoicePickerScreen extends ConsumerStatefulWidget {
  const VoicePickerScreen({super.key, required this.persona});

  final Persona persona;

  @override
  ConsumerState<VoicePickerScreen> createState() => _VoicePickerScreenState();
}

class _VoicePickerScreenState extends ConsumerState<VoicePickerScreen> {
  final _player = AudioPlayer();

  String? _locale;
  String? _speakerKey;
  late String _emotion;

  /// Key of the speaker currently being fetched, so only that row shows a
  /// spinner rather than the whole list freezing.
  String? _previewing;
  String? _error;

  @override
  void initState() {
    super.initState();
    _speakerKey = widget.persona.voiceKey;
    _emotion = widget.persona.defaultEmotion;
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(voiceCatalogProvider);

    return Scaffold(
      appBar: AppBar(title: Text('Voice for ${widget.persona.name}')),
      body: catalog.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _Message(text: '$error'),
        data: (catalog) {
          if (catalog == null) {
            return const _Message(
              text: 'Set up the speech endpoint first — there are no voices '
                  'to choose from until then.',
            );
          }
          if (catalog.isEmpty) {
            return const _Message(text: 'This endpoint offers no voices.');
          }
          return _picker(catalog);
        },
      ),
    );
  }

  Widget _picker(VoiceCatalog catalog) {
    final locales = catalog.locales;
    // Open on the assigned voice's language if there is one, so returning to
    // this screen lands where the user left it.
    final locale = _locale ??
        catalog.byKey(_speakerKey)?.locale ??
        (locales.contains('EN-US') ? 'EN-US' : locales.first);
    final speakers = catalog.inLocale(locale);
    final selected = catalog.byKey(_speakerKey);

    return ListView(
      padding: EdgeInsets.only(
        bottom: 24 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: [
        _SectionLabel('Language'),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final code in locales) ...[
                ChoiceChip(
                  label: Text(code),
                  selected: code == locale,
                  onSelected: (_) => setState(() => _locale = code),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),

        if (selected != null && selected.hasEmotions) ...[
          _SectionLabel('Default mood'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final mood in selected.emotions)
                  ChoiceChip(
                    label: Text(mood),
                    selected: mood == _emotion,
                    onSelected: (_) => setState(() => _emotion = mood),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'The mood a line is spoken in can be overridden per message; '
              'this is the one ${widget.persona.name} uses by default.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],

        _SectionLabel('Speakers'),
        for (final speaker in speakers)
          _SpeakerTile(
            speaker: speaker,
            selected: speaker.key == _speakerKey,
            previewing: _previewing == speaker.key,
            emotion: speaker.key == _speakerKey ? _emotion : null,
            onSelect: () => setState(() {
              _speakerKey = speaker.key;
              if (!speaker.emotions.contains(_emotion)) {
                _emotion = speaker.emotions.isEmpty
                    ? 'Neutral'
                    : speaker.emotions.first;
              }
            }),
            onPreview: () => _preview(speaker),
          ),

        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),

        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: FilledButton(
            onPressed: _speakerKey == null ? null : _assign,
            child: const Text('Assign voice'),
          ),
        ),
        if (widget.persona.hasVoice)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextButton(
              onPressed: _clear,
              child: const Text('Remove voice'),
            ),
          ),
      ],
    );
  }

  /// Speaks a line so the user hears the voice before committing to it.
  ///
  /// Each preview is a real synthesis request against a metered free tier, so
  /// it fires only on an explicit tap — never automatically as the list
  /// scrolls or the selection changes.
  Future<void> _preview(VoiceSpeaker speaker) async {
    // One at a time. Two in flight would race on the same player, and
    // whichever finished first would clear the spinner on the row that is
    // still loading. It also stops a double-tap costing two credits.
    if (_previewing != null) return;

    final client = await ref.read(voiceClientProvider.future);
    if (client == null || !mounted) return;

    setState(() {
      _previewing = speaker.key;
      _error = null;
    });

    try {
      final mood = speaker.key == _speakerKey ? _emotion : null;
      final audio = await client.synthesize(
        text: _sampleFor(speaker.locale),
        voice: speaker.forEmotion(mood),
      );
      // dispose() closes the player, so a request that outlives the screen
      // must not touch it.
      if (!mounted) return;
      await _player.stop();
      await _player.play(BytesSource(audio));
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _previewing = null);
    }
  }

  Future<void> _assign() async {
    await ref.read(personaRepositoryProvider).save(
          widget.persona.copyWith(
            voiceKey: _speakerKey,
            defaultEmotion: _emotion,
          ),
        );
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _clear() async {
    await ref.read(personaRepositoryProvider).save(widget.persona.withoutVoice());
    if (mounted) Navigator.of(context).pop(true);
  }

  /// A line in the speaker's own language — an English sample read by a Hindi
  /// voice tells you nothing about how it will actually sound.
  static String _sampleFor(String locale) {
    return switch (locale.toUpperCase()) {
      'HI-IN' => 'सब सिस्टम तैयार हैं। आपका कोड चल रहा है।',
      'JA-JP' => 'すべてのシステムは正常です。',
      'ES-US' || 'ES-ES' => 'Todos los sistemas están listos.',
      'FR-FR' => 'Tous les systèmes sont opérationnels.',
      'DE-DE' => 'Alle Systeme sind bereit.',
      'IT-IT' => 'Tutti i sistemi sono pronti.',
      _ => 'All systems are ready. Your build finished cleanly.',
    };
  }
}

class _SpeakerTile extends StatelessWidget {
  const _SpeakerTile({
    required this.speaker,
    required this.selected,
    required this.previewing,
    required this.emotion,
    required this.onSelect,
    required this.onPreview,
  });

  final VoiceSpeaker speaker;
  final bool selected;
  final bool previewing;
  final String? emotion;
  final VoidCallback onSelect;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final moods = speaker.emotions;

    return ListTile(
      selected: selected,
      leading: Icon(selected ? Icons.check_circle : Icons.circle_outlined),
      title: Text(speaker.speaker),
      subtitle: Text(
        moods.isEmpty
            ? 'One take'
            : '${moods.length} moods · ${moods.join(', ')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: 'Hear ${speaker.speaker}',
        onPressed: previewing ? null : onPreview,
        icon: previewing
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.play_circle_outline),
      ),
      onTap: onSelect,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 1.2,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
  }
}
