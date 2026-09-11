// Shared cards + list tiles. Every course/session/student/attendance row
// in the app is one of these — no screen hand-rolls its own Card+ListTile
// with bespoke padding, shape, or entrance timing.
//
// UI Overhaul: cards now use gradient surface fills (subtle on dark, clean
// on light), refined borders (inner-glow dark, hairline light), and the
// 4-level shadow ramp. ProxDot gains a glow halo behind the pulse.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import 'prox_motion.dart';

/// Standard content card. Refined surface with subtle depth cues:
/// - Dark: inner-glow border (white 8%) on darker fill, rest shadow
/// - Light: hairline border, clean white fill, softer shadow
/// - Hover (desktop): lifts to hover shadow with smooth transition
class ProxCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  const ProxCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(ProxSpacing.lg),
    this.onTap,
  });

  @override
  State<ProxCard> createState() => _ProxCardState();
}

class _ProxCardState extends State<ProxCard> with HoverGrace {
  var _hovering = false;

  @override
  void dispose() {
    cancelHoverGrace();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    // ROOT CAUSE of the desktop hover/exit flicker: hover used to swap
    // BoxShadow geometry (rest blur 2 / offset 0,1 ⇄ hover blur 12 /
    // offset 0,4). Every enter AND exit re-rasterized a different blur
    // kernel — on macOS that pops on both directions, and animated
    // versions re-rasterized every frame. Instant swaps still pop.
    // FIX: hover never touches the shadow. The shadow stays at `rest`
    // geometry always; hover only re-tints the cheap solid-fill border
    // (no blur re-raster, no layout/hit-test change, so no enter/exit
    // loop either). Border width stays 1.0 (width lerps re-tessellate).
    final shadow = ProxShadows.rest(context);
    final card = Container(
      decoration: BoxDecoration(
        borderRadius: ProxRadii.cardSpecRadius,
        boxShadow: [shadow],
      ),
      child: AnimatedContainer(
        duration: ProxDurations.small,
        curve: ProxCurves.standard,
        padding: const EdgeInsets.all(ProxSpacing.cardPadding),
        decoration: BoxDecoration(
          // Subtle vertical gradient: raised → overlay-blend. Adds depth
          // over flat fills while staying quiet on both themes.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              c.surfaceRaised,
              Color.lerp(c.surfaceRaised, c.surfaceOverlay, 0.55)!,
            ],
          ),
          borderRadius: ProxRadii.cardSpecRadius,
          border: Border.all(
            color: _hovering ? c.accentBrand : c.divider,
          ),
        ),
        child: widget.child,
      ),
    );

    if (widget.onTap == null) return card;

    return MouseRegion(
      onEnter: (_) => hoverEnter(() => setState(() => _hovering = true)),
      onExit: (_) => hoverExit(() => setState(() => _hovering = false)),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: card,
      ),
    );
  }
}

/// Hover exit-grace shared by the hoverable cards/tiles below (and
/// [StudentCard]): clearing the highlight waits 80ms so a spurious exit
/// — trackpad jitter at an edge, transient unmount noise on desktop —
/// that re-enters inside the window never drops the highlight. 80ms is
/// deliberately sub-perceptual: a genuine exit (e.g. off the last card,
/// where no neighbour takes over) still reads as instant, while jitter
/// gaps (1–2 frames) are covered. Enter is always instant. Dispose must
/// call [cancelHoverGrace].
mixin HoverGrace<T extends StatefulWidget> on State<T> {
  Timer? _hoverGraceTimer;

  void cancelHoverGrace() {
    _hoverGraceTimer?.cancel();
    _hoverGraceTimer = null;
  }

  /// Enter path: cancel any pending clear, then run [apply] now.
  void hoverEnter(VoidCallback apply) {
    _hoverGraceTimer?.cancel();
    apply();
  }

  /// Exit path: run [clear] after the grace window unless [hoverEnter]
  /// cancels first.
  void hoverExit(VoidCallback clear) {
    _hoverGraceTimer?.cancel();
    _hoverGraceTimer = Timer(const Duration(milliseconds: 80), () {
      if (!mounted) return;
      clear();
    });
  }
}

/// One tappable row: leading icon/dot, title, subtitle, trailing. Replaces
/// the dozen bespoke ListTile-in-Card copies across course/session/student
/// lists. Entrance stagger is opt-in via [staggerIndex] (null = no delay).
///
/// UI Overhaul: trailing chevron animates on hover, subtle left accent
/// appears on active/hover state.
class ProxListTile extends StatefulWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final int? staggerIndex;
  final Key? tileKey;

  /// Dense rows for search-hit lists (directory cards, roster hits).
  final bool dense;

  const ProxListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.staggerIndex,
    this.tileKey,
    this.dense = false,
  });

  @override
  State<ProxListTile> createState() => _ProxListTileState();
}

class _ProxListTileState extends State<ProxListTile> with HoverGrace {
  var _hovering = false;

  @override
  void dispose() {
    cancelHoverGrace();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);

    final tile = MouseRegion(
      onEnter: (_) => hoverEnter(() => setState(() => _hovering = true)),
      onExit: (_) => hoverExit(() => setState(() => _hovering = false)),
      // Same no-shadow-geometry rule as ProxCard above: shadow stays at
      // `rest` always, only the cheap tint animates — no blur re-raster,
      // no enter/exit loop, no macOS edge-crossing flicker.
      child: Container(
        decoration: BoxDecoration(
          borderRadius: ProxRadii.cardSpecRadius,
          boxShadow: [ProxShadows.rest(context)],
        ),
        child: AnimatedContainer(
          duration: ProxDurations.micro,
          curve: ProxCurves.standard,
          decoration: BoxDecoration(
            color: _hovering
                ? c.accentBrand.withValues(alpha: 0.04)
                : c.surfaceRaised,
            borderRadius: ProxRadii.cardSpecRadius,
            border: Border.all(color: c.divider),
          ),
          child: Material(
            color: Colors.transparent,
            child: ListTile(
            key: widget.tileKey,
            dense: widget.dense,
            leading: widget.leading,
            title: Text(
              widget.title,
              style: ProxType.body(color: c.contentPrimary),
            ),
            subtitle: widget.subtitle == null
                ? null
                : Text(
                    widget.subtitle!,
                    style: ProxType.caption(color: c.contentSecondary),
                  ),
            trailing: widget.trailing ??
                (widget.onTap != null
                    ? AnimatedSlide(
                        duration: ProxDurations.micro,
                        offset: Offset(_hovering ? 0.15 : 0, 0),
                        child: Icon(
                          Icons.chevron_right,
                          color: c.contentTertiary,
                          size: ProxIconSizes.md,
                        ),
                      )
                    : null),
            onTap: widget.onTap,
            shape: RoundedRectangleBorder(
              borderRadius: ProxRadii.cardSpecRadius,
            ),
          ),
          ),
        ),
      ),
    );

    final i = widget.staggerIndex;
    if (i == null || ProxMotion.reduced(context)) return tile;
    return ProxFadeSlideIn(
      delay: Duration(
        milliseconds: (i * ProxDurations.staggerStep.inMilliseconds)
            .clamp(0, ProxDurations.staggerCap.inMilliseconds),
      ),
      child: tile,
    );
  }
}

/// Small colored dot for live/presence indication. Pulses only when
/// [pulse] is true (professor LIVE, student BLE-active) — static otherwise
/// so idle lists stay calm and cheap.
///
/// UI Overhaul: gains a soft glow halo behind the dot when pulsing,
/// radiating the dot's color for a more alive feel.
///
/// Implementation note: the pulse is timer-driven (periodic toggle +
/// implicit fade), never an infinite ticker — so widget tests using
/// `pumpAndSettle` still settle and the dot costs ~1 rebuild per 800ms.
class ProxDot extends StatefulWidget {
  final Color color;
  final bool pulse;
  final double size;

  const ProxDot({
    super.key,
    required this.color,
    this.pulse = false,
    this.size = 10,
  });

  @override
  State<ProxDot> createState() => _ProxDotState();
}

class _ProxDotState extends State<ProxDot> {
  Timer? _timer;
  var _dim = false;

  @override
  void initState() {
    super.initState();
    // First arm happens in didChangeDependencies (MediaQuery is readable
    // there; initState may not register inherited dependencies).
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void didUpdateWidget(ProxDot old) {
    super.didUpdateWidget(old);
    if (widget.pulse != old.pulse) _syncTimer();
  }

  /// Arms the pulse only while it is visible: static (and timer-free)
  /// when [ProxDot.pulse] is false or reduced motion is on, so idle and
  /// reduced-motion lists never pay for a periodic rebuild.
  void _syncTimer() {
    final want = widget.pulse && !ProxMotion.reduced(context);
    if (want && _timer == null) {
      _timer = Timer.periodic(ProxDurations.dotPulse, (_) {
        if (!mounted) return;
        setState(() => _dim = !_dim);
      });
    } else if (!want && _timer != null) {
      _timer?.cancel();
      _timer = null;
      _dim = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        // Glow halo: soft radiance behind the dot in its own color.
        boxShadow: widget.pulse
            ? [
                BoxShadow(
                  color: widget.color.withValues(alpha: _dim ? 0.1 : 0.35),
                  blurRadius: widget.size * 1.5,
                  spreadRadius: widget.size * 0.3,
                ),
              ]
            : null,
      ),
    );
    if (!widget.pulse || ProxMotion.reduced(context)) return dot;
    return AnimatedOpacity(
      duration: ProxDurations.dotPulse,
      curve: ProxCurves.standard,
      opacity: _dim ? 0.35 : 1.0,
      child: dot,
    );
  }
}
