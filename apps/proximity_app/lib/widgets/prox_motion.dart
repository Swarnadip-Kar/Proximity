// Shared motion primitives. All animation state stays local to these
// widgets — never in global providers (per project constraints).
//
// Every duration routes through [ProxMotion.effective] so the platform
// reduce-motion setting degrades to instant-but-correct state changes.
//
// UI Overhaul: adds ProxHeroEntrance (scale+fade for hero elements —
// logos never rotate; ring sweeps may), ProxPulseGlow (ambient breathing
// glow), and enhanced ProxFadeSlideIn with optional scale parameter.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Fade + slide + scale entrance. The default "screen belongs to the same
/// product" transition for sections, cards, and empty states.
///
/// Never delays the child becoming interactive: the child is laid out and
/// hittable on frame one; only its opacity/offset/scale animates in.
class ProxFadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;
  final Curve curve;
  final double slideDy;

  /// Optional scale entrance (0.95→1.0 for premium feel). Set to 1.0 to
  /// disable scale animation.
  final double scaleFrom;

  const ProxFadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = ProxDurations.small,
    this.curve = ProxCurves.standard,
    this.slideDy = 0.08,
    this.scaleFrom = 0.97,
  });

  @override
  State<ProxFadeSlideIn> createState() => _ProxFadeSlideInState();
}

class _ProxFadeSlideInState extends State<ProxFadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: widget.duration);
    final curved = CurvedAnimation(parent: _c, curve: widget.curve);
    _opacity = curved;
    _offset = Tween<Offset>(
      begin: Offset(0, widget.slideDy),
      end: Offset.zero,
    ).animate(curved);
    _scale = Tween<double>(
      begin: widget.scaleFrom,
      end: 1.0,
    ).animate(curved);
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void didUpdateWidget(ProxFadeSlideIn old) {
    super.didUpdateWidget(old);
    if (old.duration != widget.duration) {
      _c.duration = widget.duration;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ProxMotion.reduced(context)) return widget.child;
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _offset,
        child: ScaleTransition(
          scale: _scale,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Staggered column: each child fades/slides in with a capped stagger so
/// long class lists finish staging quickly and never block scrolling.
///
/// Usage: wrap list children built in a loop. For live streams prefer
/// [ProxStaggerItem] per row so inserts animate without rebuilding all.
class ProxStaggered extends StatelessWidget {
  final List<Widget> children;
  final Duration step;

  const ProxStaggered({
    super.key,
    required this.children,
    this.step = ProxDurations.staggerStep,
  });

  @override
  Widget build(BuildContext context) {
    if (ProxMotion.reduced(context)) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++)
          ProxFadeSlideIn(
            delay: Duration(
              milliseconds: (i * step.inMilliseconds)
                  .clamp(0, ProxDurations.staggerCap.inMilliseconds),
            ),
            child: children[i],
          ),
      ],
    );
  }
}

/// AnimatedSwitcher with the app-standard fade+slide. Use for any
/// system-driven text swap (counters, status lines, verdict titles) so
/// incoming data never causes a rebuild-flash.
class ProxSwitcher extends StatelessWidget {
  final Widget child;
  final Duration duration;

  const ProxSwitcher({
    super.key,
    required this.child,
    this.duration = ProxDurations.medium,
  });

  @override
  Widget build(BuildContext context) {
    final d = ProxMotion.effective(context, duration);
    if (d == Duration.zero) return child;
    return AnimatedSwitcher(
      duration: d,
      switchInCurve: ProxCurves.standard,
      switchOutCurve: ProxCurves.standard,
      transitionBuilder: (c, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.15),
            end: Offset.zero,
          ).animate(anim),
          child: c,
        ),
      ),
      child: child,
    );
  }
}

/// Hero entrance: scale from 0.8 + fade (no rotation anywhere).
/// Used for welcome hero, verdict badges, and course page headers.
/// 600ms with emphasized curve for a premium reveal.
class ProxHeroEntrance extends StatefulWidget {
  final Widget child;
  final Duration delay;

  const ProxHeroEntrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
  });

  @override
  State<ProxHeroEntrance> createState() => _ProxHeroEntranceState();
}

class _ProxHeroEntranceState extends State<ProxHeroEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: ProxDurations.heroEntrance,
    );
    final curved = CurvedAnimation(
      parent: _c,
      curve: ProxCurves.emphasized,
    );
    _opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _c,
        curve: const Interval(0, 0.6, curve: Curves.easeOut),
      ),
    );
    _scale = Tween<double>(begin: 0.8, end: 1.0).animate(curved);

    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ProxMotion.reduced(context)) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Opacity(
        opacity: _opacity.value,
        child: Transform.scale(
          scale: _scale.value,
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// Ambient breathing glow: opacity pulses 0.15→0.35 over 2s.
/// Used for live/active state indicators (radar ring, presence dot halo).
/// Timer-driven, reduce-motion safe — degrades to static mid-opacity.
class ProxPulseGlow extends StatefulWidget {
  final Color color;
  final double blurRadius;
  final Widget child;

  const ProxPulseGlow({
    super.key,
    required this.color,
    this.blurRadius = 24,
    required this.child,
  });

  @override
  State<ProxPulseGlow> createState() => _ProxPulseGlowState();
}

class _ProxPulseGlowState extends State<ProxPulseGlow> {
  Timer? _timer;
  var _bright = false;
  var _armed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_armed) return;
    _armed = true;
    if (!ProxMotion.reduced(context)) {
      _timer = Timer.periodic(ProxDurations.glow, (_) {
        if (!mounted) return;
        setState(() => _bright = !_bright);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opacity = ProxMotion.reduced(context)
        ? 0.25
        : (_bright ? 0.35 : 0.15);

    // Instant steps (same settle-safe pattern as ProxDot): a continuous
    // implicit animation here would schedule endless frames and
    // pumpAndSettle would never complete. The 2s cadence keeps the
    // breathing readable without motion smoothing.
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: widget.color.withValues(alpha: opacity),
            blurRadius: widget.blurRadius,
            spreadRadius: 2,
          ),
        ],
      ),
      child: widget.child,
    );
  }
}
