// Glassmorphism surface pane — frosted translucent container for overlays,
// bottom sheets, bottom bars, and the system log terminal.
//
// Uses BackdropFilter for the blur + a semi-transparent tint overlay +
// a subtle highlight border on the top/left edges for the glass depth cue.
// The blur clips to the widget bounds only (never full-screen) to avoid
// compositing the BLE/camera surfaces underneath on live screens.
//
// Reduce-motion: blur stays (it's not motion), only animated transforms
// around the glass degrade under ProxMotion.reduced.
library;

import 'dart:ui';

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Frosted glass surface. Content renders on top of the blur + tint.
class ProxGlassPane extends StatelessWidget {
  final Widget child;
  final ProxGlassSpec? spec;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;

  const ProxGlassPane({
    super.key,
    required this.child,
    this.spec,
    this.borderRadius = BorderRadius.zero,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final glass = spec ?? ProxGlass.of(context);

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: glass.blurSigma,
          sigmaY: glass.blurSigma,
        ),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: glass.tintColor.withValues(alpha: glass.tintOpacity),
            borderRadius: borderRadius,
            border: Border.all(color: glass.borderColor, width: 0.5),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Glass-backed bottom bar container. Provides the frosted surface for
/// the navigation bar while allowing content to scroll behind it.
class ProxGlassBottomBar extends StatelessWidget {
  final Widget child;

  const ProxGlassBottomBar({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ProxGlassPane(
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(20),
      ),
      child: SafeArea(
        top: false,
        child: child,
      ),
    );
  }
}
