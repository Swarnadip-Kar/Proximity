// Proving (student mark): the radio wait after the face passes. The
// student never sees a countdown or round timing — only what is happening
// right now: waiting → signal heard → proof sent → confirming. Each step
// swaps in place via [ProxSwitcher] (system-driven, eased).
library;

import 'package:flutter/material.dart';

import '../../widgets/prox_motion.dart';
import '../../widgets/prox_states.dart';

class ProvingView extends StatelessWidget {
  final String status;
  /// Clock-drift banner copy from the student driver's tracker (null when
  /// clocks agree): shown honestly instead of verdicting late silently.
  final String? driftBanner;

  const ProvingView({
    super.key,
    required this.status,
    this.driftBanner,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ProxLoadingRow(label: 'Proving…'),
            const SizedBox(height: 12),
            ProxSwitcher(
              child: Text(
                status,
                key: ValueKey<String>(status),
              ),
            ),
            if (driftBanner != null) ...[
              const SizedBox(height: 8),
              Text(
                driftBanner!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
