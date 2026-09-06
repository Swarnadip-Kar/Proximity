// Shared state badges, section headers, and empty/loading/notice states.
//
// Motion intent: state changes read as continuations. [ProxStateBadge]
// animates color + label with the app-standard switcher so a student row
// flipping waiting → marked never flashes. Verdict-level hero motion lives
// on the verdict screens themselves, not in this pill.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import 'prox_motion.dart';

/// Pill badge for one attendance state. Icon + label carry the meaning;
/// color + switch animation reinforce it (never the only signal).
class ProxStateBadge extends StatelessWidget {
  final ProxState state;
  final String label;
  final bool pulse;

  const ProxStateBadge({
    super.key,
    required this.state,
    required this.label,
    this.pulse = false,
  });

  IconData get _icon => switch (state) {
        ProxState.waiting => Icons.hourglass_top,
        ProxState.active => Icons.radio,
        ProxState.marked => Icons.check_circle,
        ProxState.late => Icons.schedule,
        ProxState.error => Icons.error_outline,
        ProxState.neutral => Icons.circle_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final color = ProxStateColors.of(context, state);
    return ProxSwitcher(
      child: Container(
        key: ValueKey<String>('$state-$label'),
        padding: const EdgeInsets.symmetric(
          horizontal: ProxSpacing.md,
          vertical: ProxSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: ProxStateColors.tint(context, state),
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
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
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
