// Manual inbox (prof live, §7.1): pending manual-attendance requests.
//
// Composes the `features/manual_attendance/` module's [ManualInboxView] (§4.8) instead
// of owning checkbox selection state inline. The old checkbox-list +
// Select-all pattern is gone (tap-to-select + SelectionToolbar per §4.1,
// same contract as the review/export picker); decisions still delegate
// to the live screen (driver → draft → snapshot) with the same
// constructor, so the counts on screen always match the driver queue.
//
// The host driver is a plain Provider over mutating server state — it never
// notifies, so this section used to re-render only when its callers
// rebuilt (a focused section builds once; the take host while idle
// rebuilds only on waiting-room deltas). This section now polls the
// LOCAL `manualPending` getter on the existing 2s cadence (take idle poll
// when the pending set actually changes: no extra network/proof load,
// decided rows still leave via the existing decide + prune paths, and the
// timer is cancelled on dispose. Read-only on the driver (no driver
// changes). Without a driver in scope (widget tests) this stays a pure
// function of the `pending` prop.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/host_driver.dart';
import '../manual_attendance/manual_inbox.dart' show ManualInboxView;

class ManualInboxSection extends ConsumerStatefulWidget {
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
  ConsumerState<ManualInboxSection> createState() =>
      _ManualInboxSectionState();
}

class _ManualInboxSectionState extends ConsumerState<ManualInboxSection> {
  Timer? _poll;

  /// Signature of the last rendered pending set (sorted `email:status`
  /// pairs — arrivals, decisions, and status flips all change it).
  String _sig = '';

  static String _sigOf(List<ManualRow> rows) {
    final parts = [
      for (final m in rows) '${m.email.toLowerCase()}:${m.status}',
    ]..sort();
    return parts.join('|');
  }

  @override
  void initState() {
    super.initState();
    _sig = _sigOf(widget.pending);
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  /// Rebuilds only when the local pending set actually changed (an
  /// unconditional setState here would keep widget tests from settling
  /// and churn the list every 2s).
  void _refresh() {
    if (!mounted) return;
    List<ManualRow> fresh;
    try {
      fresh = ref.read(hostDriverProvider).manualPending;
    } catch (_) {
      // No driver in scope (widget tests): prop-driven only, never throw
      // out of a timer (a throw here would fail `takeException`-guarded
      // tests without rendering anything wrong).
      return;
    }
    if (_sigOf(fresh) != _sig) setState(() {});
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Fresh driver state wins when a driver is in scope; otherwise this
    // stays a pure function of the `pending` prop. The signature re-syncs
    // against what was last rendered, so the timer converges after a
    // single rebuild per change (never a loop).
    var pending = widget.pending;
    try {
      pending = ref.read(hostDriverProvider).manualPending;
      _sig = _sigOf(pending);
    } catch (_) {
      _sig = _sigOf(widget.pending);
    }
    return ManualInboxView(
      pending: pending,
      onApproveOne: widget.onApproveOne,
      onRejectOne: widget.onRejectOne,
      onDecide: widget.onDecide,
    );
  }
}
