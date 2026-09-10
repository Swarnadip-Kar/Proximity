// Shared state badges, section headers, and empty/loading/notice states.
//
// Motion intent: state changes read as continuations. [ProxStateBadge]
// animates color + label with the app-standard switcher so a student row
// flipping waiting → marked never flashes. Verdict-level hero motion lives
// on the verdict screens themselves, not in this pill.
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
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: 14, color: color),
          const SizedBox(width: ProxSpacing.xs),
          Flexible(
            child: Text(
              widget.label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: color,
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

/// Section header: "Waiting area (3)" style headings with consistent
/// typography everywhere (was 5+ ad-hoc fontSize/fontWeight copies).
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
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
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

/// Empty state: centered icon + message with breathing room. Replaces the
/// ad-hoc `Padding(vertical: 32) + Text(center)` copies.
class ProxEmptyState extends StatelessWidget {
  final String message;
  final IconData icon;

  const ProxEmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return ProxFadeSlideIn(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: ProxSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 36,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: ProxSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Quiet one-line sync/offline note (grey, centered). Replaces the
/// scattered `Text(color: Colors.grey)` copies.
class ProxSyncNote extends StatelessWidget {
  final String message;
  const ProxSyncNote(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: ProxSpacing.xs),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
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
    return ProxSwitcher(
      child: Text(
        message,
        key: ValueKey<String>(message),
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ProxSpacing.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: ProxSpacing.sm),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ProxSpacing.xs),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

/// Signed-in identity header: avatar initial + name + email + held roles.
/// Shared by the role hub and the device screen (was two identical
/// `_IdentityHeader` copies). Keeps the legacy "Signed in as …" copy the
/// flows rely on.
class ProxIdentityHeader extends StatelessWidget {
  final String displayName;
  final String email;
  final String heldLabel;
  const ProxIdentityHeader({
    super.key,
    required this.displayName,
    required this.email,
    this.heldLabel = '',
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial =
        displayName.trim().isEmpty ? '?' : displayName.trim()[0].toUpperCase();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            shape: BoxShape.circle,
            border: Border.all(color: scheme.primary.withValues(alpha: 0.3)),
          ),
          alignment: Alignment.center,
          child: Text(
            initial,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        const SizedBox(height: ProxSpacing.sm),
        Text('Signed in as $displayName',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge),
        Text(email,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                )),
        if (heldLabel.isNotEmpty) ...[
          const SizedBox(height: ProxSpacing.xs),
          Text(
            'Registered as $heldLabel.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ],
    );
  }
}
