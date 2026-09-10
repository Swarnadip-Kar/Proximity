// SetupFlow progress line (§3.3): a thin progress line at the top, no
// numbered circles, no step labels — the current step's title lives in its
// own app bar.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';

/// Thin linear progress for the setup stepper (token-driven, no numbers).
class SetupProgressLine extends StatelessWidget {
  /// Currently visible step (0-based).
  final int index;

  /// Total step count.
  final int count;

  const SetupProgressLine({
    super.key,
    required this.index,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final value =
        count <= 0 ? 0.0 : (index + 1).clamp(1, count).toDouble() / count;
    return LinearProgressIndicator(
      value: value,
      minHeight: 3,
      backgroundColor: c.divider,
      valueColor: AlwaysStoppedAnimation<Color>(c.accentBrand),
    );
  }
}
