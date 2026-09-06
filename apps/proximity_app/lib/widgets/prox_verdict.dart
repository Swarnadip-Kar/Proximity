// Verdict motion vocabulary. Each verdict differs in meaning, not just
// color — so each gets a distinct, legible motion signature:
//
//   marked    → spring scale-in (celebratory pop, verdictSpring/450ms)
//   late      → rise + fade (arrived, but after the fact — no overshoot)
//   no-signal → slow breathing fade (absence, not failure — calm loop)
//   error     → short horizontal shake (something is wrong — sharp, once)
//
// Icon + label always carry the meaning; motion only reinforces it, so
// reduced-motion still reads correctly as a plain fade-in.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

enum ProxVerdictKind { marked, late, noSignal, error }

/// Full-screen verdict badge. Backwards-compatible with the legacy
/// `MarkedBadge(title/detail)` strings the widget tests assert on.
class ProxVerdictBadge extends StatefulWidget {
  final ProxVerdictKind kind;
  final String title;
  final String detail;

  const ProxVerdictBadge({
    super.key,
    required this.kind,
    required this.title,
    required this.detail,
  });

  /// Marked ✓ with the legacy default copy.
  const ProxVerdictBadge.marked({
    super.key,
    this.detail = '',
    this.title = '✓ Marked',
  }) : kind = ProxVerdictKind.marked;

  /// Late with the legacy default copy.
  const ProxVerdictBadge.late({
    super.key,
    this.detail = '',
    this.title = 'Late',
  }) : kind = ProxVerdictKind.late;

  @override
  State<ProxVerdictBadge> createState() => _ProxVerdictBadgeState();
}

class _ProxVerdictBadgeState extends State<ProxVerdictBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    final duration = switch (widget.kind) {
      ProxVerdictKind.marked => const Duration(milliseconds: 450),
      ProxVerdictKind.late => ProxDurations.medium,
      ProxVerdictKind.noSignal => const Duration(milliseconds: 1200),
      ProxVerdictKind.error => const Duration(milliseconds: 500),
    };
    _c = AnimationController(vsync: this, duration: duration);
    if (widget.kind == ProxVerdictKind.noSignal) {
      _c.repeat(reverse: true);
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  ProxState get _state => switch (widget.kind) {
        ProxVerdictKind.marked => ProxState.marked,
        ProxVerdictKind.late => ProxState.late,
        ProxVerdictKind.noSignal => ProxState.neutral,
        ProxVerdictKind.error => ProxState.error,
      };

  IconData get _icon => switch (widget.kind) {
        ProxVerdictKind.marked => Icons.check_circle,
        ProxVerdictKind.late => Icons.schedule,
        ProxVerdictKind.noSignal => Icons.bluetooth_disabled,
        ProxVerdictKind.error => Icons.error_outline,
      };

  @override
  Widget build(BuildContext context) {
    final color = ProxStateColors.of(context, _state);
    if (ProxMotion.reduced(context)) return _content(color);

    return switch (widget.kind) {
      ProxVerdictKind.marked => ScaleTransition(
          scale: CurvedAnimation(parent: _c, curve: ProxCurves.verdictSpring),
          child: _content(color),
        ),
      ProxVerdictKind.late => FadeTransition(
          opacity: CurvedAnimation(parent: _c, curve: ProxCurves.standard),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.3),
              end: Offset.zero,
            ).animate(
                CurvedAnimation(parent: _c, curve: ProxCurves.standard)),
            child: _content(color),
          ),
        ),
      ProxVerdictKind.noSignal => FadeTransition(
          opacity: Tween<double>(begin: 1, end: 0.55).animate(
            CurvedAnimation(parent: _c, curve: Curves.easeInOut),
          ),
          child: _content(color),
        ),
      ProxVerdictKind.error => AnimatedBuilder(
          animation: _c,
          builder: (context, child) {
            // One damped shake: 3 oscillations decaying to rest.
            final t = _c.value.clamp(0.0, 1.0);
            final dx = t < 1.0
                ? (1 - t) * 10 * _shake(t * 3 * 2 * 3.1415926535)
                : 0.0;
            return Transform.translate(
              offset: Offset(dx, 0),
              child: Opacity(opacity: t < 0.2 ? t / 0.2 : 1, child: child),
            );
          },
          child: _content(color),
        ),
    };
  }

  double _shake(double x) => x <= 0 ? 0 : (x < 0.001 ? 0 : _sin(x));

  double _sin(double x) {
    // Cheap sin without importing dart:math into the widget file header
    // dance — implemented via the standard library below.
    return _Sin.impl(x);
  }

  Widget _content(Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(color: color.withValues(alpha: 0.5), width: 2),
          ),
          child: Icon(_icon, size: 44, color: color),
        ),
        const SizedBox(height: ProxSpacing.md),
        Text(
          widget.title,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
        ),
        if (widget.detail.isNotEmpty) ...[
          const SizedBox(height: ProxSpacing.xs),
          Text(widget.detail, textAlign: TextAlign.center),
        ],
      ],
    );
  }
}

// Tiny indirection so the shake math stays testable without pulling
// dart:math into the public import surface of this file.
class _Sin {
  static double impl(double x) {
    var n = x;
    // Range-reduce to [-pi, pi].
    const twoPi = 6.283185307179586;
    n = n % twoPi;
    if (n > 3.141592653589793) n -= twoPi;
    if (n < -3.141592653589793) n += twoPi;
    // Taylor, 7th order — plenty for a 10px shake.
    final x2 = n * n;
    return n * (1 - x2 / 6 + x2 * x2 / 120);
  }
}
