import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The instrument palette. Cyan is the only bright hue; gold appears only when
/// something is loud or wrong, so it carries meaning instead of decorating.
class HudColors {
  const HudColors._();

  static const void_ = Color(0xFF04070C);
  static const deep = Color(0xFF07131D);
  static const repulsor = Color(0xFF38E1FF);
  static const repulsorBright = Color(0xFF7FF3FF);
  static const struct = Color(0xFF0F6D87);
  static const gold = Color(0xFFFFB547);
  static const crit = Color(0xFFFF4D5E);
  static const ink = Color(0xFFCFE9F5);
  static const inkDim = Color(0xFF6F95A8);
}

/// The reactor: concentric instrument rings around a core that breathes with
/// the microphone.
///
/// Drawn rather than animated with widgets because it is one continuous
/// instrument — a stack of forty rotating, glowing widgets would cost far more
/// and still not let the rings share a centre cleanly.
class ReactorPainter extends CustomPainter {
  ReactorPainter({
    required this.t,
    required this.level,
    required this.bands,
    required this.accent,
    required this.reducedMotion,
  });

  /// Seconds since the animation started; drives every rotation.
  final double t;

  /// Input loudness 0..1. Swells the core and the bloom.
  final double level;

  /// Recent loudness history, oldest first, drawn as the spectrum ring.
  final List<double> bands;

  /// Shifts to gold while thinking and to red on failure, so the state of the
  /// turn is legible from across a room without reading the label.
  final Color accent;

  final bool reducedMotion;

  static const _tau = math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) * 0.44;
    final spin = reducedMotion ? 0.0 : t;

    _bloom(canvas, centre, r);
    _degreeScale(canvas, centre, r);
    _segmentedRing(canvas, centre, r, spin);
    _dashedRing(canvas, centre, r, spin);
    _spectrum(canvas, centre, r, spin);
    _core(canvas, centre, r);
  }

  void _bloom(Canvas canvas, Offset c, double r) {
    final radius = r * (0.95 + level * 0.5);
    canvas.drawCircle(
      c,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            accent.withValues(alpha: 0.20 + level * 0.32),
            accent.withValues(alpha: 0.06),
            accent.withValues(alpha: 0),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: c, radius: radius)),
    );
  }

  /// Static 360° scale. Everything else rotates against it, which is what
  /// makes the rotation read as motion rather than drift.
  void _degreeScale(Canvas canvas, Offset c, double r) {
    final minor = Paint()
      ..color = HudColors.struct
      ..strokeWidth = 1;
    final major = Paint()
      ..color = accent
      ..strokeWidth = 1.4;

    for (var deg = 0; deg < 360; deg += 5) {
      final a = (deg - 90) * math.pi / 180;
      final isMajor = deg % 30 == 0;
      final len = isMajor ? r * 0.075 : r * 0.035;
      final outer = Offset(c.dx + math.cos(a) * r, c.dy + math.sin(a) * r);
      final inner = Offset(
        c.dx + math.cos(a) * (r - len),
        c.dy + math.sin(a) * (r - len),
      );
      canvas.drawLine(outer, inner, isMajor ? major : minor);

      if (isMajor) {
        _label(
          canvas,
          deg.toString().padLeft(3, '0'),
          Offset(
            c.dx + math.cos(a) * (r - len - r * 0.07),
            c.dy + math.sin(a) * (r - len - r * 0.07),
          ),
          math.max(7, r * 0.048),
        );
      }
    }

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = accent.withValues(alpha: 0.3),
    );
  }

  void _segmentedRing(Canvas canvas, Offset c, double r, double spin) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = accent
      ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 3);

    final radius = r * 0.845;
    final rect = Rect.fromCircle(center: c, radius: radius);
    for (var i = 0; i < 6; i++) {
      final from = (i / 6) * _tau - spin * 0.16;
      canvas.drawArc(rect, from, _tau / 6 - 0.22, false, paint);
    }
  }

  /// Dashed ring plus three gold markers riding it, so the rotation has
  /// something to read against at a glance.
  void _dashedRing(Canvas canvas, Offset c, double r, double spin) {
    final radius = r * 0.755;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = HudColors.repulsorBright.withValues(alpha: 0.65);

    const dashes = 90;
    for (var i = 0; i < dashes; i++) {
      final from = (i / dashes) * _tau + spin * 0.32;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: radius),
        from,
        _tau / dashes * 0.35,
        false,
        paint,
      );
    }

    final marker = Paint()
      ..color = HudColors.gold
      ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 4);
    for (var i = 0; i < 3; i++) {
      final a = (i / 3) * _tau + spin * 0.32;
      canvas.drawCircle(
        Offset(c.dx + math.cos(a) * radius, c.dy + math.sin(a) * radius),
        2.6,
        marker,
      );
    }
  }

  /// Where the microphone actually lands on the instrument.
  void _spectrum(Canvas canvas, Offset c, double r, double spin) {
    if (bands.isEmpty) return;

    final inner = r * 0.60;
    for (var i = 0; i < bands.length; i++) {
      final value = bands[i].clamp(0.0, 1.0);
      final a = (i / bands.length) * _tau - math.pi / 2 + spin * 0.05;
      final outer = inner + value * r * 0.13 + 1.5;
      canvas.drawLine(
        Offset(c.dx + math.cos(a) * inner, c.dy + math.sin(a) * inner),
        Offset(c.dx + math.cos(a) * outer, c.dy + math.sin(a) * outer),
        Paint()
          ..strokeWidth = 2
          ..color = (value > 0.62 ? HudColors.gold : accent)
              .withValues(alpha: 0.45 + value * 0.55),
      );
    }

    canvas.drawCircle(
      c,
      r * 0.555,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = accent.withValues(alpha: 0.35),
    );
  }

  void _core(Canvas canvas, Offset c, double r) {
    final pulse = 0.5 + math.sin(t * 2.1) * 0.08 + level * 0.42;
    final radius = r * 0.30 * (0.86 + pulse * 0.3);

    canvas.drawCircle(
      c,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white,
            HudColors.repulsorBright,
            accent.withValues(alpha: 0.42),
            accent.withValues(alpha: 0),
          ],
          stops: const [0, 0.28, 0.7, 1],
        ).createShader(Rect.fromCircle(center: c, radius: radius)),
    );

    // The triangular iris — the detail that makes it read as a reactor
    // rather than a generic glow.
    final spin = reducedMotion ? 0.0 : t * 0.5;
    final path = Path();
    for (var i = 0; i < 3; i++) {
      final a = (i / 3) * _tau + spin;
      final p = Offset(
        c.dx + math.cos(a) * r * 0.155,
        c.dy + math.sin(a) * r * 0.155,
      );
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = HudColors.void_.withValues(alpha: 0.85),
    );
  }

  void _label(Canvas canvas, String text, Offset centre, double fontSize) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: HudColors.inkDim,
          fontSize: fontSize,
          fontFamily: 'monospace',
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      centre - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(ReactorPainter old) =>
      old.t != t ||
      old.level != level ||
      old.accent != accent ||
      !listEquals(old.bands, bands);
}
