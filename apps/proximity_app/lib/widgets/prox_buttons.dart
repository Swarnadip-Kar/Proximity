// Shared buttons. One press language everywhere: user-triggered taps
// scale subtly (spring), actions fire on tap-down semantics — never gated
// behind or delayed by a decorative animation.
//
// UI Overhaul: ProxPrimaryButton now renders with a brand gradient fill
// and a subtle ambient glow. ProxSecondaryButton gets a ghost variant
// with brand-tinted hover state. Both preserve the 0.97 press-scale.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Press-scale wrapper: subtle 0.97 squeeze on tap-down, spring back on
/// release. Visual only — [onPressed] fires immediately on tap-up.
class _PressScale extends StatefulWidget {
  final Widget child;
  final bool enabled;
  const _PressScale({required this.child, required this.enabled});

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  var _down = false;

  @override
  Widget build(BuildContext context) {
    // Listener (not GestureDetector): pointer events never compete with
    // the inner button's tap arena, so onPressed always fires.
    return Listener(
      onPointerDown: widget.enabled ? (_) => setState(() => _down = true) : null,
      onPointerUp: widget.enabled ? (_) => setState(() => _down = false) : null,
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.97 : 1.0,
        // User-triggered tap language: spring squeeze, instant when the
        // OS asks for reduced motion (the tap itself never waits).
        duration: ProxMotion.effective(context, ProxDurations.micro),
        curve: ProxCurves.spring,
        child: widget.child,
      ),
    );
  }
}

/// Primary action (Start, Join, Save, Continue). Renders with a brand
/// gradient fill and a subtle ambient glow. Full-width by default on
/// phone layouts — pass [expanded] false for inline use.
class ProxPrimaryButton extends StatefulWidget {
  final Widget label;
  final VoidCallback? onPressed;
  final Widget? icon;
  final bool expanded;
  final Key? buttonKey;

  const ProxPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expanded = true,
    this.buttonKey,
  });

  @override
  State<ProxPrimaryButton> createState() => _ProxPrimaryButtonState();
}

class _ProxPrimaryButtonState extends State<ProxPrimaryButton> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final enabled = widget.onPressed != null;

    final gradient = enabled
        ? c.gradientBrand
        : LinearGradient(
            colors: c.gradientBrand.colors
                .map((color) => color.withValues(alpha: 0.4))
                .toList(),
            begin: c.gradientBrand.begin,
            end: c.gradientBrand.end,
          );

    final button = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: ProxDurations.small,
        curve: ProxCurves.standard,
        constraints: const BoxConstraints(minHeight: ProxSpacing.minTap),
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: ProxRadii.buttonRadius,
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: c.accentBrand.withValues(
                      alpha: _hovering ? 0.35 : 0.18,
                    ),
                    blurRadius: _hovering ? 20 : 12,
                    offset: const Offset(0, 4),
                    spreadRadius: _hovering ? 0 : -2,
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: widget.buttonKey,
            onTap: widget.onPressed,
            borderRadius: ProxRadii.buttonRadius,
            splashColor: Colors.white.withValues(alpha: 0.1),
            highlightColor: Colors.white.withValues(alpha: 0.05),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: ProxSpacing.xl,
                vertical: ProxSpacing.md,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.icon != null) ...[
                    IconTheme(
                      data: const IconThemeData(
                        color: Colors.white,
                        size: ProxIconSizes.md,
                      ),
                      child: widget.icon!,
                    ),
                    const SizedBox(width: ProxSpacing.sm),
                  ],
                  DefaultTextStyle(
                    style: ProxType.label(color: Colors.white).copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                    child: widget.label,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final scaled = _PressScale(enabled: enabled, child: button);
    if (!widget.expanded) return scaled;
    return SizedBox(width: double.infinity, child: scaled);
  }
}

/// Secondary action (Cancel, Back, Save to device). Same shape/rhythm as
/// primary, ghost treatment — transparent with brand border, subtle tint
/// on hover.
class ProxSecondaryButton extends StatefulWidget {
  final Widget label;
  final VoidCallback? onPressed;
  final Widget? icon;
  final bool expanded;

  const ProxSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expanded = false,
  });

  @override
  State<ProxSecondaryButton> createState() => _ProxSecondaryButtonState();
}

class _ProxSecondaryButtonState extends State<ProxSecondaryButton> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final enabled = widget.onPressed != null;

    final button = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: ProxDurations.micro,
        curve: ProxCurves.standard,
        constraints: const BoxConstraints(minHeight: ProxSpacing.minTap),
        decoration: BoxDecoration(
          color: _hovering && enabled
              ? c.accentBrand.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: ProxRadii.buttonRadius,
          border: Border.all(
            color: enabled
                ? c.accentBrand.withValues(alpha: _hovering ? 0.6 : 0.35)
                : c.contentTertiary.withValues(alpha: 0.3),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: ProxRadii.buttonRadius,
            splashColor: c.accentBrand.withValues(alpha: 0.08),
            highlightColor: c.accentBrand.withValues(alpha: 0.04),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: ProxSpacing.xl,
                vertical: ProxSpacing.md,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.icon != null) ...[
                    IconTheme(
                      data: IconThemeData(
                        color: enabled ? c.accentBrand : c.contentTertiary,
                        size: ProxIconSizes.md,
                      ),
                      child: widget.icon!,
                    ),
                    const SizedBox(width: ProxSpacing.sm),
                  ],
                  DefaultTextStyle(
                    style: ProxType.label(
                      color: enabled ? c.accentBrand : c.contentTertiary,
                    ).copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                    child: widget.label,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final scaled = _PressScale(enabled: enabled, child: button);
    if (!widget.expanded) return scaled;
    return SizedBox(width: double.infinity, child: scaled);
  }
}
