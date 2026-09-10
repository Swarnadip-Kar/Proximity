// Manual inbox UI (new, §4.8).
//
// The professor-side approve/reject list, owned by the
// `features/manual_attendance/` module and composed by `live/<course>/inbox`
// (focused section) and the take-attendance host screen — never bespoke
// approve/reject UI inline in either. Routes unchanged; module boundary
// only.
//
// Selection is hold-and-tap (§4.1, no checkboxes anywhere): long-press
// enters selection for this list, taps toggle, the [SelectionToolbar]
// offers `Approve N · Reject N · Select all · Cancel`. Selection state
// lives in this list's OWN [SelectionScope] instance (per-list rule —
// never shared with the roster or any other list).
//
// Decision paths are the host's (driver `decideManual` + draft + snapshot,
// wired by the callers) and are preserved exactly:
//  - exactly one selected + Approve/Reject → [onApproveOne]/[onRejectOne]
//    (the single-item path, incl. its log line + per-row clear);
//  - several selected → [onDecide] (the bulk path, incl. its bulk log).
library;

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
      return;
    }
    await widget.onDecide(emails, approve);
    if (mounted) ctl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final pending = _forPending();
    final ctl = ref.watch(selectionControllerProvider);
    _pruneStale(ctl);
    final selecting = ctl.selecting;
    final n = ctl.count;
    final c = ProximityColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.zero,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Manual requests (${pending.length})',
                  style: ProxType.title(color: c.contentPrimary),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: ProxSpacing.sm),
        if (pending.isEmpty)
          const ProxEmptyLine('No manual requests.')
        else ...[
          // One-time hold-to-select hint (§9): once per install, hidden
          // while selecting (the toolbar owns that moment).
          SelectionCoachMark(
            listType: SelectionCoachMarks.inbox,
            selecting: selecting,
          ),
          for (final m in pending)
            Padding(
              padding: const EdgeInsets.only(bottom: ProxSpacing.sm),
              child: StudentCard(
                key: ValueKey<String>('manual-${m.email}'),
                name: m.name.isNotEmpty ? m.name : m.email,
                subtitle: rosterSubtitle(m.roll, m.email),
                // Static (never pulsing) badge: a periodic pulse would
                // keep widget tests from settling; meaning rides on
                // icon + word, not motion.
                status: const VerdictBadge(status: ProxStatus.review),
                selectionMode: selecting,
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
          onCancel: ctl.clear,
        ),
      ],
    );
  }
}
