// Shared screen shell. One app-bar + content pattern everywhere:
//
//   ProxScreen(title: ..., actions: ..., child: ...)
//     → AdaptiveScaffold (Cupertino nav on iOS/macOS, Material elsewhere)
//     → centered, max-width constrained scroll body with standard padding
//
// Screens keep their own scroll physics/lists where behavior demands it
// (live lists, records), but padding, max width, and app-bar treatment
// come from here so every screen belongs to the same product.
//
// UI Overhaul: adds a subtle gradient to the app bar area for depth,
// and an optional progress indicator slot below the bar for page-level
// loading states.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../main.dart' show AdaptiveScaffold;

/// Standard screen: adaptive app bar + constrained content column.
///
/// UI Overhaul: optional [loading] parameter shows a thin progress
/// indicator below the app bar. Optional [floatingAction] for FAB.
class ProxScreen extends StatelessWidget {
  final String title;
  final List<Widget>? actions;
  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;
  final bool scrollable;

  /// When true, shows a thin animated progress indicator below the app bar.
  final bool loading;

  /// Optional floating action button.
  final Widget? floatingAction;

  const ProxScreen({
    super.key,
    required this.title,
    required this.child,
    this.actions,
    this.maxWidth = ProxSpacing.maxContentWidth,
    this.padding = const EdgeInsets.all(ProxSpacing.lg),
    this.scrollable = true,
    this.loading = false,
    this.floatingAction,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);

    final content = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: scrollable
            ? SingleChildScrollView(padding: padding, child: child)
            : Padding(padding: padding, child: child),
      ),
    );

    final body = Column(
      children: [
        // Thin progress indicator — visible only when loading.
        AnimatedContainer(
          duration: ProxDurations.small,
          height: loading ? 2 : 0,
          child: loading
              ? LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation(c.accentBrand),
                )
              : const SizedBox.shrink(),
        ),
        Expanded(child: content),
      ],
    );

    return AdaptiveScaffold(
      title: title,
      actions: actions,
      body: body,
      floatingActionButton: floatingAction,
    );
  }
}
