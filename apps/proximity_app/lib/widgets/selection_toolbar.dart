// SelectionToolbar — the bulk-action bar for hold-and-tap lists (§4.1).
//
// Slides up from the bottom ("Approve N · Reject N · Select all · Cancel"),
// replacing the bottom bar temporarily on screens that have one (inbox,
// sessions list for multi-delete). Flat surface, hairline top divider —
// this is working chrome, not a gradient/glow moment (§2.5).
//
// Generic by design: the caller supplies [actions] (e.g. Approve/Reject
// built by the manual-attendance module, Delete built by the sessions
// list). No checkbox appears here or anywhere in selection UI — selection
// is hold-and-tap only.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// One bulk action on the toolbar (e.g. `Approve 3`, `Reject 3`).
@immutable
class SelectionToolbarAction {
  final String label;
  final VoidCallback? onPressed;

  const SelectionToolbarAction({required this.label, this.onPressed});
}

/// Bottom bulk-action bar. Renders nothing when [visible] is false.
class SelectionToolbar extends StatelessWidget {
  /// Whether the bar is shown (bind to `controller.selecting`).
  final bool visible;

  /// Number of selected rows (`N selected`).
  final int selectedCount;

  /// Total rows in the list (for the `Select all` affordance). Null hides
  /// the total; [onSelectAll] still selects whatever the caller passes.
  final int? totalCount;

  /// Bulk actions (Approve/Reject, Delete, …). Rendered low-emphasis so
  /// the count stays the primary read.
  final List<SelectionToolbarAction> actions;

  /// `Select all` tap. Null hides the affordance.
  final VoidCallback? onSelectAll;

  /// `Cancel` tap (exits selection mode). Null hides the affordance.
  final VoidCallback? onCancel;

  const SelectionToolbar({
    super.key,
    required this.visible,
    required this.selectedCount,
    this.totalCount,
    this.actions = const [],
    this.onSelectAll,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final bar = _bar(context);
    if (ProxMotion.reduced(context)) return bar;
    // Slide-up entrance (sheet cadence); reduce-motion renders statically.
    return AnimatedSlide(
      duration: ProxDurations.sheet,
      curve: ProxCurves.emphasized,
      offset: Offset.zero,
      child: AnimatedOpacity(
        duration: ProxDurations.sheet,
        opacity: 1.0,
        child: bar,
      ),
    );
  }

  Widget _bar(BuildContext context) {
    final c = ProximityColors.of(context);
    final total = totalCount;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: c.surfaceRaised,
          border: Border(top: BorderSide(color: c.divider)),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: ProxSpacing.screenMargin,
          vertical: ProxSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                total == null
                    ? '$selectedCount selected'
                    : '$selectedCount of $total selected',
                style: ProxType.label(color: c.contentPrimary),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            Flexible(
              flex: 2,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final action in actions)
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize:
                              const Size(64, ProxSpacing.minTap),
                        ),
                        onPressed: action.onPressed,
                        child: Text(
                          action.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (onSelectAll != null)
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize:
                              const Size(64, ProxSpacing.minTap),
                        ),
                        onPressed: onSelectAll,
                        child: const Text('Select all'),
                      ),
                    if (onCancel != null)
                      IconButton(
                        tooltip: 'Cancel',
                        iconSize: 20,
                        constraints: const BoxConstraints(
                          minWidth: ProxSpacing.minTap,
                          minHeight: ProxSpacing.minTap,
                        ),
                        onPressed: onCancel,
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
