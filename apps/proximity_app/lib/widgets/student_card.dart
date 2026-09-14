// StudentCard — the one card shape (§4.1).
//
// Fixed layout, three lines max:
// ```
// [avatar]  Name                         [status]
//           ID · Email (truncated)
//           (optional) round trail: R1 ✓ · R2 ✗ (pill chips)
// ```
//
// UI Overhaul: avatar gets a gradient ring (ring sweep rotates, logo/
// photo inside never rotates), card gets hover lift (desktop), round
// trail chips get animated scale-in. Selection uses avatar ring + card
// overlay.
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
import 'prox_cards.dart' show HoverGrace;
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
/// Parts without a single alphanumeric (a bare `-` separator in
/// `DSL506 - Intro…`) are SKIPPED, never initialled — separators are not
/// names. Single-part names read the first 2 chars (`plato` → `PL`).
String studentInitials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty && RegExp(r'[A-Za-z0-9]').hasMatch(p))
      .toList();
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

/// Avatar color for a name — identity-only hues, never verdict colors.
///
/// Slots stay stable (`studentColorIndex` unchanged) so existing rows keep
/// their slot; only the hues change. Deliberately avoids green/yellow/red/
/// orange (Marked/Late/Error/Review) so an avatar never reads as a verdict
/// next to the card's real VerdictBadge. Brightness inferred from the
/// resolved `ProximityColors` surface (dark surface = dark palette).
/// Never face data.
Color studentAvatarColor(ProximityColors c, String name) {
  final dark =
      ThemeData.estimateBrightnessForColor(c.surfaceBase) == Brightness.dark;
  return _identityFor(name, dark);
}

Color _identityFor(String name, bool dark) {
  final palette = dark ? ProxIdentity.dark : ProxIdentity.light;
  return palette[studentColorIndex(name) % palette.length];
}

/// Avatar-initials foreground for a name: identity hues are drawn dark
/// enough for both themes, so foreground equals the base (no on-tint
/// remap needed — that path existed only for verdict-yellow/orange).
Color studentAvatarForeground(ProximityColors c, String name) =>
    studentAvatarColor(c, name);

/// Course logo initials (first 2 alphanumerics, upper): `CS201` → `CS`,
/// `Maths` → `MA`. Pure for unit tests.
String courseInitials(String course) {
  final alnum =
      course.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (alnum.isEmpty) return '?';
  return alnum.length >= 2 ? alnum.substring(0, 2) : alnum;
}

/// Course logo color: same deterministic palette + token discipline as
/// student avatars, so course discs read as family. Never face data.
Color courseAvatarColor(ProximityColors c, String course) =>
    studentAvatarColor(c, 'course:$course');

/// Course logo disc: same disc language as student avatars (tinted disc +
/// initials), used everywhere a course needs a mark — pickers, headers,
/// previews. Replaces one-off folder/book icons.
class CourseLogo extends StatelessWidget {
  final String course;
  final double size;

  const CourseLogo({super.key, required this.course, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final base = courseAvatarColor(c, course);
    final fg = base;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: base.withValues(alpha: 0.15),
      ),
      alignment: Alignment.center,
      child: Text(
        courseInitials(course),
        style: ProxType.label(color: fg).copyWith(
          fontWeight: FontWeight.w700,
          fontSize: size * 0.34,
        ),
        overflow: TextOverflow.clip,
        maxLines: 1,
      ),
    );
  }
}

/// Shared identity avatar: photo first (account metadata, never face
/// data), initials disc fallback on ProxIdentity hues. Optional gradient
/// ring (identity accent, never glow — glow is reserved for live
/// scanning). Replaces browse/header one-off avatar assemblies.
///
/// Course discs ([ProxAvatar.course]) use [courseInitials] (CS201 → CS),
/// the same helper as [CourseLogo] — one course-disc language everywhere.
class ProxAvatar extends StatelessWidget {
  final String name;
  final String photoUrl;
  final double size;
  final bool withRing;
  final bool isCourse;

  const ProxAvatar({
    super.key,
    required this.name,
    this.photoUrl = '',
    this.size = 56,
    this.withRing = true,
    this.isCourse = false,
  });

  /// Course disc: photo (gated Gmail opt-in) or [courseInitials] fallback,
  /// no ring (matches [CourseLogo]).
  const ProxAvatar.course({
    super.key,
    required String course,
    this.photoUrl = '',
    this.size = 40,
  })  : name = course,
        withRing = false,
        isCourse = true;

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final url = photoUrl.trim();
    final label = isCourse ? courseInitials(name) : studentInitials(name);
    final discTextStyle = isCourse
        ? ProxType.label(color: courseAvatarColor(c, name)).copyWith(
            fontWeight: FontWeight.w700,
            fontSize: size * 0.34,
          )
        : ProxType.title(color: studentAvatarColor(c, name));
    Widget initials() {
      final base =
          isCourse ? courseAvatarColor(c, name) : studentAvatarColor(c, name);
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: base.withValues(alpha: 0.12),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: discTextStyle,
          overflow: TextOverflow.clip,
          maxLines: 1,
        ),
      );
    }

    final face = url.isEmpty
        ? initials()
        : ClipOval(
            child: Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => initials(),
              frameBuilder: (context, child, frame, _) {
                if (frame == null) return initials();
                return child;
              },
            ),
          );
    if (name.trim().isEmpty && url.isEmpty) {
      return const SizedBox.shrink();
    }
    if (!withRing) return face;
    return Container(
      width: size + 8,
      height: size + 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: c.gradientBrand,
      ),
      padding: const EdgeInsets.all(3),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.surfaceBase,
        ),
        padding: const EdgeInsets.all(2),
        child: face,
      ),
    );
  }
}

/// Attendance ring avatar: the ONE ring + face assembly shared by the
/// course list cards and the course detail header (same box, same avatar,
/// same ring ratio — never drift apart again).
///
/// Prof photo first ([photoUrl], ordinary account metadata, never face
/// data), course-letter disc fallback (letters beneath while
/// loading/offline/error — never blank). A solid [surfaceBase] separator
/// hugs the face so the translucent initials disc and the hard-edged
/// photo share one boundary before the ring. The attendance [value]
/// (0..1) rides the accentBrand arc over the divider track.
class AttendanceRingAvatar extends StatelessWidget {
  final String photoUrl;
  final String course;
  final double value;

  /// Ring-box edge. Defaults to [ProxSpacing.minTap] (the list size).
  final double boxSize;

  /// Face diameter inside the separator.
  final double avatarSize;

  /// Ring stroke as a fraction of [avatarSize] (one ratio everywhere).
  final double ringRatio;

  const AttendanceRingAvatar({
    super.key,
    required this.photoUrl,
    required this.course,
    required this.value,
    this.boxSize = ProxSpacing.minTap,
    this.avatarSize = 36,
    this.ringRatio = 3 / 36,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final url = photoUrl.trim();
    final face = url.isEmpty
        ? CourseLogo(course: course, size: avatarSize)
        : ClipOval(
            child: Image.network(
              url,
              width: avatarSize,
              height: avatarSize,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  CourseLogo(course: course, size: avatarSize),
              frameBuilder: (context, child, frame, _) {
                if (frame == null) {
                  return CourseLogo(course: course, size: avatarSize);
                }
                return child;
              },
            ),
          );
    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CircularProgressIndicator(
              value: value.clamp(0.0, 1.0),
              strokeWidth: avatarSize * ringRatio,
              strokeCap: StrokeCap.round,
              backgroundColor: c.divider,
              valueColor: AlwaysStoppedAnimation<Color>(c.accentBrand),
            ),
          ),
          Center(
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.surfaceBase,
              ),
              padding: const EdgeInsets.all(2),
              child: face,
            ),
          ),
        ],
      ),
    );
  }
}

/// The one card shape, used on rosters, waiting lists, inbox, manual-add
/// results, and records.
class StudentCard extends StatefulWidget {
  /// Display name (line 1, truncated first under pressure).
  final String name;

  /// `ID · Email` line (line 2, truncated first). Null hides the line.
  final String? subtitle;

  /// Optional second detail line (line 3, same caption style, truncated).
  /// Mark class tiles put the email here so it sits below the rest.
  /// Null hides the line — every other card is unchanged.
  final String? subtitle2;

  /// Status slot (§4.2), right-aligned on line 1. Usually one
  /// [VerdictBadge]; the course-overview session rows pass a stacked
  /// present/absent badge column instead. Null hides the slot.
  final Widget? status;

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

  /// Volunteered Gmail profile photo URL (ordinary account metadata, NOT
  /// face-verification output). ''/null = deterministic initials avatar.
  /// Rendered via [Image.network] with initials fallback on error/offline.
  final String? photoUrl;

  /// Avatar identity override: avatar color + initials derive from this
  /// instead of [name]. The course-overview session rows show the session
  /// date as [name] but keep the course disc (CS, not date initials).
  /// Null (every other caller) keeps the legacy name-derived avatar.
  final String? avatarName;

  /// Full-width subtitle-line replacement. The course-overview session
  /// rows slot their evenly-spaced rounds/present/partial/absent row
  /// here (rounds included — `subtitle` stays null). Null (every other
  /// caller) renders the classic single subtitle text.
  final Widget? subtitleTrailing;

  /// Full-width footer below the main row (inside card padding). The
  /// course-overview session rows slot their attendance share bar here.
  /// Null (every other caller) renders the classic row only.
  final Widget? footer;

  /// Card internal padding override. Null (every other caller) keeps the
  /// spec padding ([ProxLayout.cardPadding] all round). The overview
  /// session rows slim the top only.
  final EdgeInsetsGeometry? padding;

  /// Avatar disc diameter (default 40 — rosters, waiting lists, records).
  /// Mark browse class tiles pass 56.
  final double avatarSize;

  /// Tiny caption tucked directly beneath the avatar disc, inside the
  /// avatar column only (never overlapping the title/content section).
  /// Mark browse tiles show the live round ordinal here ("1st Class").
  /// Null/empty renders exactly as before (bare disc, same metrics).
  final String? avatarCaption;

  /// False hides the avatar disc (the export page shows date-only rows).
  /// True (every other caller) keeps the classic avatar.
  final bool showAvatar;

  /// True when [name] is a COURSE title (`DSL506 - Intro…`), not a person:
  /// the avatar disc uses [courseInitials] (`DS`) + course hues instead of
  /// person initials. Mark browse class tiles pass true; every person row
  /// keeps false (default — pixel-identical).
  final bool isCourse;

  const StudentCard({
    super.key,
    required this.name,
    this.subtitle,
    this.subtitle2,
    this.status,
    this.roundTrail = const [],
    this.selectionMode = false,
    this.selected = false,
    this.onSelectionChanged,
    this.onTap,
    this.photoUrl,
    this.avatarName,
    this.subtitleTrailing,
    this.footer,
    this.padding,
    this.avatarSize = 40,
    this.showAvatar = true,
    this.isCourse = false,
    this.avatarCaption,
  });

  @override
  State<StudentCard> createState() => _StudentCardState();
}

class _StudentCardState extends State<StudentCard> with HoverGrace {
  var _pressed = false;
  var _hovering = false;

  /// Ring-sweep driver: timer-stepped gradient angle (timers never block
  /// pumpAndSettle), armed only while the ring is on and motion is
  /// allowed. Only the SweepGradient angles animate — the logo/photo
  /// child is never wrapped in Transform.rotate, so it stays still.
  Timer? _ringTimer;
  var _ringAngle = 0.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRing();
  }

  @override
  void didUpdateWidget(StudentCard old) {
    super.didUpdateWidget(old);
    _syncRing();
  }

  void _syncRing() {
    final want = (widget.selected || widget.selectionMode) &&
        !ProxMotion.reduced(context);
    if (want && _ringTimer == null) {
      _ringTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
        if (!mounted) return;
        setState(() => _ringAngle += 0.25);
      });
    } else if (!want && _ringTimer != null) {
      _ringTimer?.cancel();
      _ringTimer = null;
    }
  }

  @override
  void dispose() {
    cancelHoverGrace();
    _ringTimer?.cancel();
    super.dispose();
  }

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
    final avatarLabel = widget.avatarName ?? widget.name;
    final avatarColor = widget.isCourse
        ? courseAvatarColor(c, avatarLabel)
        : studentAvatarColor(c, avatarLabel);
    // Course discs draw the initial IN the base hue (same as CourseLogo /
    // ProxAvatar.course); person discs keep the identity foreground.
    final avatarFg =
        widget.isCourse ? avatarColor : studentAvatarForeground(c, avatarLabel);
    final ringOn = widget.selected || _pressed;

    // No-shadow-geometry hover rule (see ProxCard): hover never touches
    // the shadow (stays at `rest` always) — only the tint/border color
    // animates. Swapping blur/offset on enter AND exit re-rasterizes a
    // different blur kernel each way, which pops on macOS both directions.
    final card = Container(
      decoration: BoxDecoration(
        borderRadius: ProxRadii.cardSpecRadius,
        boxShadow: [ProxShadows.rest(context)],
      ),
      child: AnimatedContainer(
        duration: ProxDurations.micro,
        curve: ProxCurves.standard,
        constraints: const BoxConstraints(minHeight: ProxSpacing.minTap),
        padding:
            widget.padding ?? EdgeInsets.all(ProxLayout.cardPadding(context)),
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
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Avatar with gradient ring on selection. Only the ring sweep
            // rotates (SweepGradient angles in the plain inner Container);
            // the logo/photo child is never Transform.rotated, so it stays
            // still. The angles MUST NOT live in AnimatedContainer's
            // decoration: every 120ms tick would restart its implicit
            // BoxDecoration animation and pumpAndSettle would never settle.
            // NOTE: padding animates 0 ↔ 2.5, so the curve must NOT overshoot
            // (easeOutBack dips below 0 → AnimatedContainer asserts
            // padding.isNonNegative). Keep the spring for scale only.
            if (widget.showAvatar)
              SizedBox(
                // Caption column: fixed width so the ordinal ("12th
                // Class") fits beside the disc without touching the
                // title section; the disc stays centered over it. Bare
                // discs keep the exact legacy width (no content shift).
                width: (widget.avatarCaption?.trim().isNotEmpty ?? false)
                    ? widget.avatarSize + 8
                    : widget.avatarSize,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: ProxDurations.small,
                      curve: ProxCurves.standard,
                      width: widget.avatarSize,
                      height: widget.avatarSize,
                      padding: EdgeInsets.all(ringOn ? 2.5 : 0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: ringOn
                      ? Colors.transparent
                      : avatarColor.withValues(alpha: 0.15),
                ),
                child: ringOn
                    ? Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: SweepGradient(
                            startAngle: _ringAngle,
                            endAngle: _ringAngle + 6.283,
                            colors: [
                              c.accentBrand,
                              avatarColor,
                              c.accentBrand,
                            ],
                          ),
                        ),
                        padding: const EdgeInsets.all(1),
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: c.surfaceRaised,
                          ),
                          child: _CardAvatar(
                            name: avatarLabel,
                            photoUrl: widget.photoUrl,
                            ringOn: ringOn,
                            avatarColor: avatarColor,
                            avatarFg: avatarFg,
                            c: c,
                            size: widget.avatarSize,
                            isCourse: widget.isCourse,
                          ),
                        ),
                      )
                    : _CardAvatar(
                        name: avatarLabel,
                        photoUrl: widget.photoUrl,
                        ringOn: ringOn,
                        avatarColor: avatarColor,
                        avatarFg: avatarFg,
                        c: c,
                        size: widget.avatarSize,
                        isCourse: widget.isCourse,
                      ),
                    ),
                    // Round ordinal under the disc (avatar column only).
                    if (widget.avatarCaption?.trim().isNotEmpty ?? false) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.avatarCaption!.trim(),
                        style: ProxType.caption(color: c.contentSecondary),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ],
                  ],
                ),
              ),
            if (widget.showAvatar) const SizedBox(width: ProxSpacing.md),
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
                  if ((widget.subtitle != null &&
                          widget.subtitle!.isNotEmpty) ||
                      widget.subtitleTrailing != null) ...[
                    const SizedBox(width: 0, height: 2),
                    widget.subtitleTrailing ??
                        Text(
                          widget.subtitle!,
                          style: ProxType.caption(color: c.contentSecondary),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                  ],
                  if (widget.subtitle2 != null &&
                      widget.subtitle2!.isNotEmpty) ...[
                    const SizedBox(width: 0, height: 2),
                    Text(
                      widget.subtitle2!,
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
                  // Footer (attendance share bar on session rows): full
                  // content-column width, below trail/text.
                  if (widget.footer != null) ...[
                    const SizedBox(height: ProxSpacing.sm),
                    widget.footer!,
                  ],
                ],
              ),
            ),
          ],
        ),
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
        onEnter: (_) => hoverEnter(() => setState(() => _hovering = true)),
        onExit: (_) => hoverExit(() => setState(() => _hovering = false)),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleTap,
          onLongPressStart: _handleLongPressStart,
          onLongPressEnd: _handleLongPressEnd,
          onSecondaryTap:
              widget.onSelectionChanged == null || !isDesktopSelection
                  ? null
                  : _handleSecondaryTap,
          child: scaled,
        ),
      ),
    );
  }
}

/// Avatar face: volunteered Gmail photo when present (network image with
/// initials fallback on error/offline/empty), else the deterministic
/// initials disc. Photo is ordinary account metadata, never face data.
class _CardAvatar extends StatelessWidget {
  final String name;
  final String? photoUrl;
  final bool ringOn;
  final Color avatarColor;
  final Color avatarFg;
  final ProximityColors c;
  final double size;

  /// True when [name] is a course title: the disc shows [courseInitials]
  /// (`DS`), not person initials.
  final bool isCourse;

  const _CardAvatar({
    required this.name,
    required this.photoUrl,
    required this.ringOn,
    required this.avatarColor,
    required this.avatarFg,
    required this.c,
    this.size = 40,
    this.isCourse = false,
  });

  @override
  Widget build(BuildContext context) {
    final url = photoUrl?.trim() ?? '';
    Widget initials() => Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: avatarColor.withValues(alpha: ringOn ? 0.2 : 0.15),
          ),
          alignment: Alignment.center,
          child: Text(
            isCourse ? courseInitials(name) : studentInitials(name),
            // Same disc-initials proportion as CourseLogo (size * 0.34).
            style:
                ProxType.label(color: avatarFg).copyWith(fontSize: size * 0.34),
            overflow: TextOverflow.clip,
          ),
        );
    if (url.isEmpty) return initials();
    return ClipOval(
      child: Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => initials(),
        // While loading (or offline-starved), show initials beneath:
        // the frameBuilder fades the photo in over them.
        frameBuilder: (context, child, frame, _) {
          if (frame == null) return initials();
          return child;
        },
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
    // One-shot scale-in when the chip first appears (completes, so
    // pumpAndSettle-safe; skipped under reduce-motion).
    if (ProxMotion.reduced(context)) return _chip(c, color);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.6, end: 1.0),
      duration: ProxDurations.verdictPop,
      curve: ProxCurves.verdictSpring,
      builder: (_, v, child) => Transform.scale(scale: v, child: child),
      child: _chip(c, color),
    );
  }

  Widget _chip(ProximityColors c, Color color) {
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
