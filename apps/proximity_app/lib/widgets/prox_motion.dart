// Shared motion primitives. All animation state stays local to these
// widgets — never in global providers (per project constraints).
//
// Every duration routes through [ProxMotion.effective] so the platform
// reduce-motion setting degrades to instant-but-correct state changes.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Fade + slide entrance. The default "screen belongs to the same product"
/// transition for sections, cards, and empty states.
///
/// Never delays the child becoming interactive: the child is laid out and
/// hittable on frame one; only its opacity/offset animates in.
class ProxFadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;
  final Curve curve;
  final double slideDy;

  const ProxFadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = ProxDurations.small,
    this.curve = ProxCurves.standard,
    this.slideDy = 0.08,
  });

  @override
  State<ProxFadeSlideIn> createState() => _ProxFadeSlideInState();
}

class _ProxFadeSlideInState extends State<ProxFadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: widget.duration);
    _opacity = CurvedAnimation(parent: _c, curve: widget.curve);
    _offset = Tween<Offset>(
      begin: Offset(0, widget.slideDy),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _c, curve: widget.curve));
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
      child: SlideTransition(position: _offset, child: widget.child),
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
            begin: const Offset(0, 0.25),
            end: Offset.zero,
          ).animate(anim),
          child: c,
        ),
      ),
      child: child,
    );
  }
}
