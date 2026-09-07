// Live session header (prof live): the mid-class always-on block —
// LIVE/IDLE state, elapsed open time, present/waiting counters, and the
// Start ⇄ Stop control cluster. Nothing else is always-on mid-class.
//
// Motion intent: the elapsed tick rebuilds in place (keyed rows elsewhere
// never replay entrances); the control cluster cross-fades via
// [ProxSwitcher] so Start ⇄ Stop reads as a continuation, not a hard
// swap. Actions fire immediately — only the visuals transition.
// Counters are fed at build time from the live tally, never cached, so
// they cannot go stale during transitions.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../widgets/animated.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';

/// Open-window elapsed clock (mm:ss, unbounded — Stop ends it).
String liveElapsedLabel(Duration elapsed) {
  final s = elapsed.inSeconds;
  final mm = (s ~/ 60).toString().padLeft(2, '0');
  final ss = (s % 60).toString().padLeft(2, '0');
  return '$mm:$ss';
}

class LiveSessionHeader extends StatelessWidget {
  final bool live;
  final Duration elapsed;
  final int present;
  final int waiting;
  final int windowsTaken;
  final int windowNo;
  final bool hosting;
  final String? hostLine;

  final VoidCallback onStart;
  final VoidCallback onRetake;
  final VoidCallback onTakeAnother;
  final VoidCallback onStop;
  final VoidCallback onEnd;

  const LiveSessionHeader({
    super.key,
    required this.live,
    required this.elapsed,
    required this.present,
    required this.waiting,
    required this.windowsTaken,
    required this.windowNo,
    required this.hosting,
    required this.hostLine,
    required this.onStart,
    required this.onRetake,
    required this.onTakeAnother,
    required this.onStop,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    // Denominator prefers the live waiting count (who could still mark);
    // falls back to present so the counter never reads 0/0 mid-round.
    final denom = waiting > 0 ? waiting : (present > 0 ? present : 0);
    return AnimatedContainer(
      duration: ProxDurations.small,
      curve: ProxCurves.standard,
      padding: const EdgeInsets.all(ProxSpacing.md),
      decoration: BoxDecoration(
        color: live
            ? Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.45)
            : Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.35),
        borderRadius: ProxRadii.cardRadius,
        border: Border.all(
          color: live
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)
              : Theme.of(context)
                  .colorScheme
                  .outlineVariant
                  .withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                liveElapsedLabel(elapsed),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ProxDot(
                    color: live
                        ? ProxStateColors.of(context, ProxState.active)
                        : ProxStateColors.of(context, ProxState.neutral),
                    pulse: live,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    live ? 'LIVE' : 'IDLE',
                    style: const TextStyle(letterSpacing: 3),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PresentTicker(present: present, total: denom),
                ProxSwitcher(
                  child: Text(
                    windowsTaken <= 1
                        ? 'Window 1 · $present present / $denom waiting'
                        : 'Windows 1–$windowNo ($windowsTaken taken) · intersection $present / $denom waiting',
                    key: ValueKey<String>(
                        '$windowsTaken-$windowNo-$present-$denom'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (hostLine != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(hostLine!,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                const SizedBox(height: 8),
                // Start ⇄ Stop control cluster cross-fades (continuation,
                // not a hard swap) — the single most "alive" moment in
                // the app. Actions fire immediately; only the visuals
                // transition.
                ProxSwitcher(
                  child: Wrap(
                    key: ValueKey<bool>(live),
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (live) ...[
                        ProxPrimaryButton(
                          label: const Text('Stop'),
                          onPressed: onStop,
                          expanded: false,
                        ),
                      ] else ...[
                        if (windowNo == 0)
                          ProxPrimaryButton(
                            label: const Text('Start'),
                            onPressed: (!hosting) ? null : onStart,
                            expanded: false,
                          )
                        else ...[
                          // Retake resumes the stopped round: same round
                          // number, fresh secrets, marks merge into it
                          // (no new intersection hurdle). Take another
                          // round opens a new round instead.
                          ProxPrimaryButton(
                            label: Text('Retake round $windowNo'),
                            onPressed:
                                (!hosting) ? null : onRetake,
                            expanded: false,
                          ),
                          ProxPrimaryButton(
                            label: const Text('Take another round'),
                            onPressed:
                                (!hosting) ? null : onTakeAnother,
                            expanded: false,
                          ),
                          ProxSecondaryButton(
                            label: const Text('End attendance'),
                            onPressed: (!hosting) ? null : onEnd,
                          ),
                        ],
                        if (windowNo == 0)
                          ProxSecondaryButton(
                            label: const Text('End attendance'),
                            onPressed: (!hosting) ? null : onEnd,
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
