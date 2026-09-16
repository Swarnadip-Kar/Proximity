// Verdict shared actions (student mark): the manual-request fallback at
// fallback weight plus the unified back-to-browse action.
//
// Single-purpose split from `verdict_view.dart` (Mark slim-down): every
// terminal verdict wires the SAME two actions — back lands directly on
// mark/browse in one step (never stepping through waiting/face/proving),
// and non-Marked verdicts offer the manual fallback behind a button →
// confirmation sheet, never inline (§6.4). All copy verbatim (frozen).
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../widgets/fallback_button.dart';
import '../../widgets/prox_buttons.dart';

/// Manual-request fallback at fallback weight (button → confirmation
/// sheet, never inline): shown on non-Marked verdicts only, never
/// competing with the primary verdict display.
class VerdictManualFallback extends StatelessWidget {
  final VoidCallback onRequest;

  const VerdictManualFallback({super.key, required this.onRequest});

  @override
  Widget build(BuildContext context) {
    return FallbackButton(
      label: 'Request manual attendance',
      sheetTitle: 'Request manual attendance',
      icon: Icons.how_to_reg,
      sheetBuilder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              onRequest();
            },
            child: const Text('Request manual attendance'),
          ),
          const SizedBox(height: ProxSpacing.sm),
          TextButton(
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

/// Unified verdict back: one step directly to mark/browse (the host resets
/// the mark-tab phase to browsing — never waiting/face/proving). Same
/// frozen label the wrong-org verdict already carried.
class VerdictBackToClasses extends StatelessWidget {
  final VoidCallback onBack;

  const VerdictBackToClasses({super.key, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return ProxPrimaryButton(
      label: const Text('Back to classes'),
      onPressed: onBack,
      expanded: false,
    );
  }
}
