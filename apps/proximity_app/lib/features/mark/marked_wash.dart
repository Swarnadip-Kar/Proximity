// Marked celebratory wash (student mark, §6.3, single-use): a full-width
// `gradient.marked` wash with `effect.glow.marked` behind the badge,
// fading over `verdictWash` (400ms). Non-blocking (pure decor beneath the
// content), skippable by tap, and never rendered anywhere else. Under
// reduce-motion it collapses to a flat `status.marked` fill for the same
// beat, then clears — meaning stays on the badge's icon + word.
//
// Single-purpose split from `verdict_view.dart` (Mark slim-down).
//
// Contrast (§9, darkest stop — no exemptions): status-green badge text on
// the green wash measures ~1.1:1 (unreadable), so wash content renders in
// the token-prescribed dark ink `#14161A` via a wash-local
// [ProximityColors] override (badge, trail pills, stay-put line all read
// the override — no component API changes): 8.27:1 on dark's darkest stop
// `#33C77A` (10.60 on the light stop), 5.03:1 on light's darkest stop
// `#1E9A5C` (7.09 on the light stop). Transient 400ms reinforcement, same
// single-use rule.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';

/// Wash-local dark ink for [MarkedWash] content (see its contrast note).
/// Only the two fields wash content reads are overridden — badge + trail
/// pills (`statusMarked`), stay-put line (`contentSecondary`) — so nothing
/// outside the wash can observe the override.
ProximityColors _washInk(ProximityColors c) => c.copyWith(
      statusMarked: const Color(0xFF14161A),
      contentSecondary: const Color(0xFF14161A),
    );

/// The one celebratory wash in the app (§6.3, single-use): a full-width
/// `gradient.marked` wash with `effect.glow.marked` behind the badge,
/// fading over `verdictWash` (400ms). Non-blocking (pure decor beneath the
/// content), skippable by tap, and never rendered anywhere else. Under
/// reduce-motion it collapses to a flat `status.marked` fill for the same
/// beat, then clears — meaning stays on the badge's icon + word.
class MarkedWash extends StatefulWidget {
  /// Builds the wash content. The build context carries the wash-local
  /// dark-ink [ProximityColors] — read colors from it, not from above.
  final WidgetBuilder builder;

  const MarkedWash({super.key, required this.builder});

  @override
  State<MarkedWash> createState() => _MarkedWashState();
}

class _MarkedWashState extends State<MarkedWash> {
  var _visible = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    // Single-use, self-clearing: the wash always lifts, whether or not the
    // fade plays (timer-driven so widget tests still settle).
    _hide = Timer(ProxDurations.verdictWash, () {
      if (!mounted) return;
      setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Wash lifted: normal surface, normal token colors (the dark-ink
    // override only ever applies while the wash is behind the content).
    if (!_visible) return Builder(builder: widget.builder);
    final c = ProximityColors.of(context);
    final reduced = ProxMotion.reduced(context);
    final wash = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        vertical: ProxSpacing.xl,
        horizontal: ProxSpacing.md,
      ),
      decoration: BoxDecoration(
        gradient: reduced ? null : c.gradientMarked,
        color: reduced ? c.statusMarked.withValues(alpha: 0.15) : null,
        borderRadius: ProxRadii.cardSpecRadius,
        boxShadow: reduced ? null : [c.glowMarked.toShadow()],
      ),
      // Wash-local dark ink (see class docs): the builder context reads
      // the override, so badge + trail + line all render in `#14161A`.
      child: Theme(
        data: Theme.of(context).copyWith(
          extensions: <ThemeExtension<dynamic>>[_washInk(c)],
        ),
        child: Builder(builder: widget.builder),
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Skippable-by-tap: one tap lifts the wash early.
      onTap: () {
        _hide?.cancel();
        setState(() => _visible = false);
      },
      child: reduced
          ? wash
          : TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: ProxDurations.verdictWash,
              curve: ProxCurves.standard,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: child,
              ),
              child: wash,
            ),
    );
  }
}
