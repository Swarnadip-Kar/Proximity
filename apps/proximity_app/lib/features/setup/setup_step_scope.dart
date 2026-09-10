// SetupFlow step scope: lets step content drive the stepper instead of
// pushing standalone routes when hosted inside SetupFlowScreen.
//
// The scope is present ONLY inside SetupFlowScreen. Every branch that
// consults it falls back to the legacy push/pop when the scope is absent,
// so standalone routes (deep-links, previews, widget tests) and the
// openBundle/openCapture/openResult chain behave byte-for-byte as before.
library;

import 'package:flutter/widgets.dart';

/// Canonical SetupFlow page indices (single source of truth shared by the
/// orchestrator and the step-local back targets).
///
/// Pagination (2026-09-10 `## Setup pagination`, revised by
/// `## About-page removal` the same day): the flow is six one-purpose
/// pages — Confirm device (device facts) → Account & key (inputs +
/// Continue). Welcome, Capture, and Result stay one page each (audit in
/// INTEGRATION_LOG). The About-to-enroll explainer page was removed from
/// the flow per product-owner decision; its sections stay live on the
/// standalone deep-linkable EnrollIntroScreen (intro_sections shared).
/// Capture/Result indices are 4/5; order semantics and start-index
/// conditions are behavior-identical (first incomplete page wins).
abstract final class SetupStep {
  /// Sign in (welcome).
  static const welcome = 0;

  /// Pick role (roles hub).
  static const role = 1;

  /// Confirm device (which account, which device, move status).
  static const device = 2;

  /// Account & key (ID entry + device key + Continue to face scan).
  static const accountKey = 3;

  /// Capture face (5-angle session).
  static const capture = 4;

  /// Done (save + claim outcome).
  static const result = 5;

  static const count = 6;
}

/// Stepper controls for the enclosing SetupFlowScreen.
class SetupStepScope extends InheritedWidget {
  /// Currently visible step index.
  final int index;

  /// Total step count ([SetupStep.count]).
  final int count;

  /// Advance one step (no-op past the last step).
  final Future<void> Function() next;

  /// Go back one step (no-op on the first step — the orchestrator routes
  /// first-step back to [SetupFlowScreen.onFirstBack]).
  final Future<void> Function() back;

  /// Jump to an explicit step ([SetupStep] index, clamped).
  final Future<void> Function(int step) goTo;

  /// Finish the flow (lands on mark/browse, never the roles hub).
  final Future<void> Function() complete;

  const SetupStepScope({
    super.key,
    required this.index,
    required this.count,
    required this.next,
    required this.back,
    required this.goTo,
    required this.complete,
    required super.child,
  });

  /// Null outside SetupFlowScreen (standalone routes/tests).
  static SetupStepScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SetupStepScope>();

  @override
  bool updateShouldNotify(SetupStepScope old) =>
      old.index != index || old.count != count;
}
