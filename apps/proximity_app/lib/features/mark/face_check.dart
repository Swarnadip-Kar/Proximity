// Face check (student mark): Samsung-style seamless scan — it starts by
// itself the moment this step appears (zero taps); the Scan button stays
// as fallback/retry. The radio keeps listening under the camera UI (one
// small pulsing dot + caption, no radar dump).
//
// Inconclusive scans never burn an attempt: the notice swaps in place via
// [ProxSwitcher] and auto-retries relaunch from here.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../widgets/animated.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';

class FaceCheckView extends StatelessWidget {
  final String faceNotice;
  final bool canScan;
  final VoidCallback onScan;

  const FaceCheckView({
    super.key,
    required this.faceNotice,
    required this.canScan,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FaceOval(
                progress: 1.0, prompt: 'Position your face in the oval'),
            const SizedBox(height: 8),
            const Text(
                'Professor started marking — look at the camera, scanning starts by itself.'),
            // Ambient BLE indicator: the radio keeps listening under
            // the camera UI. One small pulsing dot + caption — visible
            // without distracting from the scan.
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ProxDot(
                  color: ProxStateColors.of(context, ProxState.active),
                  pulse: true,
                  size: 8,
                ),
                const SizedBox(width: 6),
                Text(
                  'BLE listening',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
            if (faceNotice.isNotEmpty) ...[
              const SizedBox(height: 8),
              ProxSwitcher(
                child: Text(
                  faceNotice,
                  key: ValueKey<String>(faceNotice),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            const SizedBox(height: 8),
            ProxPrimaryButton(
              icon: const Icon(Icons.face),
              label: const Text('Scan face'),
              onPressed: !canScan ? null : onScan,
              expanded: false,
            ),
          ],
        ),
      ),
    );
  }
}
