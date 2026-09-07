// Shared buttons. One press language everywhere: user-triggered taps
// scale subtly (spring), actions fire on tap-down semantics — never gated
// behind or delayed by a decorative animation.
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

/// Primary action (Start, Join, Save, Continue). Full-width by default on
/// phone layouts — pass [expanded] false for inline use.
class ProxPrimaryButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final button = icon == null
        ? FilledButton(
            key: buttonKey,
            onPressed: onPressed,
            child: label,
          )
        : FilledButton.icon(
            key: buttonKey,
            onPressed: onPressed,
            icon: icon!,
            label: label,
          );
    final scaled =
        _PressScale(enabled: onPressed != null, child: button);
    if (!expanded) return scaled;
    return SizedBox(width: double.infinity, child: scaled);
  }
}

/// Secondary action (Cancel, Back, Save to device). Same shape/rhythm as
/// primary, outlined treatment.
class ProxSecondaryButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final button = icon == null
        ? OutlinedButton(onPressed: onPressed, child: label)
        : OutlinedButton.icon(
            onPressed: onPressed, icon: icon!, label: label);
    final scaled =
        _PressScale(enabled: onPressed != null, child: button);
    if (!expanded) return scaled;
    return SizedBox(width: double.infinity, child: scaled);
  }
}
