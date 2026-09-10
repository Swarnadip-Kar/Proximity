// StudentCard — the one card shape (§4.1).
//
// Fixed layout, three lines max:
// ```
// [avatar]  Name                         [status]
//           ID · Email (truncated)
//           (optional) round trail: R1 ✓ · R2 ✗ (pill chips)
// ```
//
// UI Overhaul: avatar gets a gradient ring (rotating conic gradient in
// the avatar's color family), card gets hover lift (desktop), round trail
// chips get animated scale-in. Selection uses avatar ring + card overlay.
//
// - Avatar: initials on a deterministic color from the name hash — never
//   anything derived from `face_verification` data. There is no code path
//   in this file (or any widget built on it) that reads the face gallery
//   for display.
// - Status slot: a [VerdictBadge] (§4.2) right-aligned, vertically centered
//   on line 1.
// - Round trail renders as small pill chips, not raw text.
// - NO checkbox ever renders on this card. Selection is a full-card
//   affordance: long-press → card scales to 0.96 with a haptic tick and a
//   filled ring appears around the avatar; subsequent taps toggle the ring
//   on any card in that list.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/tokens.dart';
import 'selection_controller.dart' show isDesktopSelection;
import 'verdict_badge.dart';

/// One round tick in the round trail (e.g. R1 present, R2 absent).
@immutable
class RoundTick {
  /// Round label (`R1`, `R2`, …). Caller-owned display string.
  final String label;

  /// True = present (✓, marked tone), false = absent (✗, secondary tone).
  final bool present;

  const RoundTick(this.label, {required this.present});
}

/// Initials (max 2) from a display name. Pure for unit tests.
String studentInitials(String name) {
  final parts =
      name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    final p = parts.first;
    return (p.length >= 2 ? p.substring(0, 2) : p).toUpperCase();
  }
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

/// Deterministic palette slot from a name hash. Pure for unit tests.
int studentColorIndex(String name) {
  var h = 0;
  for (final u in name.trim().toLowerCase().codeUnits) {
    h = (h * 31 + u) & 0x7fffffff;
  }
  return h % 5;
}

/// Avatar color for a name, drawn from Foundation status/brand tokens only
/// (dark/light parity, no hardcoded colors). Never face data.
Color studentAvatarColor(ProximityColors c, String name) {
  const palette = <Color Function(ProximityColors)>[
    _brand,
    _marked,
    _late,
    _review,
    _error,
  ];
  return palette[studentColorIndex(name) % palette.length](c);
}

Color _brand(ProximityColors c) => c.accentBrand;
Color _marked(ProximityColors c) => c.statusMarked;
Color _late(ProximityColors c) => c.statusLate;
Color _review(ProximityColors c) => c.statusReview;
Color _error(ProximityColors c) => c.statusError;

/// Avatar-initials foreground for a name.
Color studentAvatarForeground(ProximityColors c, String name) {
  final base = studentAvatarColor(c, name);
  if (base == c.statusLate) return c.onTintLate;
  if (base == c.statusReview) return c.onTintReview;
  return base;
}

/// The one card shape, used on rosters, waiting lists, inbox, manual-add
/// results, and records.
class StudentCard extends StatefulWidget {
  /// Display name (line 1, truncated first under pressure).
  final String name;

  /// `ID · Email` line (line 2, truncated first). Null hides the line.
  final String? subtitle;

  /// Status slot (§4.2), right-aligned on line 1. Null hides the slot.
  final VerdictBadge? status;

  /// Round trail (line 3, pill chips). Empty hides the line.
  final List<RoundTick> roundTrail;

  /// Whether the owning list is currently in selection mode.
  final bool selectionMode;

  /// Whether this card is currently selected (avatar ring on).
  final bool selected;

  /// Selection membership sink. Null = this card is not selectable.
  final ValueChanged<bool>? onSelectionChanged;

  /// Single-item action (navigate/act).
  final VoidCallback? onTap;

  const StudentCard({
    super.key,
    required this.name,
    this.subtitle,
    this.status,
    this.roundTrail = const [],
    this.selectionMode = false,
    this.selected = false,
    this.onSelectionChanged,
    this.onTap,
  });

  @override
  State<StudentCard> createState() => _StudentCardState();
}

class _StudentCardState extends State<StudentCard> {
  var _pressed = false;
  var _hovering = false;

  void _handleTap() {
    final onSelection = widget.onSelectionChanged;
    if (widget.selectionMode && onSelection != null) {
      onSelection(!widget.selected);
      return;
    }
    widget.onTap?.call();
  }

  void _handleLongPressStart(LongPressStartDetails _) {
    final onSelection = widget.onSelectionChanged;
    if (onSelection == null) return;
    unawaited(HapticFeedback.lightImpact());
    setState(() => _pressed = true);
    onSelection(true);
  }

  void _handleLongPressEnd(LongPressEndDetails _) {
    if (_pressed) setState(() => _pressed = false);
  }

  void _handleSecondaryTap() {
    widget.onSelectionChanged?.call(true);
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final avatarColor = studentAvatarColor(c, widget.name);
    final avatarFg = studentAvatarForeground(c, widget.name);
    final ringOn = widget.selected || _pressed;

    final card = AnimatedContainer(
      duration: ProxDurations.micro,
      curve: ProxCurves.standard,
      constraints: const BoxConstraints(minHeight: ProxSpacing.minTap),
      padding: EdgeInsets.all(ProxLayout.cardPadding(context)),
      decoration: BoxDecoration(
        color: widget.selected
            ? c.surfaceOverlay
            : _hovering
                ? c.accentBrand.withValues(alpha: 0.03)
                : c.surfaceRaised,
        borderRadius: ProxRadii.cardSpecRadius,
        border: Border.all(
          color: widget.selected
              ? c.accentBrand.withValues(alpha: 0.5)
              : _hovering
                  ? c.accentBrand.withValues(alpha: 0.12)
                  : c.divider,
        ),
        boxShadow: [
          _hovering
              ? ProxShadows.hover(context)
              : ProxShadows.rest(context),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Avatar with gradient ring on selection.
          AnimatedContainer(
            duration: ProxDurations.small,
            curve: ProxCurves.spring,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: ringOn
                  ? SweepGradient(
                      colors: [
                        c.accentBrand,
                        avatarColor,
                        c.accentBrand,
                      ],
                    )
                  : null,
              color: ringOn ? null : avatarColor.withValues(alpha: 0.15),
            ),
            padding: EdgeInsets.all(ringOn ? 2.5 : 0),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ringOn
                    ? c.surfaceRaised
                    : Colors.transparent,
              ),
              padding: EdgeInsets.all(ringOn ? 1 : 0),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: avatarColor.withValues(alpha: ringOn ? 0.2 : 0.15),
                ),
                alignment: Alignment.center,
                child: Text(
                  studentInitials(widget.name),
                  style: ProxType.label(color: avatarFg),
                  overflow: TextOverflow.clip,
                ),
              ),
            ),
          ),
          const SizedBox(width: ProxSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        widget.name,
                        style: ProxType.body(color: c.contentPrimary),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    if (widget.status != null) ...[
                      const SizedBox(width: ProxSpacing.sm),
                      widget.status!,
                    ],
                  ],
                ),
                if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
                  const SizedBox(width: 0, height: 2),
                  Text(
                    widget.subtitle!,
                    style: ProxType.caption(color: c.contentSecondary),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
                if (widget.roundTrail.isNotEmpty) ...[
                  const SizedBox(height: ProxSpacing.xs),
                  Wrap(
                    spacing: ProxSpacing.sm,
                    runSpacing: ProxSpacing.xs,
                    children: [
                      for (final tick in widget.roundTrail)
                        _RoundChip(tick: tick),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    final scaled = AnimatedScale(
      scale: _pressed ? 0.96 : 1.0,
      duration: ProxMotion.effective(context, ProxDurations.micro),
      curve: ProxCurves.spring,
      child: card,
    );

    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.name,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleTap,
          onLongPressStart: _handleLongPressStart,
          onLongPressEnd: _handleLongPressEnd,
          onSecondaryTap: widget.onSelectionChanged == null ||
                  !isDesktopSelection
              ? null
              : _handleSecondaryTap,
          child: scaled,
        ),
      ),
    );
  }
}

class _RoundChip extends StatelessWidget {
  final RoundTick tick;
  const _RoundChip({required this.tick});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final color = tick.present ? c.statusMarked : c.contentSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ProxSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ProxRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            tick.present ? Icons.check : Icons.close,
            size: 10,
            color: color,
          ),
          const SizedBox(width: 3),
          Text(
            tick.label,
            style: ProxType.caption(color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
