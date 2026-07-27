import 'package:flutter/material.dart';

import 'package:mobilecode/features/terminal/session_controller.dart';

/// The row of keys a phone keyboard does not have.
///
/// Agent CLIs are full-screen TUIs driven by Esc, Tab, arrows, and Ctrl-C.
/// None of those exist on a soft keyboard, so without this bar the app can
/// display an agent but not actually use one.
class AccessoryBar extends StatelessWidget {
  const AccessoryBar({super.key, required this.controller});

  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  _Key(label: 'esc', onTap: () => controller.sendRaw('\x1b')),
                  _Key(label: 'tab', onTap: () => controller.sendRaw('\t')),
                  _Key(
                    label: 'ctrl',
                    active: controller.ctrlArmed,
                    onTap: controller.toggleCtrl,
                  ),
                  _Key(
                    label: 'alt',
                    active: controller.altArmed,
                    onTap: controller.toggleAlt,
                  ),
                  _Key(
                    icon: Icons.keyboard_arrow_up,
                    onTap: () => controller.sendRaw('\x1b[A'),
                  ),
                  _Key(
                    icon: Icons.keyboard_arrow_down,
                    onTap: () => controller.sendRaw('\x1b[B'),
                  ),
                  _Key(
                    icon: Icons.keyboard_arrow_left,
                    onTap: () => controller.sendRaw('\x1b[D'),
                  ),
                  _Key(
                    icon: Icons.keyboard_arrow_right,
                    onTap: () => controller.sendRaw('\x1b[C'),
                  ),
                  // Ctrl-C is the single most-reached-for key when an agent is
                  // doing something you did not intend, so it gets its own
                  // button rather than requiring the sticky modifier.
                  _Key(
                    label: '^C',
                    onTap: () => controller.sendControl('c'),
                  ),
                  _Key(label: '/', onTap: () => controller.sendRaw('/')),
                  _Key(label: '|', onTap: () => controller.sendRaw('|')),
                  _Key(label: '-', onTap: () => controller.sendRaw('-')),
                  _Key(label: '~', onTap: () => controller.sendRaw('~')),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({this.label, this.icon, this.active = false, required this.onTap});

  final String? label;
  final IconData? icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground =
        active ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
      child: Material(
        color: active
            ? theme.colorScheme.primary
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: icon != null
                ? Icon(icon, size: 20, color: foreground)
                : Text(
                    label!,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: foreground,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
