// Verdict (student mark): Marked / Late / No-signal / Wrong-org /
// Needs-review, each in the shared `VerdictBadge` shell (icon + word,
// never color alone).
//
// `Marked` is the single highest-weight moment in the app: the badge keeps
// its elastic scale-in plus a brief (400ms, non-blocking, skippable-by-tap)
// full-width `gradient.marked` wash with `effect.glow.marked` behind it,
// fading to the normal surface. That combination fires here and nowhere
// else. Every other outcome uses the same badge shell flat — no flourish.
// Non-Marked verdicts show the per-round trail as pill chips, the verbatim
// one-line next step, and the manual-request fallback button.
//
// Every verdict carries the per-round trail for the join so far. Marked
// parks here (stay-put copy) until the round ends, then the flow rejoins
// the waiting room automatically — zero taps, face re-checks every round.
// Hosting-ended (unreachable server) never parks: the badge leaves for the
// live list instead of a dead waiting room.
//
// Back-after-marking fix: EVERY verdict (including Marked/Late, which
// previously had no back action) carries an explicit back button wired to
// [onBack] — the host resets the mark-tab phase to browsing in one step,
// never stepping through waiting/face/proving. The host wires the same
// teardown to the system-back path.
//
// Modularity: the celebratory wash lives in `marked_wash.dart` and the
// shared actions (manual fallback, back-to-browse) in
// `verdict_actions.dart`. This file owns only the per-verdict composition.
// All verdict copy stays verbatim (frozen).
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/trust_cards.dart';
import '../../widgets/verdict_badge.dart';
import 'marked_wash.dart';
import 'verdict_actions.dart';
import 'waiting_room.dart' show RoundTrailPills;

enum MarkVerdict { marked, late, wrongOrg, needsReview, noSignal }

class MarkVerdictView extends StatelessWidget {
  final MarkVerdict kind;
  final String detail;
  final String infoDetail;

  /// Real orgs for the wrong-org card ('' keeps the generic fallback).
  final String classOrg;
  final String myOrg;
  final List<String> roundMarks;
  final int attemptsLeft;
  final VoidCallback onRetryFace;
  final VoidCallback onManualInstead;
  final VoidCallback onBack;

  const MarkVerdictView({
    super.key,
    required this.kind,
    required this.detail,
    this.infoDetail = '',
    this.classOrg = '',
    this.myOrg = '',
    required this.roundMarks,
    this.attemptsLeft = 0,
    required this.onRetryFace,
    required this.onManualInstead,
    required this.onBack,
  });

  Widget _frame(BuildContext context, Widget child) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(ProxSpacing.screenMargin),
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: ProxSpacing.maxContentWidth),
            child: child,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return switch (kind) {
      MarkVerdict.marked => _frame(
          context,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MarkedWash(
                builder: (washContext) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const VerdictBadge(
                      status: ProxStatus.marked,
                      label: '✓ Marked',
                    ),
                    if (roundMarks.isNotEmpty) ...[
                      const SizedBox(height: ProxSpacing.sm),
                      RoundTrailPills(marks: roundMarks),
                      const SizedBox(height: ProxSpacing.xs),
                      Text(
                        'Stay put — the next round rejoins automatically.',
                        textAlign: TextAlign.center,
                        style: ProxType.body(
                          color:
                              ProximityColors.of(washContext).contentSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Back sits OUTSIDE the wash so the wash tap-to-skip never
              // swallows it. Same one-step teardown as every other verdict.
              const SizedBox(height: ProxSpacing.md),
              VerdictBackToClasses(onBack: onBack),
            ],
          ),
        ),
      MarkVerdict.late => _frame(
          context,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const VerdictBadge(status: ProxStatus.late),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: ProxSpacing.xs),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: ProxType.body(color: c.contentPrimary),
                ),
              ],
              if (roundMarks.isNotEmpty) ...[
                const SizedBox(height: ProxSpacing.sm),
                RoundTrailPills(marks: roundMarks),
                const SizedBox(height: ProxSpacing.xs),
                Text(
                  'Stay put — the next round rejoins automatically.',
                  textAlign: TextAlign.center,
                  style: ProxType.body(color: c.contentSecondary),
                ),
              ],
              const SizedBox(height: ProxSpacing.md),
              VerdictBackToClasses(onBack: onBack),
              const SizedBox(height: ProxSpacing.xs),
              VerdictManualFallback(onRequest: onManualInstead),
            ],
          ),
        ),
      MarkVerdict.wrongOrg => _frame(
          context,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const VerdictBadge(status: ProxStatus.wrongOrg),
              const SizedBox(height: ProxSpacing.sm),
              WrongOrgCard(
                classOrg: classOrg.isNotEmpty ? classOrg : 'this class',
                myOrg: myOrg.isNotEmpty ? myOrg : 'your account',
              ),
              const SizedBox(height: ProxSpacing.sm),
              Text(
                detail.isEmpty
                    ? 'No proof was sent — join your institute class instead.'
                    : detail,
                textAlign: TextAlign.center,
                style: ProxType.caption(color: c.contentSecondary),
              ),
              const SizedBox(height: ProxSpacing.md),
              VerdictBackToClasses(onBack: onBack),
              const SizedBox(height: ProxSpacing.xs),
              VerdictManualFallback(onRequest: onManualInstead),
            ],
          ),
        ),
      MarkVerdict.needsReview => _frame(
          context,
          ProxFadeSlideIn(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const VerdictBadge(status: ProxStatus.review),
                const SizedBox(height: ProxSpacing.sm),
                Text(
                  'Face check didn\'t match the enrolled face — try again in good light, holding still.',
                  textAlign: TextAlign.center,
                  style: ProxType.body(color: c.contentPrimary),
                ),
                const SizedBox(height: ProxSpacing.md),
                // 4 mismatch sessions, then the review queue. Anything
                // unreadable never reaches this screen (the verify
                // session keeps scanning; free auto-relaunches follow).
                if (attemptsLeft > 0)
                  ProxPrimaryButton(
                    icon: const Icon(Icons.refresh),
                    label: Text('Retry face scan ($attemptsLeft left)'),
                    onPressed: onRetryFace,
                    expanded: false,
                  )
                else
                  VerdictManualFallback(onRequest: onManualInstead),
                const SizedBox(height: ProxSpacing.sm),
                ProxSecondaryButton(
                  label: const Text('Back'),
                  onPressed: onBack,
                ),
              ],
            ),
          ),
        ),
      MarkVerdict.noSignal => _frame(
          context,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const VerdictBadge(status: ProxStatus.noSignal),
              if ((infoDetail.isNotEmpty ? infoDetail : detail).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: ProxSpacing.xs),
                  child: Text(
                    infoDetail.isNotEmpty ? infoDetail : detail,
                    textAlign: TextAlign.center,
                    style: ProxType.body(color: c.contentPrimary),
                  ),
                ),
              const SizedBox(height: ProxSpacing.md),
              ProxPrimaryButton(
                label: const Text('Try again'),
                onPressed: onBack,
                expanded: false,
              ),
              const SizedBox(height: ProxSpacing.xs),
              VerdictManualFallback(onRequest: onManualInstead),
            ],
          ),
        ),
    };
  }
}
