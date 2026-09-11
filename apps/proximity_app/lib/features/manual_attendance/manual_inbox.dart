// Manual inbox UI (new, §4.8).
//
// The professor-side approve/reject list, owned by the
// `features/manual_attendance/` module and composed by `live/<course>/inbox`
// (focused section) and the take-attendance host screen — never bespoke
// approve/reject UI inline in either. Routes unchanged; module boundary
// only.
//
// Selection is tap-to-select (§4.1, no checkboxes anywhere): plain taps
// toggle for this list (rows have no navigation target, so no hold is
// needed — same contract as the review/export picker), right-click
// selects on desktop, and the [SelectionToolbar] offers
// `Approve N · Reject N · Select all · Cancel` (same controller, same
// toolbar — see `widgets/selection_controller.dart`). Selection state
// lives in this list's OWN [SelectionScope] instance (per-list rule —
// never shared with the roster or any other list).
//
// Decision paths are the host's (driver `decideManual` + draft + snapshot,
// wired by the callers) and are preserved exactly:
//  - exactly one selected + Approve/Reject → [onApproveOne]/[onRejectOne]
//    (the single-item path, incl. its log line + per-row clear);
//  - several selected → [onDecide] (the bulk path, incl. its bulk log).
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/host_driver.dart' show ManualRow;
import '../../design/tokens.dart';
import '../../widgets/partial_list.dart' show rosterSubtitle;
import '../../widgets/prox_states.dart';
import '../../widgets/selection_controller.dart';
import '../../widgets/selection_toolbar.dart';
import '../../widgets/student_card.dart';
import '../../widgets/verdict_badge.dart';

/// Swipe-to-decide row: mirrors [RemovableRosterRow] (live_roster.dart)
/// exactly — same [Dismissible] defaults (threshold/motion), same wash
/// language (12% status tint + [ProxRadii.cardSpecRadius] + edge padding
/// + status-color icon), same async confirmDismiss-returns-bool contract
/// (success dismisses, failure snaps back, never throws).
/// Direction only differs by intent: swipe RIGHT (startToEnd) approves
/// through the single-item approve path; swipe LEFT (endToStart) rejects
/// through the single-item reject path. Both act immediately (same
/// immediacy as the toolbar single-item Approve/Reject — no confirm
/// dialog); decided rows leave via the existing decide + prune paths.
/// Tap-to-select coexists: the [child] keeps its own tap handling;
/// only the swiped row's selection is cleared, others are preserved.
class _InboxSwipeRow extends StatelessWidget {
  final String email;
  final Future<void> Function(String email) onApprove;
  final Future<void> Function(String email) onReject;
  final Widget child;

  const _InboxSwipeRow({
    required this.email,
    required this.onApprove,
    required this.onReject,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Dismissible(
      key: ValueKey<String>('inbox-swipe-$email'),
      direction: DismissDirection.horizontal,
      confirmDismiss: (direction) async {
        try {
          if (direction == DismissDirection.startToEnd) {
            await onApprove(email);
            return true;
          } else if (direction == DismissDirection.endToStart) {
            await onReject(email);
            return true;
          }
          return false;
        } catch (_) {
          return false;
        }
      },
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: ProxSpacing.lg),
        decoration: BoxDecoration(
          color: c.statusMarked.withValues(alpha: 0.12),
          borderRadius: ProxRadii.cardSpecRadius,
        ),
        child: Icon(Icons.check, color: c.statusMarked),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: ProxSpacing.lg),
        decoration: BoxDecoration(
          color: c.statusError.withValues(alpha: 0.12),
          borderRadius: ProxRadii.cardSpecRadius,
        ),
        child: Icon(Icons.delete_outline, color: c.statusError),
      ),
      child: child,
    );
  }
}

/// Approve/reject list for pending manual-attendance requests. Owns a
/// fresh [SelectionScope] for exactly this list.
class ManualInboxView extends StatefulWidget {
  final List<ManualRow> pending;
  final Future<void> Function(String email) onApproveOne;
  final Future<void> Function(String email) onRejectOne;
  final Future<void> Function(List<String> emails, bool approve) onDecide;

  const ManualInboxView({
    super.key,
    required this.pending,
    required this.onApproveOne,
    required this.onRejectOne,
    required this.onDecide,
  });

  @override
  State<ManualInboxView> createState() => _ManualInboxViewState();
}

class _ManualInboxViewState extends State<ManualInboxView> {
  @override
  Widget build(BuildContext context) {
    // Own scope instance: sibling lists (roster, sessions) never share
    // selection state with this inbox.
    return SelectionScope(
      child: _ManualInboxBody(
        pending: widget.pending,
        onApproveOne: widget.onApproveOne,
        onRejectOne: widget.onRejectOne,
        onDecide: widget.onDecide,
      ),
    );
  }
}

/// Tap-to-select inbox rows (same contract as the review/export picker:
/// plain taps toggle on native, no hold, no mode toggle — rows have no
/// navigation target to conflict with; web renders without multi-select).
class _ManualInboxBody extends ConsumerStatefulWidget {
  final List<ManualRow> pending;
  final Future<void> Function(String email) onApproveOne;
  final Future<void> Function(String email) onRejectOne;
  final Future<void> Function(List<String> emails, bool approve) onDecide;

  const _ManualInboxBody({
    required this.pending,
    required this.onApproveOne,
    required this.onRejectOne,
    required this.onDecide,
  });

  @override
  ConsumerState<_ManualInboxBody> createState() => _ManualInboxBodyState();
}

class _ManualInboxBodyState extends ConsumerState<_ManualInboxBody> {
  static String _id(String email) => email.toLowerCase();

  /// Drops selection for rows that left the pending list (approved /
  /// rejected elsewhere) without touching live membership mid-build.
  void _pruneStale(SelectionController ctl) {
    final live = {for (final m in _forPending()) _id(m.email)};
    final stale = ctl.selectedIds.where((id) => !live.contains(id)).toList();
    if (stale.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final id in stale) {
        ctl.deselect(id);
      }
    });
  }

  List<ManualRow> _forPending() => widget.pending;

  Future<void> _approveOne(String email) async {
    await widget.onApproveOne(email);
    if (mounted) ref.read(selectionControllerProvider).deselect(_id(email));
  }

  Future<void> _rejectOne(String email) async {
    await widget.onRejectOne(email);
    if (mounted) ref.read(selectionControllerProvider).deselect(_id(email));
  }

  Future<void> _decideSelected(bool approve) async {
    final ctl = ref.read(selectionControllerProvider);
    final emails = ctl.selectedIds.toList();
    if (emails.isEmpty) return;
    if (emails.length == 1) {
      // Single-item path (same host sequence as the old per-row buttons).
      if (approve) {
        await _approveOne(emails.first);
      } else {
        await _rejectOne(emails.first);
      }
    } else {
      await widget.onDecide(emails, approve);
      if (mounted) ctl.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _forPending();
    final ctl = ref.watch(selectionControllerProvider);
    _pruneStale(ctl);
    // Tap-to-select is native-only; web renders the same rows without
    // multi-select (same contract as the review/export picker).
    final tapSelect = !kIsWeb;
    final selecting = ctl.selecting && !kIsWeb;
    final n = ctl.count;
    final c = ProximityColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Manual requests (${pending.length})',
          style: ProxType.title(color: c.contentPrimary),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        const SizedBox(height: ProxSpacing.sm),
        if (pending.isEmpty)
          const ProxEmptyLine('No manual requests.')
        else ...[
          // Tap-to-select hint (same caption as the review/export
          // picker — no per-page copy).
          if (tapSelect) ...[
            Text(
              'Tap to select',
              style: ProxType.caption(color: c.contentTertiary),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
            const SizedBox(height: ProxSpacing.xs),
          ],
          for (final m in pending)
            Padding(
              padding: const EdgeInsets.only(bottom: ProxSpacing.sm),
              child: _InboxSwipeRow(
                email: m.email,
                onApprove: _approveOne,
                onReject: _rejectOne,
                child: StudentCard(
                  key: ValueKey<String>('manual-${m.email}'),
                  name: m.name.isNotEmpty ? m.name : m.email,
                  subtitle: rosterSubtitle(m.roll, m.email),
                  photoUrl: m.photoUrl,
                  // Static (never pulsing) badge: a periodic pulse would
                  // keep widget tests from settling; meaning rides on
                  // icon + word, not motion.
                  status: const VerdictBadge(status: ProxStatus.review),
                  selectionMode: tapSelect,
                  selected: ctl.isSelected(_id(m.email)),
                  onSelectionChanged: (v) {
                    if (v) {
                      ctl.select(_id(m.email));
                    } else {
                      ctl.deselect(_id(m.email));
                    }
                  },
                ),
              ),
            ),
        ],
        SelectionToolbar(
          visible: selecting,
          selectedCount: n,
          totalCount: pending.length,
          actions: [
            SelectionToolbarAction(
              label: 'Approve $n',
              onPressed: n == 0 ? null : () => _decideSelected(true),
            ),
            SelectionToolbarAction(
              label: 'Reject $n',
              onPressed: n == 0 ? null : () => _decideSelected(false),
            ),
          ],
          onSelectAll: () => ctl.selectAll(pending.map((m) => _id(m.email))),
          // Toolbar Cancel exits selection mode entirely; the toolbar
          // contract itself is unchanged.
          onCancel: ctl.clear,
        ),
      ],
    );
  }
}
