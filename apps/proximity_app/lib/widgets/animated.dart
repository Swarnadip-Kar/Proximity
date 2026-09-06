import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Face oval with progress ring (~1s check).
class FaceOval extends StatelessWidget {
  final double progress; // 0..1
  final String prompt; // position instruction shown under the icon
  final Color? color; // ring/glow tint, defaults to theme primary
  const FaceOval(
      {super.key, required this.progress, required this.prompt, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 200,
      height: 240,
      child: CustomPaint(
        painter: _OvalPainter(progress: progress, color: c),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.face, size: 64),
              const SizedBox(height: 8),
              Text(prompt,
                  style: Theme.of(context).textTheme.labelLarge,
                  textAlign: TextAlign.center),
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
    // Soft border glow behind the crisp ring.
    canvas.drawOval(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..color = color.withValues(alpha: 0.22)
          ..maskFilter =
              const MaskFilter.blur(BlurStyle.normal, 10));
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

/// Success spring: ✓ Marked (or custom [title], e.g. Late) with scale-in.
class MarkedBadge extends StatefulWidget {
  final String detail;
  final String title;
  const MarkedBadge({super.key, required this.detail, this.title = '✓ Marked'});

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
          Text(widget.title, style: const TextStyle(fontSize: 28)),
          const SizedBox(height: 4),
          Text(widget.detail),
        ],
      ),
    );
  }
}
