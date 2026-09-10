// Live session header (prof live, §7.1): the mid-class always-on block —
// LIVE/IDLE state, elapsed open time, present/waiting counters, and the
// Start ⇄ Stop control cluster. Nothing else is always-on mid-class.
//
// Presentation rebuild (behavior frozen): the fixed header picks up
// `gradient.brand` while state is LIVE and stays flat `surface.raised`
// while IDLE (§2.5) — the one flourish on the professor surface, since it
// answers "is this actually running" at a glance. Verdict vocabulary
// (`Start`/`Stop`/`Retake round N`/`Take another round`/`End attendance`),
// the elapsed `mm:ss` clock, and the present/waiting denominator rule are
// byte-identical to the pre-rebuild header.
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
    final c = ProximityColors.of(context);
    // Denominator prefers the live waiting count (who could still mark);
    // falls back to present so the counter never reads 0/0 mid-round.
    final denom = waiting > 0 ? waiting : (present > 0 ? present : 0);
    final onWash = live;
    // Contrast (§9, checked against the DARKEST stop — no exemptions): a
    // full-opacity `gradient.brand` wash under `contentPrimary` body text
    // measures 2.85:1 (dark) / 3.49:1 (light) — both below AA body text —
    // and outlined-button labels on it fail outright (~1.4–1.6:1). So LIVE
    // renders the TOKEN gradient at 20% alpha over `surfaceRaised`
    // (stops/begin/end still the token's — never hand-authored), which
    // measures, against the effective surface: dark ink 11.99, dark
    // outlined-label 6.68, dark LIVE ring 4.21 (≥3 non-text); light ink
    // 13.76, light outlined-label 5.42, light ring 3.95. The gradient =
    // "running" signal (§2.5) is preserved as a brand tint + LIVE word +
    // pulsing dot; IDLE stays flat `surfaceRaised`.
    final ink = c.contentPrimary;
    return AnimatedContainer(
      duration: ProxDurations.small,
      curve: ProxCurves.standard,
      padding: const EdgeInsets.all(ProxSpacing.cardPadding),
      decoration: BoxDecoration(
        // The one professor flourish (§2.5): gradient while LIVE, flat
        // raised surface while IDLE. Never a hand-authored gradient: the
        // LIVE wash reuses the token's own begin/end/stops at 20% alpha
        // over `surfaceRaised` (see the contrast note above).
        color: c.surfaceRaised,
        gradient: onWash
            ? LinearGradient(
                begin: c.gradientBrand.begin,
                end: c.gradientBrand.end,
                colors: [
                  for (final stop in c.gradientBrand.colors)
                    stop.withValues(alpha: 0.2),
                ],
              )
            : null,
        borderRadius: ProxRadii.cardSpecRadius,
        border: Border.all(
          color: onWash ? c.contentPrimary.withValues(alpha: 0.35) : c.divider,
        ),
        boxShadow: [c.elevationRaised],
      ),
      child: Row(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                liveElapsedLabel(elapsed),
                style: ProxType.title(color: ink),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
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
                  const SizedBox(width: ProxSpacing.sm),
                  Text(
                    live ? 'LIVE' : 'IDLE',
                    style:
                        ProxType.label(color: ink).copyWith(letterSpacing: 3),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(width: ProxSpacing.lg),
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
                    style: ProxType.caption(color: ink),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
                if (hostLine != null)
                  Padding(
                    padding: const EdgeInsets.only(top: ProxSpacing.xs),
                    child: Text(
                      hostLine!,
                      style: ProxType.caption(color: ink),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                const SizedBox(height: ProxSpacing.sm),
                // Start ⇄ Stop control cluster cross-fades (continuation,
                // not a hard swap) — the single most "alive" moment in
                // the app. Actions fire immediately; only the visuals
                // transition.
                ProxSwitcher(
                  child: Wrap(
                    key: ValueKey<bool>(live),
                    spacing: ProxSpacing.sm,
                    runSpacing: ProxSpacing.sm,
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
                            onPressed: (!hosting) ? null : onRetake,
                            expanded: false,
                          ),
                          ProxPrimaryButton(
                            label: const Text('Take another round'),
                            onPressed: (!hosting) ? null : onTakeAnother,
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
