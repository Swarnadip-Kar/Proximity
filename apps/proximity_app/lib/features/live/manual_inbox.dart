// Manual inbox (prof live): pending manual-attendance requests with
// select-all + approve/reject (single + bulk).
//
// This section owns the checkbox selection state. Decisions delegate to
// the live screen (driver → draft → snapshot); the inbox only clears the
// decided rows from its selection once the decision lands, so the counts
// on screen always match the driver queue.
library;

import 'package:flutter/material.dart';

import '../../core/host_driver.dart';
import '../../design/tokens.dart';
import '../../widgets/partial_list.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_states.dart';

class ManualInboxSection extends StatefulWidget {
  final List<ManualRow> pending;
  final Future<void> Function(String email) onApproveOne;
  final Future<void> Function(String email) onRejectOne;
  final Future<void> Function(List<String> emails, bool approve) onDecide;

  const ManualInboxSection({
    super.key,
    required this.pending,
    required this.onApproveOne,
    required this.onRejectOne,
    required this.onDecide,
  });

  @override
  State<ManualInboxSection> createState() => _ManualInboxSectionState();
}

class _ManualInboxSectionState extends State<ManualInboxSection> {
  final Set<String> _selected = {};

  void _toggle(String email, bool? v) {
    setState(() {
      if (v == true) {
        _selected.add(email.toLowerCase());
      } else {
        _selected.remove(email.toLowerCase());
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selected.length == widget.pending.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(widget.pending.map((m) => m.email.toLowerCase()));
      }
    });
  }

  Future<void> _approveOne(String email) async {
    await widget.onApproveOne(email);
    if (mounted) setState(() => _selected.remove(email.toLowerCase()));
  }

  Future<void> _rejectOne(String email) async {
    await widget.onRejectOne(email);
    if (mounted) setState(() => _selected.remove(email.toLowerCase()));
  }

  Future<void> _decideSelected(bool approve) async {
    final emails = _selected.toList();
    await widget.onDecide(emails, approve);
    if (mounted) setState(() => _selected.clear());
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.pending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ProxSectionHeader(
          title: 'Manual requests (${pending.length})',
          padding: EdgeInsets.zero,
          trailing: pending.isEmpty
              ? null
              : TextButton(
                  onPressed: _toggleSelectAll,
                  child: Text(_selected.length == pending.length
                      ? 'Clear all'
                      : 'Select all'),
                ),
        ),
        if (pending.isEmpty)
          const ProxEmptyLine('No manual requests.')
        else ...[
          for (final m in pending)
            ProxFadeSlideIn(
              key: ValueKey<String>('manual-${m.email}'),
              child: CheckboxListTile(
                dense: true,
                value: _selected.contains(m.email.toLowerCase()),
                onChanged: (v) => _toggle(m.email, v),
                title: Text(m.name.isNotEmpty ? m.name : m.email),
                subtitle: Text(rosterSubtitle(m.roll, m.email)),
                secondary: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(Icons.check,
                          color:
                              ProxStateColors.of(context, ProxState.marked)),
                      tooltip: 'Approve',
                      onPressed: () => _approveOne(m.email),
                    ),
                    IconButton(
                      icon: Icon(Icons.close,
                          color:
                              ProxStateColors.of(context, ProxState.error)),
                      tooltip: 'Reject',
                      onPressed: () => _rejectOne(m.email),
                    ),
                  ],
                ),
              ),
            ),
          Row(
            children: [
              ProxPrimaryButton(
                label: const Text('Approve selected'),
                onPressed: _selected.isEmpty
                    ? null
                    : () => _decideSelected(true),
                expanded: false,
              ),
              const SizedBox(width: 8),
              ProxSecondaryButton(
                label: const Text('Reject'),
                onPressed: _selected.isEmpty
                    ? null
                    : () => _decideSelected(false),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
