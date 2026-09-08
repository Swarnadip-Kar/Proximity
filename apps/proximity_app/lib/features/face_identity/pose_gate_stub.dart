// Web records-only stub for pose_gate_mlkit.dart: identical public API
// (MlkitPoseGate), every check refuses. The web app never enrolls (records
// only, canUseFace is false and the session screen shows FaceBlockedCard);
// this exists so the shared pose_gate.dart compiles for web without the
// ML Kit plugin. Native builds use pose_gate_mlkit.dart. Mirror the class
// members here or the web build fails loudly (by design).
library;

import 'pose_gate.dart';

/// Fail-closed pose stand-in: construction is harmless (DI never picks it
/// on web), checks refuse — enrollment cannot validate without the gate.
class MlkitPoseGate implements PoseGate {
  MlkitPoseGate();

  static StateError _blocked() => StateError(
      'Face enrollment needs the mobile app (Android/iOS) — this device is records-only.');

  @override
  Future<PoseDecision> checkSlot(String imagePath, String slot) async =>
      throw _blocked();

  @override
  Future<void> close() async {}
}
