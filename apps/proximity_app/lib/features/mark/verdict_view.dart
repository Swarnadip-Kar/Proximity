// Verdict (student mark): Marked / Late / No-signal / Error, each with a
// distinct motion signature owned by [ProxVerdictBadge] (marked pops,
// late rises, no-signal breathes, error shakes — meaning is always carried
// by icon + label first, so reduced-motion still reads correctly).
//
// Every verdict carries the per-round trail ('R1 · KQ7 …') for the join so
// far. Marked parks here (stay-put copy) until the round ends, then the
// flow rejoins the waiting room automatically — zero taps, face re-checks
// every round. Hosting-ended (unreachable server) never parks: the badge
// leaves for the live list instead of a dead waiting room.
library;

import 'package:flutter/material.dart';

import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_verdict.dart';
import '../../widgets/trust_cards.dart';

enum MarkVerdict { marked, late, wrongOrg, needsReview, noSignal }

class MarkVerdictView extends StatelessWidget {
  final MarkVerdict kind;
  final String detail;
  final String infoDetail;
  /// Real orgs for the wrong-org card (Track 6, from
  /// [MarkedReceipt.classOrg]/[myOrg]); '' falls back to the generic
  /// placeholders so older call sites keep compiling unchanged.
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

  @override
  Widget build(BuildContext context) {
    return switch (kind) {
      MarkVerdict.marked => Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ProxVerdictBadge.marked(detail: detail),
                if (roundMarks.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'This session: ${roundMarks.join(' · ')}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Stay put — the next round rejoins automatically.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      MarkVerdict.late => Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ProxVerdictBadge.late(detail: detail),
                if (roundMarks.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'This session: ${roundMarks.join(' · ')}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      MarkVerdict.wrongOrg => Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                WrongOrgCard(
                  classOrg:
                      classOrg.isNotEmpty ? classOrg : 'this class',
                  myOrg: myOrg.isNotEmpty ? myOrg : 'your account',
                ),
                const SizedBox(height: 8),
                Text(
                  detail.isEmpty
                      ? 'No proof was sent — join your institute class instead.'
                      : detail,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                ProxPrimaryButton(
                  label: const Text('Back to classes'),
                  onPressed: onBack,
                  expanded: false,
                ),
              ],
            ),
          ),
        ),
      MarkVerdict.needsReview => Center(
          child: ProxFadeSlideIn(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                    'Face check didn\'t match the enrolled face — try again in good light, holding still.'),
                const SizedBox(height: 12),
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
                  ProxSecondaryButton(
                    icon: const Icon(Icons.how_to_reg),
                    label: const Text('Request manual attendance instead'),
                    onPressed: onManualInstead,
                  ),
                const SizedBox(height: 8),
                ProxSecondaryButton(
                  label: const Text('Back'),
                  onPressed: onBack,
                ),
              ],
            ),
          ),
        ),
      MarkVerdict.noSignal => Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ProxVerdictBadge(
                  kind: ProxVerdictKind.noSignal,
                  title: 'No signal',
                  detail: infoDetail.isNotEmpty ? infoDetail : detail,
                ),
                const SizedBox(height: 12),
                ProxPrimaryButton(
                  label: const Text('Try again'),
                  onPressed: onBack,
                  expanded: false,
                ),
              ],
            ),
          ),
        ),
    };
  }
}
