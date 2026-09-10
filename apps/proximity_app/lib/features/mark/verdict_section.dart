// Terminal-verdict section (student mark host composition): builds the
// verdict widget for a terminal mark phase.
//
// Single-purpose split from `screens/student_home.dart` (Mark slim-down):
// widget-building ONLY — the host keeps all timers/drivers/drafts/nav/
// gate orchestration and passes its callbacks in. Every terminal phase
// lands on the same [onBackToBrowsing] teardown so back from any verdict
// (marked/late/manual-decided/wrong-org/needs-review/no-signal) resets
// the mark-tab phase to browsing in one step, never stepping through
// waiting/face/proving. All verdict copy stays verbatim (frozen) inside
// `verdict_view.dart`.
library;

import 'package:flutter/material.dart';

import 'mark_phase.dart';
import 'verdict_view.dart';

/// Builds the verdict widget for a terminal [phase]. Non-terminal phases
/// are a programming error here (the host switch only calls this for its
/// verdict arms).
Widget markVerdictSection({
  required StudentPhase phase,
  required String ackDetail,
  required String infoDetail,
  required String wrongClassOrg,
  required String wrongMyOrg,
  required List<String> roundMarks,
  required int attemptsLeft,
  required VoidCallback onBackToBrowsing,
  required VoidCallback onRequestManual,
  required VoidCallback onRetryFace,
}) {
  return switch (phase) {
    StudentPhase.marked => MarkVerdictView(
        kind: MarkVerdict.marked,
        detail: ackDetail,
        roundMarks: roundMarks,
        onRetryFace: () {},
        onManualInstead: () {},
        onBack: onBackToBrowsing,
      ),
    StudentPhase.late => MarkVerdictView(
        kind: MarkVerdict.late,
        detail: ackDetail,
        roundMarks: roundMarks,
        onRetryFace: () {},
        onManualInstead: onRequestManual,
        onBack: onBackToBrowsing,
      ),
    StudentPhase.wrongOrg => MarkVerdictView(
        kind: MarkVerdict.wrongOrg,
        detail: ackDetail,
        classOrg: wrongClassOrg,
        myOrg: wrongMyOrg,
        roundMarks: const [],
        onRetryFace: () {},
        onManualInstead: onRequestManual,
        onBack: onBackToBrowsing,
      ),
    StudentPhase.needsReview => MarkVerdictView(
        kind: MarkVerdict.needsReview,
        detail: '',
        roundMarks: const [],
        attemptsLeft: attemptsLeft,
        onRetryFace: onRetryFace,
        onManualInstead: onRequestManual,
        onBack: onBackToBrowsing,
      ),
    StudentPhase.noSignal => MarkVerdictView(
        kind: MarkVerdict.noSignal,
        detail: ackDetail,
        infoDetail: infoDetail,
        roundMarks: const [],
        onRetryFace: () {},
        onManualInstead: onRequestManual,
        onBack: onBackToBrowsing,
      ),
    _ => throw ArgumentError('markVerdictSection: non-verdict $phase'),
  };
}
