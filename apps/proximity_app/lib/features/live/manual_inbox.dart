// Manual inbox (prof live, §7.1): pending manual-attendance requests.
//
// Presentation rebuild (behavior frozen): this section composes the
// `features/manual_attendance/` module's [ManualInboxView] (§4.8) instead
// of owning checkbox selection state inline. The old checkbox-list +
// Select-all pattern is gone (hold-and-tap + SelectionToolbar per §4.1);
// decisions still delegate to the live screen (driver → draft →
// snapshot) with the same constructor, so the counts on screen always
// match the driver queue.
library;

import 'package:flutter/material.dart';

import '../../core/host_driver.dart';
import '../manual_attendance/manual_inbox.dart' show ManualInboxView;

class ManualInboxSection extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return ManualInboxView(
      pending: pending,
      onApproveOne: onApproveOne,
      onRejectOne: onRejectOne,
      onDecide: onDecide,
    );
  }
}
