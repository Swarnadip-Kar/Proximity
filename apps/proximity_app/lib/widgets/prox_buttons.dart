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
import 'prox_cards.dart' show HoverGrace;

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

  /// Compact density (token-based): keeps the 48dp tap floor but trims
  /// internal padding (xl/md → lg/sm). Opt-in per placement — default
  /// stays the roomy standard so existing screens are untouched.
  final bool compact;

  const ProxPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expanded = true,
    this.buttonKey,
    this.compact = false,
  });

  @override
  State<ProxPrimaryButton> createState() => _ProxPrimaryButtonState();
}

class _ProxPrimaryButtonState extends State<ProxPrimaryButton>
    with HoverGrace {
  var _hovering = false;

  @override
  void dispose() {
    cancelHoverGrace();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final enabled = widget.onPressed != null;
    // Disabled is flat (never a faded gradient): a washed gradient still
    // reads as actionable and fails contrast. Flat overlay + tertiary
    // foreground reads inert on both themes.
    final foreground = enabled ? Colors.white : c.contentTertiary;

    // ROOT CAUSE of the desktop flicker (hover + exit): hover changed
    // BoxShadow GEOMETRY (blur 12→20, spread −2→0) on enter AND exit.
    // Each direction re-rasterized a different blur kernel — on macOS
    // that pops both ways; animating it re-rasterized every frame.
    // FIX: hover never changes shadow geometry. Blur/spread/offset stay
    // identical; only the glow alpha (0.18→0.35) shifts in a static
    // Container (one repaint, same blur kernel, no layout/hit-test
    // change, so no enter/exit loop either).
    final button = MouseRegion(
      onEnter: (_) => hoverEnter(() => setState(() => _hovering = true)),
      onExit: (_) => hoverExit(() => setState(() => _hovering = false)),
      child: Container(
        constraints: const BoxConstraints(minHeight: ProxSpacing.minTap),
        decoration: BoxDecoration(
          color: enabled ? null : c.surfaceOverlay,
          gradient: enabled ? c.gradientBrand : null,
          borderRadius: ProxRadii.buttonRadius,
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: c.accentBrand.withValues(
                      alpha: _hovering ? 0.35 : 0.18,
                    ),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                    spreadRadius: -2,
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
              padding: EdgeInsets.symmetric(
                horizontal:
                    widget.compact ? ProxSpacing.lg : ProxSpacing.xl,
                vertical: widget.compact ? ProxSpacing.sm : ProxSpacing.md,
              ),
              // FittedBox scales down only when the label+icon exceed the
              // available width (e.g. long "Continue as Professor offline"
              // at large text scale) — short labels measure identically
              // to a plain Row, so existing layouts/hit-tests are untouched.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.icon != null) ...[
                      IconTheme(
                        data: IconThemeData(
                          color: foreground,
                          size: ProxIconSizes.md,
                        ),
                        child: widget.icon!,
                      ),
                      const SizedBox(width: ProxSpacing.sm),
                    ],
                    DefaultTextStyle(
                      style: ProxType.label(color: foreground).copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                      softWrap: false,
                      child: widget.label,
                    ),
                  ],
                ),
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
///
/// [tone] re-tints the ghost in a sanctioned status color (same shape,
/// same rhythm — only the hue changes). `ProxStatus.marked` green marks
/// confirm-into-roster actions like "Add & mark present"; null keeps the
/// default brand. Never a raw color — always a design-system token.
class ProxSecondaryButton extends StatefulWidget {
  final Widget label;
  final VoidCallback? onPressed;
  final Widget? icon;
  final bool expanded;

  /// Compact density (token-based, same contract as primary).
  final bool compact;

  /// Optional status-color tone for the ghost treatment.
  final ProxStatus? tone;

  const ProxSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expanded = false,
    this.compact = false,
    this.tone,
  });

  @override
  State<ProxSecondaryButton> createState() => _ProxSecondaryButtonState();
}

class _ProxSecondaryButtonState extends State<ProxSecondaryButton>
    with HoverGrace {
  var _hovering = false;

  @override
  void dispose() {
    cancelHoverGrace();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final enabled = widget.onPressed != null;
    // Status tone (null = brand default). Same ghost, sanctioned hue.
    final tone = widget.tone == null
        ? c.accentBrand
        : ProxIcons.statusColor(context, widget.tone!);

    // Ghost hover animates solid tint/border fills only (no blur), so it
    // is flicker-free by construction; grace exit matches the cards.
    final button = MouseRegion(
      onEnter: (_) => hoverEnter(() => setState(() => _hovering = true)),
      onExit: (_) => hoverExit(() => setState(() => _hovering = false)),
      child: AnimatedContainer(
        duration: ProxDurations.micro,
        curve: ProxCurves.standard,
        constraints: const BoxConstraints(minHeight: ProxSpacing.minTap),
        decoration: BoxDecoration(
          color: _hovering && enabled
              ? tone.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: ProxRadii.buttonRadius,
          border: Border.all(
            color: enabled
                ? tone.withValues(alpha: _hovering ? 0.6 : 0.35)
                : c.contentTertiary.withValues(alpha: 0.3),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: ProxRadii.buttonRadius,
            splashColor: tone.withValues(alpha: 0.08),
            highlightColor: tone.withValues(alpha: 0.04),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal:
                    widget.compact ? ProxSpacing.lg : ProxSpacing.xl,
                vertical:
                    widget.compact ? ProxSpacing.sm : ProxSpacing.md,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.icon != null) ...[
                      IconTheme(
                        data: IconThemeData(
                          color: enabled ? tone : c.contentTertiary,
                          size: ProxIconSizes.md,
                        ),
                        child: widget.icon!,
                      ),
                      const SizedBox(width: ProxSpacing.sm),
                    ],
                    DefaultTextStyle(
                      style: ProxType.label(
                        color: enabled ? tone : c.contentTertiary,
                      ).copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                      softWrap: false,
                      child: widget.label,
                    ),
                  ],
                ),
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

/// Quiet destructive action (End attendance, Discard draft, Remove).
/// Text-only in statusError — terminal actions never compete as gradient
/// primary or brand secondary. Same 48dp floor; disabled reads tertiary.
class ProxDangerButton extends StatelessWidget {
  final Widget label;
  final VoidCallback? onPressed;

  const ProxDangerButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final enabled = onPressed != null;
    return TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(64, ProxSpacing.minTap),
        foregroundColor: enabled ? c.statusError : c.contentTertiary,
      ),
      onPressed: onPressed,
      child: DefaultTextStyle(
        style: ProxType.label(
          color: enabled ? c.statusError : c.contentTertiary,
        ).copyWith(fontWeight: FontWeight.w600),
        softWrap: false,
        child: label,
      ),
    );
  }
}
