// Manual request status (student mark): the manual-fallback branch off
// the waiting room. Sends the request, then polls the professor decision
// (pending → approved/rejected). Approved marks present; rejected parks
// with the verdict (present-or-absent ACK) instead of looping.
library;

import 'package:flutter/material.dart';

import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_states.dart';

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
    final decided = status == 'approved' || status == 'rejected';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.how_to_reg, size: 48),
            const SizedBox(height: 12),
            Text(
              switch (status) {
                'approved' =>
                  'Manual attendance approved — marked present.',
                'rejected' =>
                  'Manual request declined (marked absent) — see professor.',
                _ => 'Manual request sent — waiting for professor approval…',
              },
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            if (!decided) const ProxLoadingRow(label: 'Waiting…'),
            const SizedBox(height: 12),
            ProxSecondaryButton(
              label: const Text('Back'),
              onPressed: onBack,
            ),
          ],
        ),
      ),
    );
  }
}
