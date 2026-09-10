// SetupFlow step scope: lets step content drive the stepper instead of
// pushing standalone routes when hosted inside SetupFlowScreen.
//
// The scope is present ONLY inside SetupFlowScreen. Every branch that
// consults it falls back to the legacy push/pop when the scope is absent,
// so standalone routes (deep-links, previews, widget tests) and the
// openBundle/openCapture/openResult chain behave byte-for-byte as before.
library;

import 'package:flutter/widgets.dart';

/// Canonical SetupFlow step indices (single source of truth shared by the
/// orchestrator and the step-local back targets).
abstract final class SetupStep {
  /// Sign in (welcome).
  static const welcome = 0;

  /// Pick role (roles hub).
  static const role = 1;

  /// Confirm device + about-to-enroll (combined device+intro step).
  static const deviceIntro = 2;

  /// Capture face (5-angle session).
  static const capture = 3;

  /// Done (save + claim outcome).
  static const result = 4;

  static const count = 5;
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
