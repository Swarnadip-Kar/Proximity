// Mark-flow continuation shell (student): waiting → scan → verdict reads
// as ONE flow, never hard cuts.
//
// Every phase hop cross-fades + rises with the screen-level emphasized
// curve ([ProxCurves.emphasized], medium) instead of swapping instantly;
// reduced-motion degrades to an instant-but-correct swap. Actions are
// never gated on the animation — it is purely visual.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import 'mark_phase.dart';

class MarkFlowShell extends StatelessWidget {
  final StudentPhase phase;
  final Widget child;

  const MarkFlowShell({super.key, required this.phase, required this.child});

  @override
  Widget build(BuildContext context) {
    final d = ProxMotion.effective(context, ProxDurations.medium);
    if (d == Duration.zero) return child;
    return AnimatedSwitcher(
      duration: d,
      switchInCurve: ProxCurves.emphasized,
      switchOutCurve: ProxCurves.standard,
      transitionBuilder: (c, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.12),
            end: Offset.zero,
          ).animate(anim),
          child: c,
        ),
      ),
      child: KeyedSubtree(
        key: ValueKey<StudentPhase>(phase),
        child: child,
      ),
    );
  }
}
