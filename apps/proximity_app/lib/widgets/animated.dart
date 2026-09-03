import 'dart:math' as math;

import 'package:flutter/material.dart';

/// LIVE countdown ring: 30s sweep. 60fps via AnimationController.
class CountdownRing extends StatefulWidget {
  final Duration total;
  final Duration remaining;
  final String centerLabel;
  const CountdownRing(
      {super.key,
      required this.total,
      required this.remaining,
      required this.centerLabel});

  @override
  State<CountdownRing> createState() => _CountdownRingState();
}

class _CountdownRingState extends State<CountdownRing>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    final progress = widget.total.inMilliseconds == 0
        ? 0.0
        : (widget.remaining.inMilliseconds / widget.total.inMilliseconds)
            .clamp(0.0, 1.0);
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 148,
      height: 148,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        child: CustomPaint(
          painter: _RingPainter(progress: progress, color: cs.primary),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.centerLabel,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 2),
                const Text('LIVE', style: TextStyle(letterSpacing: 3)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  _RingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 8;
    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..color = color.withValues(alpha: 0.15);
    canvas.drawCircle(c, r, bg);
    final fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2,
        2 * math.pi * progress, false, fg);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}

/// 30s radar/countdown sweep for student listening state.
class RadarSweep extends StatefulWidget {
  final double progress; // 0..1 elapsed
  const RadarSweep({super.key, required this.progress});

  @override
  State<RadarSweep> createState() => _RadarSweepState();
}

class _RadarSweepState extends State<RadarSweep> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 180,
      height: 180,
      child: CustomPaint(
        painter: _RadarPainter(
            sweep: (widget.progress % 1.0) * 2 * math.pi, color: cs.primary),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double sweep;
  final Color color;
  _RadarPainter({required this.sweep, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 4;
    for (var i = 3; i >= 1; i--) {
      canvas.drawCircle(
          c,
          r * i / 3,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = color.withValues(alpha: 0.25));
    }
    final p = Paint()..color = color.withValues(alpha: 0.35);
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), sweep - 0.6, 0.6,
        true, p);
    canvas.drawCircle(
        c + Offset(math.cos(sweep) * r * 0.7, math.sin(sweep) * r * 0.7),
        6,
        Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.sweep != sweep;
}

/// Face oval with progress ring (~1s check).
class FaceOval extends StatelessWidget {
  final double progress; // 0..1
  final String prompt; // blink | turn-head
  const FaceOval({super.key, required this.progress, required this.prompt});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 200,
      height: 240,
      child: CustomPaint(
        painter: _OvalPainter(progress: progress, color: cs.primary),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.face, size: 64),
              const SizedBox(height: 8),
              Text(prompt, style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
        ),
      ),
    );
  }
}

class _OvalPainter extends CustomPainter {
  final double progress;
  final Color color;
  _OvalPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
        center: size.center(Offset.zero),
        width: size.width - 16,
        height: size.height - 16);
    canvas.drawOval(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = color.withValues(alpha: 0.25));
    canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..color = color);
  }

  @override
  bool shouldRepaint(_OvalPainter old) => old.progress != progress;
}

/// Animated present-count ticker (counts up, no jank: simple AnimatedSwitcher).
class PresentTicker extends StatelessWidget {
  final int present;
  final int total;
  const PresentTicker({super.key, required this.present, required this.total});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      transitionBuilder: (child, anim) =>
          SlideTransition(position: Tween<Offset>(begin: const Offset(0, 0.6), end: Offset.zero).animate(anim), child: child),
      child: Text('$present/$total present',
          key: ValueKey<int>(present),
          style: Theme.of(context).textTheme.headlineSmall),
    );
  }
}

/// Success spring: ✓ Marked with scale-in.
class MarkedBadge extends StatefulWidget {
  final String detail;
  const MarkedBadge({super.key, required this.detail});

  @override
  State<MarkedBadge> createState() => _MarkedBadgeState();
}

class _MarkedBadgeState extends State<MarkedBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _s;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 450));
    _s = CurvedAnimation(parent: _c, curve: Curves.elasticOut);
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _s,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('✓ Marked', style: TextStyle(fontSize: 28)),
          const SizedBox(height: 4),
          Text(widget.detail),
        ],
      ),
    );
  }
}
