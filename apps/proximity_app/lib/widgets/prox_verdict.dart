// Verdict motion vocabulary. Each verdict differs in meaning, not just
// color — so each gets a distinct, legible motion signature:
//
//   marked    → spring scale-in (celebratory pop, verdictSpring/450ms)
//   late      → rise + fade (arrived, but after the fact — no overshoot)
//   no-signal → slow breathing fade (absence, not failure — calm loop,
//               timer-driven so tests still settle)
//   error     → short horizontal shake (something is wrong — sharp, once)
//
// Icon + label always carry the meaning; motion only reinforces it, so
// reduced-motion still reads correctly as a plain fade-in.
library;

import 'dart:async';
import 'dart:math' as math;

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

  @override
  State<ProxVerdictBadge> createState() => _ProxVerdictBadgeState();
}

class _ProxVerdictBadgeState extends State<ProxVerdictBadge>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;
  Timer? _breath;
  var _dim = false;
  var _armed = false;

  @override
  void initState() {
    super.initState();
    // One-shot controllers arm here; the noSignal breathing loop arms in
    // didChangeDependencies (MediaQuery is readable there, and reduced
    // motion must leave it disarmed so the badge never rebuilds).
    if (widget.kind == ProxVerdictKind.noSignal) return;
    final duration = switch (widget.kind) {
      ProxVerdictKind.marked => ProxDurations.verdictPop,
      ProxVerdictKind.late => ProxDurations.medium,
      ProxVerdictKind.noSignal => ProxDurations.breath,
      ProxVerdictKind.error => ProxDurations.shake,
    };
    _c = AnimationController(vsync: this, duration: duration)..forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_armed || widget.kind != ProxVerdictKind.noSignal) return;
    _armed = true;
    if (!ProxMotion.reduced(context)) {
      // Calm loop, timer-driven (no infinite ticker — tests settle).
      _breath = Timer.periodic(ProxDurations.breath, (_) {
        if (!mounted) return;
        setState(() => _dim = !_dim);
      });
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    _breath?.cancel();
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

    // noSignal never creates [_c] (timer-driven loop instead).
    final c = _c;
    if (widget.kind == ProxVerdictKind.noSignal) {
      return AnimatedOpacity(
        duration: ProxDurations.breath,
        curve: ProxCurves.standard,
        opacity: _dim ? 0.55 : 1.0,
        child: _content(color),
      );
    }
    if (c == null) return _content(color);

    return switch (widget.kind) {
      ProxVerdictKind.marked => ScaleTransition(
          scale: CurvedAnimation(parent: c, curve: ProxCurves.verdictSpring),
          child: _content(color),
        ),
      ProxVerdictKind.late => FadeTransition(
          opacity: CurvedAnimation(parent: c, curve: ProxCurves.standard),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.3),
              end: Offset.zero,
            ).animate(
                CurvedAnimation(parent: c, curve: ProxCurves.standard)),
            child: _content(color),
          ),
        ),
      ProxVerdictKind.noSignal => _content(color),
      ProxVerdictKind.error => AnimatedBuilder(
          animation: c,
          builder: (context, child) {
            // One damped shake: 3 oscillations decaying to rest.
            final t = c.value.clamp(0.0, 1.0);
            final dx = t < 1.0
                ? (1 - t) * 10 * math.sin(t * 3 * 2 * math.pi)
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
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
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
