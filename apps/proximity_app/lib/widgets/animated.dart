import 'package:flutter/material.dart';

import '../design/app_theme.dart';
import '../design/tokens.dart';

/// Animated present-count ticker (counts up, no jank: simple AnimatedSwitcher).
/// Honors reduced motion (instant swap). Kept for the take-attendance header
/// contract.
class PresentTicker extends StatelessWidget {
  final int present;
  final int total;
  const PresentTicker({super.key, required this.present, required this.total});

  @override
  Widget build(BuildContext context) {
    // Single-line + ellipsis: the strip Row bounds this via Flexible, so
    // triple-digit counts shrink text instead of overflowing 360dp.
    final label = Text(
        '$present/$total present',
        key: ValueKey<int>(present),
        style: proxTabular(
            context, Theme.of(context).textTheme.headlineSmall),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        softWrap: false);
    if (ProxMotion.reduced(context)) return label;
    return AnimatedSwitcher(
      duration: ProxDurations.medium,
      transitionBuilder: (child, anim) =>
          SlideTransition(position: Tween<Offset>(begin: const Offset(0, 0.6), end: Offset.zero).animate(anim), child: child),
      child: label,
    );
  }
}
