// Shared screen shell. One app-bar + content pattern everywhere:
//
//   ProxScreen(title: ..., actions: ..., child: ...)
//     → AdaptiveScaffold (Cupertino nav on iOS/macOS, Material elsewhere)
//     → centered, max-width constrained scroll body with standard padding
//
// Screens keep their own scroll physics/lists where behavior demands it
// (live lists, records), but padding, max width, and app-bar treatment
// come from here so every screen belongs to the same product.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../main.dart' show AdaptiveScaffold;

/// Standard screen: adaptive app bar + constrained content column.
class ProxScreen extends StatelessWidget {
  final String title;
  final List<Widget>? actions;
  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;
  final bool scrollable;

  const ProxScreen({
    super.key,
    required this.title,
    required this.child,
    this.actions,
    this.maxWidth = ProxSpacing.maxContentWidth,
    this.padding = const EdgeInsets.all(ProxSpacing.lg),
    this.scrollable = true,
  });

  @override
  Widget build(BuildContext context) {
    final body = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: scrollable
            ? SingleChildScrollView(padding: padding, child: child)
            : Padding(padding: padding, child: child),
      ),
    );
    return AdaptiveScaffold(title: title, actions: actions, body: body);
  }
}
