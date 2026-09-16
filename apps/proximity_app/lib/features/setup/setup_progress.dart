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

/// Stepper-owned progress overlay for SetupFlowScreen (placement fix).
///
/// Renders ONE [SetupProgressLine] below the step's own app bar — at the
/// body top, inside the top safe area — instead of one line per page above
/// the inner Scaffolds (which painted the blue line over the status bar,
/// above the top bar). The offset is the platform nav-bar height
/// ([kToolbarHeight] Material, 44 Cupertino) inside a top-only [SafeArea],
/// so the line lands on the app-bar/body seam on all form factors; the
/// 3px line occupies the bar's bottom 3px and never covers body content.
/// [IgnorePointer] keeps every app-bar action tappable. Progress semantics
/// ([index]/[count] → value) are unchanged from [SetupProgressLine].
class SetupProgressOverlay extends StatelessWidget {
  /// Currently visible step (0-based).
  final int index;

  /// Total step count.
  final int count;

  const SetupProgressOverlay({
    super.key,
    required this.index,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final barHeight =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS
            ? 44.0
            : kToolbarHeight;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        top: true,
        bottom: false,
        left: false,
        right: false,
        child: IgnorePointer(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: barHeight - 3),
              SetupProgressLine(index: index, count: count),
            ],
          ),
        ),
      ),
    );
  }
}
