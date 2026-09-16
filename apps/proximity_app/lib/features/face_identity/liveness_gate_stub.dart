// Web records-only stub for liveness_gate_native.dart: identical public
// API (HeuristicLivenessGate), every check refuses. The web app never runs
// liveness (records only, canUseFace is false and checkFace blocks before
// the gate); this exists so the shared liveness_gate.dart + student_driver
// compile for web without dart:io. Native builds use
// liveness_gate_native.dart. Mirror the class members here or the web
// build fails loudly (by design).
library;

import 'liveness_gate.dart';

/// Fail-closed liveness stand-in: construction is harmless (DI never picks
/// it on web — checkFace blocks records-only devices first), checks refuse
/// — SK never signs without a holder check. (Historical class name kept
/// for the shared wiring; the native scorer is the MiniFASNetV2 model.)
class HeuristicLivenessGate implements LivenessGate {
  final Duration budget;

  const HeuristicLivenessGate({
    this.budget = const Duration(milliseconds: 1200),
  });

  static StateError _blocked() => StateError(
      'Face verification needs the mobile app (Android/iOS) — this device is records-only.');

  @override
  Future<LivenessResult> detectPassive(String imagePath) async =>
      throw _blocked();
}
