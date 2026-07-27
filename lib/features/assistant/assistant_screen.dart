import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/features/assistant/assistant_controller.dart';
import 'package:mobilecode/features/assistant/assistant_identity.dart';
import 'package:mobilecode/features/assistant/audio_sink.dart';
import 'package:mobilecode/features/assistant/hud_painter.dart';
import 'package:mobilecode/features/assistant/speech_input.dart';
import 'package:mobilecode/features/voice/voice_screen.dart';

/// The assistant, as an instrument panel.
class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key});

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;

  AssistantController? _controller;
  var _seconds = 0.0;

  /// Rolling loudness history that becomes the spectrum ring. Fixed length so
  /// the ring never changes shape, only height.
  final _bands = List<double>.filled(48, 0);
  var _bandCursor = 0;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController.unbounded(vsync: this)..addListener(_frame);
    _clock.repeat(min: 0, max: 1, period: const Duration(seconds: 1));
  }

  @override
  void dispose() {
    _clock.dispose();
    _controller?.dispose();
    super.dispose();
  }

  void _frame() {
    final controller = _controller;
    setState(() {
      _seconds += 1 / 60;
      // Feeding the ring even when idle keeps it alive rather than flat —
      // a dead instrument reads as a broken one.
      final level = controller?.phase == AssistantPhase.listening
          ? controller!.level
          : (controller?.phase == AssistantPhase.speaking ? 0.35 : 0.05);
      _bands[_bandCursor] = level;
      _bandCursor = (_bandCursor + 1) % _bands.length;
    });
  }

  List<double> get _orderedBands => [
        for (var i = 0; i < _bands.length; i++)
          _bands[(_bandCursor + i) % _bands.length],
      ];

  AssistantController _resolveController(WidgetRef ref) {
    // Rebuilt whenever the endpoints or the assigned voice change, so
    // configuring the app mid-session takes effect without a restart.
    final existing = _controller;
    if (existing != null) return existing;

    final controller = AssistantController(
      speech: PlatformSpeechInput(),
      audio: PlayerAudioSink(),
      llm: ref.read(llmClientProvider).valueOrNull,
      voice: ref.read(voiceClientProvider).valueOrNull,
      speaker: ref.read(assistantSpeakerProvider).valueOrNull,
      // Lets the controller find the same speaker again in the other
      // language, so the language toggle changes accent rather than person.
      catalog: ref.read(voiceCatalogProvider).valueOrNull,
    );
    controller.addListener(() => setState(() {}));
    _controller = controller;
    return controller;
  }

  @override
  Widget build(BuildContext context) {
    // Watching rather than reading so a saved endpoint rebuilds the wiring.
    ref.listen(llmClientProvider, (_, _) => _rebuildController());
    ref.listen(voiceClientProvider, (_, _) => _rebuildController());
    ref.listen(assistantSpeakerProvider, (_, _) => _rebuildController());

    final controller = _resolveController(ref);
    final reduced = MediaQuery.disableAnimationsOf(context);

    return Scaffold(
      backgroundColor: HudColors.void_,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _Masthead(
                  phase: controller.phase,
                  language: controller.language,
                  onLanguage: controller.setLanguage,
                  onSettings: () => _openSettings(context),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _tapCore(controller),
                    behavior: HitTestBehavior.opaque,
                    child: CustomPaint(
                      painter: ReactorPainter(
                        t: _seconds,
                        level: controller.level,
                        bands: _orderedBands,
                        accent: _accentFor(controller.phase),
                        reducedMotion: reduced,
                      ),
                      child: Center(
                        child: _CoreLabel(controller: controller),
                      ),
                    ),
                  ),
                ),
                _Transcript(controller: controller),
              ],
            ),
          ),
          const IgnorePointer(child: _Chrome()),
        ],
      ),
    );
  }

  void _rebuildController() {
    _controller?.dispose();
    _controller = null;
    if (mounted) setState(() {});
  }

  Future<void> _tapCore(AssistantController controller) async {
    if (controller.phase == AssistantPhase.failed) {
      controller.clearError();
      return;
    }
    await controller.toggleListening();
  }

  Future<void> _openSettings(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const VoiceScreen()),
    );
    _rebuildController();
  }

  static Color _accentFor(AssistantPhase phase) => switch (phase) {
        AssistantPhase.thinking => HudColors.gold,
        AssistantPhase.failed => HudColors.crit,
        _ => HudColors.repulsor,
      };
}

class _Masthead extends StatelessWidget {
  const _Masthead({
    required this.phase,
    required this.language,
    required this.onLanguage,
    required this.onSettings,
  });

  final AssistantPhase phase;
  final AssistantLanguage language;
  final ValueChanged<AssistantLanguage> onLanguage;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              AssistantIdentity.name,
              style: const TextStyle(
                color: HudColors.repulsor,
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: 8,
                shadows: [
                  Shadow(color: HudColors.repulsor, blurRadius: 18),
                ],
              ),
            ),
          ),
          _LanguageToggle(value: language, onChanged: onLanguage),
          IconButton(
            tooltip: 'Voice and endpoints',
            onPressed: onSettings,
            icon: const Icon(Icons.tune, color: HudColors.inkDim),
          ),
        ],
      ),
    );
  }
}

class _LanguageToggle extends StatelessWidget {
  const _LanguageToggle({required this.value, required this.onChanged});

  final AssistantLanguage value;
  final ValueChanged<AssistantLanguage> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final language in AssistantLanguage.values)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: GestureDetector(
              onTap: () => onChanged(language),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: language == value
                        ? HudColors.repulsor
                        : HudColors.struct,
                  ),
                  color: language == value
                      ? HudColors.repulsor.withValues(alpha: 0.15)
                      : null,
                ),
                child: Text(
                  language.shortLabel,
                  style: TextStyle(
                    color: language == value
                        ? HudColors.repulsor
                        : HudColors.inkDim,
                    fontSize: 11,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The word in the middle of the reactor: what it is doing, or what to do.
class _CoreLabel extends StatelessWidget {
  const _CoreLabel({required this.controller});

  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    final text = switch (controller.phase) {
      AssistantPhase.listening => 'LISTENING',
      AssistantPhase.thinking => 'THINKING',
      AssistantPhase.speaking => 'SPEAKING',
      AssistantPhase.failed => 'TAP TO RESET',
      AssistantPhase.idle => 'TAP TO SPEAK',
    };

    return Text(
      text,
      style: TextStyle(
        color: controller.phase == AssistantPhase.failed
            ? HudColors.crit
            : HudColors.void_,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 3,
      ),
    );
  }
}

/// Live transcript plus whatever needs saying about configuration.
class _Transcript extends StatelessWidget {
  const _Transcript({required this.controller});

  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    final lines = controller.history.reversed.take(4).toList();

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 130),
      padding: EdgeInsets.fromLTRB(
        20, 12, 20, 16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x3838E1FF))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (controller.error != null)
            _Line(
              text: controller.error!,
              colour: HudColors.crit,
            )
          else if (!controller.canAnswer)
            const _Line(
              text: 'No model endpoint yet — open the tuner and add your '
                  'LiteLLM URL to get an answer back.',
              colour: HudColors.gold,
            )
          else if (!controller.canSpeak)
            const _Line(
              text: 'No voice assigned — answers appear here but are not '
                  'spoken. Assign one in the tuner.',
              colour: HudColors.gold,
            ),
          if (controller.heard.isNotEmpty)
            _Line(text: controller.heard, colour: HudColors.ink, dim: false),
          for (final line in lines)
            _Line(
              text: line.speaker
                  ? '${AssistantIdentity.properName}: ${line.text}'
                  : line.text,
              colour: line.speaker ? HudColors.repulsor : HudColors.inkDim,
            ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.text, required this.colour, this.dim = true});

  final String text;
  final Color colour;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colour,
          fontSize: dim ? 12 : 14,
          height: 1.35,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

/// Scanlines, vignette, and corner brackets — the frame that makes the panel
/// read as an instrument rather than a page.
class _Chrome extends StatelessWidget {
  const _Chrome();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 1.1,
                colors: [
                  Colors.transparent,
                  HudColors.void_.withValues(alpha: 0.75),
                ],
                stops: const [0.45, 1],
              ),
            ),
          ),
        ),
        for (final corner in _corners)
          Positioned(
            top: corner.top,
            bottom: corner.bottom,
            left: corner.left,
            right: corner.right,
            child: SizedBox(
              width: 22,
              height: 22,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    top: corner.top != null ? _edge : BorderSide.none,
                    bottom: corner.bottom != null ? _edge : BorderSide.none,
                    left: corner.left != null ? _edge : BorderSide.none,
                    right: corner.right != null ? _edge : BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  static const _edge =
      BorderSide(color: Color(0x8C38E1FF), width: 1);

  static const _corners = [
    (top: 8.0, bottom: null, left: 8.0, right: null),
    (top: 8.0, bottom: null, left: null, right: 8.0),
    (top: null, bottom: 8.0, left: 8.0, right: null),
    (top: null, bottom: 8.0, left: null, right: 8.0),
  ];
}
