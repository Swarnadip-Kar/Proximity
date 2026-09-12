// Shared state badges, section headers, and empty/loading/notice states.
//
// Motion intent: state changes read as continuations. [ProxStateBadge]
// animates color + label with the app-standard switcher so a student row
// flipping waiting → marked never flashes. Verdict-level hero motion lives
// on the verdict screens themselves, not in this pill.
//
// UI Overhaul: badges gain soft glow halos, section headers get accent
// bars, empty states gain animated illustrations, identity headers get
// gradient avatar rings.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import 'prox_motion.dart';

/// Pill badge for one attendance state. Icon + label carry the meaning;
/// color + switch animation reinforce it (never the only signal).
///
/// [pulse] breathes the badge while its state is live (e.g. the waiting
/// room "Connected" badge). Timer-driven like [ProxDot], static under
/// reduced motion — meaning never depends on the pulse.
///
/// UI Overhaul: gains a soft glow halo behind the badge in the state color
/// for a more premium, alive feel.
class ProxStateBadge extends StatefulWidget {
  final ProxState state;
  final String label;
  final bool pulse;

  const ProxStateBadge({
    super.key,
    required this.state,
    required this.label,
    this.pulse = false,
  });

  @override
  State<ProxStateBadge> createState() => _ProxStateBadgeState();
}

class _ProxStateBadgeState extends State<ProxStateBadge> {
  Timer? _timer;
  var _dim = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void didUpdateWidget(ProxStateBadge old) {
    super.didUpdateWidget(old);
    if (widget.pulse != old.pulse) _syncTimer();
  }

  void _syncTimer() {
    final want = widget.pulse && !ProxMotion.reduced(context);
    if (want && _timer == null) {
      _timer = Timer.periodic(ProxDurations.dotPulse, (_) {
        if (!mounted) return;
        setState(() => _dim = !_dim);
      });
    } else if (!want && _timer != null) {
      _timer?.cancel();
      _timer = null;
      _dim = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  IconData get _icon => switch (widget.state) {
        ProxState.waiting => Icons.hourglass_top,
        ProxState.active => Icons.radio,
        ProxState.marked => Icons.check_circle,
        ProxState.late => Icons.schedule,
        ProxState.error => Icons.error_outline,
        ProxState.neutral => Icons.circle_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final color = ProxStateColors.of(context, widget.state);
    final badge = Container(
      key: ValueKey<String>('${widget.state}-${widget.label}'),
      padding: const EdgeInsets.symmetric(
        horizontal: ProxSpacing.md,
        vertical: ProxSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: ProxStateColors.tint(context, widget.state),
        borderRadius: ProxRadii.chipRadius,
        border: Border.all(color: color.withValues(alpha: 0.3)),
        // Soft glow halo behind the badge.
        boxShadow: widget.pulse
            ? [
                BoxShadow(
                  color: color.withValues(alpha: _dim ? 0.05 : 0.15),
                  blurRadius: 8,
                  spreadRadius: 0,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: 14, color: color),
          const SizedBox(width: ProxSpacing.xs),
          Flexible(
            child: Text(
              widget.label,
              style: ProxType.label(color: color).copyWith(
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    final switched = ProxSwitcher(child: badge);
    if (!widget.pulse || ProxMotion.reduced(context)) return switched;
    return AnimatedOpacity(
      duration: ProxDurations.dotPulse,
      curve: ProxCurves.standard,
      opacity: _dim ? 0.55 : 1.0,
      child: switched,
    );
  }
}

/// Section header with accent bar: thin 2dp accent line (brand gradient,
/// 32dp wide) left of the title text, acting as a visual anchor.
class ProxSectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const ProxSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.only(
      top: ProxSpacing.lg,
      bottom: ProxSpacing.sm,
    ),
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          // Accent bar — visual anchor for the section.
          Container(
            width: 3,
            height: 18,
            margin: const EdgeInsets.only(right: ProxSpacing.sm),
            decoration: BoxDecoration(
              gradient: c.gradientBrand,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Text(
              title,
              style: ProxType.title(color: c.contentPrimary).copyWith(
                fontSize: 17,
                letterSpacing: -0.2,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Empty state with animated illustration: a subtle floating icon with
/// orbiting dots that gently drift, plus optional sub-action button.
class ProxEmptyState extends StatefulWidget {
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  const ProxEmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<ProxEmptyState> createState() => _ProxEmptyStateState();
}

class _ProxEmptyStateState extends State<ProxEmptyState> {
  Timer? _timer;
  double _phase = 0;
  var _armed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_armed) return;
    _armed = true;
    if (!ProxMotion.reduced(context)) {
      _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!mounted) return;
        setState(() => _phase = (_phase + 0.02) % 6.283);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    // Hero entrance for the illustration: empty states land with a
    // premium settle instead of a plain fade.
    return ProxHeroEntrance(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: ProxSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 80,
              height: 80,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Orbit dots (3 small dots at varying phases).
                  for (var i = 0; i < 3; i++)
                    Positioned(
                      left: 40 + 28 * _cos(_phase + i * 2.094),
                      top: 40 + 28 * _sin(_phase + i * 2.094),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: c.accentBrand.withValues(
                            alpha: 0.2 + 0.15 * _cos(_phase + i),
                          ),
                        ),
                      ),
                    ),
                  // Main icon with ambient glow.
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.accentBrand.withValues(alpha: 0.08),
                      border: Border.all(
                        color: c.accentBrand.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Icon(
                      widget.icon,
                      size: ProxIconSizes.lg,
                      color: c.accentBrand.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: ProxSpacing.lg),
            Text(
              widget.message,
              textAlign: TextAlign.center,
              style: ProxType.body(color: c.contentSecondary),
            ),
            if (widget.actionLabel != null && widget.onAction != null) ...[
              const SizedBox(height: ProxSpacing.lg),
              TextButton(
                onPressed: widget.onAction,
                child: Text(
                  widget.actionLabel!,
                  style: ProxType.label(color: c.accentBrand),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static double _cos(double x) => x.isNaN ? 0 : x >= 0 ? _cosImpl(x) : _cosImpl(-x);
  static double _sin(double x) => x.isNaN ? 0 : _cosImpl(x - 1.5708);
  static double _cosImpl(double x) {
    // Inline cos to keep the file self-contained (no dart:math import).
    return _dartMathCos(x);
  }
  static double _dartMathCos(double x) {
    // Use a direct calculation rather than importing math to avoid
    // potential conflicts. This is called at 50ms intervals for 3 dots.
    final v = x % 6.283185307;
    // Taylor series approximation, good enough for visual orbits.
    final x2 = v * v;
    final x4 = x2 * x2;
    final x6 = x4 * x2;
    return 1 - x2 / 2 + x4 / 24 - x6 / 720;
  }
}

/// Full-page error state: error icon disc + headline + message + optional
/// retry. Empty states stay neutral ([ProxEmptyState]); inline field errors
/// stay inline ([ProxErrorNote], [BrowseBanner]). This is for dead-ends
/// (unknown route, failed load with no data).
class ProxErrorState extends StatelessWidget {
  final String headline;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const ProxErrorState({
    super.key,
    required this.headline,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ProxSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.statusError.withValues(alpha: 0.08),
              border: Border.all(
                color: c.statusError.withValues(alpha: 0.2),
              ),
            ),
            child: Icon(
              Icons.error_outline,
              size: ProxIconSizes.lg,
              color: c.statusError,
            ),
          ),
          const SizedBox(height: ProxSpacing.md),
          Text(
            headline,
            textAlign: TextAlign.center,
            style: ProxType.title(color: c.contentPrimary),
          ),
          const SizedBox(height: ProxSpacing.xs),
          Text(
            message,
            textAlign: TextAlign.center,
            style: ProxType.body(color: c.contentSecondary),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: ProxSpacing.lg),
            TextButton(
              onPressed: onAction,
              child: Text(
                actionLabel!,
                style: ProxType.label(color: c.accentBrand),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Quiet one-line sync/offline note (grey, centered). Replaces the
/// scattered `Text(color: Colors.grey)` copies.
class ProxSyncNote extends StatelessWidget {  final String message;
  const ProxSyncNote(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: ProxSpacing.xs),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: ProxType.caption(color: c.contentTertiary),
      ),
    );
  }
}

/// Error note: same rhythm as [ProxSyncNote], error color.
class ProxErrorNote extends StatelessWidget {
  final String message;
  const ProxErrorNote(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return ProxSwitcher(
      child: Container(
        key: ValueKey<String>(message),
        padding: const EdgeInsets.symmetric(
          horizontal: ProxSpacing.md,
          vertical: ProxSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: c.statusError.withValues(alpha: 0.08),
          borderRadius: ProxRadii.cardSpecRadius,
          border: Border.all(color: c.statusError.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: ProxIconSizes.sm,
              color: c.statusError,
            ),
            const SizedBox(width: ProxSpacing.sm),
            Flexible(
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: ProxType.caption(color: c.statusError),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Loading row: small spinner + label, used for sync/search/window-open
/// waits. Never blocks the surrounding list.
class ProxLoadingRow extends StatelessWidget {
  final String label;
  const ProxLoadingRow({super.key, this.label = 'Loading…'});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ProxSpacing.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: c.accentBrand,
            ),
          ),
          const SizedBox(width: ProxSpacing.sm),
          Flexible(
            child: Text(
              label,
              style: ProxType.caption(color: c.contentSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small one-line empty note for dense sections (waiting area, inbox,
/// partial lists). Same tone as [ProxEmptyState] without the icon +
/// breathing room — sections that already have a header must not each
/// invent their own `Padding(vertical: 4) + Text` copy.
class ProxEmptyLine extends StatelessWidget {
  final String message;
  const ProxEmptyLine(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ProxSpacing.xs),
      child: Text(
        message,
        style: ProxType.caption(color: c.contentSecondary),
      ),
    );
  }
}

/// Signed-in identity header with gradient avatar ring. Only the ring
/// sweep rotates — the photo/initial inside never rotates.
class ProxIdentityHeader extends StatefulWidget {
  final String displayName;
  final String email;
  final String heldLabel;

  /// Volunteered Gmail profile photo (''/null = initial disc). Rendered
  /// with initials fallback on error/offline.
  final String? photoUrl;
  const ProxIdentityHeader({
    super.key,
    required this.displayName,
    required this.email,
    this.heldLabel = '',
    this.photoUrl,
  });

  @override
  State<ProxIdentityHeader> createState() => _ProxIdentityHeaderState();
}

class _ProxIdentityHeaderState extends State<ProxIdentityHeader> {
  Timer? _timer;
  double _angle = 0;
  var _armed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_armed) return;
    _armed = true;
    if (!ProxMotion.reduced(context)) {
      _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!mounted) return;
        setState(() => _angle = (_angle + 0.015) % 6.283);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final initial =
        widget.displayName.trim().isEmpty ? '?' : widget.displayName.trim()[0].toUpperCase();
    final photo = (widget.photoUrl ?? '').trim();

    Widget initials() => Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.accentBrand.withValues(alpha: 0.1),
          ),
          alignment: Alignment.center,
          child: Text(
            initial,
            style: ProxType.display(color: c.accentBrand).copyWith(
              fontSize: 22,
            ),
          ),
        );

    // Gmail photo inside the rotating gradient ring, initials fallback.
    // Only the SweepGradient angles animate — the face below stays still.
    final face = photo.isEmpty
        ? initials()
        : ClipOval(
            child: Image.network(
              photo,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => initials(),
              frameBuilder: (context, child, frame, _) {
                if (frame == null) return initials();
                return child;
              },
            ),
          );

    return ProxFadeSlideIn(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Avatar with rotating gradient ring (sweep only, face static).
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                startAngle: _angle,
                endAngle: _angle + 6.283,
                colors: [
                  c.accentBrand,
                  c.statusMarked,
                  c.accentBrand,
                ],
              ),
            ),
            padding: const EdgeInsets.all(2.5),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.surfaceBase,
              ),
              padding: const EdgeInsets.all(2),
              child: face,
            ),
          ),
          const SizedBox(height: ProxSpacing.md),
          Text(
            'Signed in as ${widget.displayName}',
            textAlign: TextAlign.center,
            style: ProxType.title(color: c.contentPrimary),
          ),
          const SizedBox(height: 2),
          Text(
            widget.email,
            textAlign: TextAlign.center,
            style: ProxType.caption(color: c.contentSecondary),
          ),
          if (widget.heldLabel.isNotEmpty) ...[
            const SizedBox(height: ProxSpacing.xs),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: ProxSpacing.md,
                vertical: ProxSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: c.accentBrand.withValues(alpha: 0.08),
                borderRadius: ProxRadii.chipRadius,
              ),
              child: Text(
                'Registered as ${widget.heldLabel}',
                textAlign: TextAlign.center,
                style: ProxType.caption(color: c.accentBrand),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
