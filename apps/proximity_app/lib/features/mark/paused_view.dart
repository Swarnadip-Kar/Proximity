// Paused view (student mark): foreground-required overlay after a real
// backgrounding during proving/face-check. Copy verbatim (frozen).
//
// Single-purpose split from `screens/student_home.dart` (Mark slim-down):
// widget-building only — lifecycle/run-guard orchestration stays on the
// host. Back returns to the join list in one step.
library;

import 'package:flutter/material.dart';

/// Paused overlay: `Paused — reopen` + `Back to join` (verbatim).
class PausedView extends StatelessWidget {
  final VoidCallback onBack;

  const PausedView({super.key, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Paused — reopen'),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: onBack,
            child: const Text('Back to join'),
          ),
        ],
      ),
    );
  }
}
