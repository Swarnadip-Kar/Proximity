// StudentCard — the one card shape (§4.1).
//
// Fixed layout, three lines max:
// ```
// [avatar]  Name                         [status]
//           ID · Email (truncated)
//           (optional) round trail: R1 ✓ · R2 ✗ (pill chips)
// ```
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
//   on any card in that list. On desktop only, right-click (secondary tap)
//   enters selection with that row — the mouse-first entry alongside the
//   per-list Select toggle (see selection_controller.dart); touch devices
//   wire no secondary handler at all. Selection state itself lives in a
//   [SelectionController] scoped per list (see selection_controller.dart) —
//   this card is controlled (`selected` + callbacks), never global.
//
// Tradeoff note (§10 vs §4.1): long emails truncate with ellipsis but the
// full value is NOT on a long-press tooltip here — long-press is owned by
// hold-and-tap selection with no exception. Desktop hover tooltips still
// work via [Tooltip] where callers add one.
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
///
/// Task 3 (D3): the avatar fill stays `studentAvatarColor` @15% (spec hex
/// untouched); initials text on a late/review avatar uses the darkened
/// on-tint in light. Dark on-tints equal the status hexes, so dark output
/// is pixel-identical. Non-late/review avatars are unchanged.
Color studentAvatarForeground(ProximityColors c, String name) {
  final base = studentAvatarColor(c, name);
  if (base == c.statusLate) return c.onTintLate;
  if (base == c.statusReview) return c.onTintReview;
  return base;
}

/// The one card shape, used on rosters, waiting lists, inbox, manual-add
/// results, and records (reduced variant: name/email replaced by session
/// date/summary — same shell, caller-supplied strings).
class StudentCard extends StatefulWidget {
  /// Display name (line 1, truncated first under pressure).
  final String name;

  /// `ID · Email` line (line 2, truncated first). Null hides the line.
  final String? subtitle;

  /// Status slot (§4.2), right-aligned on line 1. Null hides the slot.
  final VerdictBadge? status;

  /// Round trail (line 3, pill chips). Empty hides the line.
  final List<RoundTick> roundTrail;

  /// Whether the owning list is currently in selection mode. While true,
  /// taps toggle membership instead of navigating.
  final bool selectionMode;

  /// Whether this card is currently selected (avatar ring on).
  final bool selected;

  /// Selection membership sink. Null = this card is not selectable.
  /// Long-press always calls `onSelectionChanged(true)` (enter selection);
  /// taps while [selectionMode] call `onSelectionChanged(!selected)`.
  final ValueChanged<bool>? onSelectionChanged;

  /// Single-item action (navigate/act). Ignored for taps while
  /// [selectionMode] is true and [onSelectionChanged] is set.
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
    // 12ms haptic tick: the platform selection tick (duration is fixed by
    // the OS; HapticFeedback exposes no duration parameter).
    unawaited(HapticFeedback.lightImpact());
    setState(() => _pressed = true);
    onSelection(true);
  }

  void _handleLongPressEnd(LongPressEndDetails _) {
    if (_pressed) setState(() => _pressed = false);
  }

  void _handleSecondaryTap() {
    // Desktop mouse-first entry: right-click selects this row, mirroring
    // long-press entry (always select, never toggle off — the
    // controller's select() is idempotent). No haptic/press pulse: mouse
    // users get the avatar ring on rebuild. Gated to null in build on
    widget.onSelectionChanged?.call(true);
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final avatarColor = studentAvatarColor(c, widget.name);
    final avatarFg = studentAvatarForeground(c, widget.name);
    final ringOn = widget.selected || _pressed;

    final card = Container(
      constraints: const BoxConstraints(minHeight: ProxSpacing.minTap),
      // §10 narrow breakpoint: card padding drops 16→12 below 360dp so
      // the name + status row keeps room to ellipsize instead of
      // squeezing; the round trail below wraps regardless (Wrap).
      padding: EdgeInsets.all(ProxLayout.cardPadding(context)),
      decoration: BoxDecoration(
        // Selection-mode card bg token while selected; flat raised rest.
        color: widget.selected ? c.surfaceOverlay : c.surfaceRaised,
        borderRadius: ProxRadii.cardSpecRadius,
        border: Border.all(
          color: widget.selected ? c.accentBrand : c.divider,
        ),
        boxShadow: [c.elevationRaised],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: avatarColor.withValues(alpha: 0.15),
              // Filled ring appears around the avatar on selection.
              border: Border.all(
                color: ringOn
                    ? c.accentBrand
                    : avatarColor.withValues(
                        alpha: 0.0,
                      ),
                width: ringOn ? 2.5 : 2,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              studentInitials(widget.name),
              style: ProxType.label(color: avatarFg),
              overflow: TextOverflow.clip,
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
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        onLongPressStart: _handleLongPressStart,
        onLongPressEnd: _handleLongPressEnd,
        // Mouse-first entry (desktop only): right-click enters selection
        // with this row. Null on touch devices (and on non-selectable
        // cards) — mobile gesture wiring unchanged.
        onSecondaryTap: widget.onSelectionChanged == null ||
                !isDesktopSelection
            ? null
            : _handleSecondaryTap,
        child: scaled,
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
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ProxRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        '${tick.label} ${tick.present ? '✓' : '✗'}',
        style: ProxType.caption(color: color),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
