// Manual request status (student mark): the manual-fallback branch off
// the waiting room. Sends the request, then polls the professor decision
// (pending → approved/rejected). Approved marks present; rejected parks
// with the verdict (present-or-absent ACK) instead of looping.
//
// Restyled only: poll timing, branch copy, and the Back action are
// verbatim from the previous screen. The pending state carries the shared
// `Pending` badge; approved/rejected keep their one-line verdicts.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/verdict_badge.dart';

class ManualRequestView extends StatelessWidget {
  final String status;
  final VoidCallback onBack;

  const ManualRequestView({
    super.key,
    required this.status,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final decided = status == 'approved' || status == 'rejected';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(ProxSpacing.screenMargin),
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: ProxSpacing.maxContentWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!decided) ...[
                const VerdictBadge(status: ProxStatus.pending),
                const SizedBox(height: ProxSpacing.sm),
              ] else ...[
                const Icon(Icons.how_to_reg, size: 48),
                const SizedBox(height: ProxSpacing.md),
              ],
              Text(
                switch (status) {
                  'approved' =>
                    'Manual attendance approved — marked present.',
                  'rejected' =>
                    'Manual request declined (marked absent) — see professor.',
                  _ => 'Manual request sent — waiting for professor approval…',
                },
                textAlign: TextAlign.center,
                style: ProxType.body(color: c.contentPrimary),
              ),
              const SizedBox(height: ProxSpacing.md),
              if (!decided) const ProxLoadingRow(label: 'Waiting…'),
              const SizedBox(height: ProxSpacing.md),
              ProxSecondaryButton(
                label: const Text('Back'),
                onPressed: onBack,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
