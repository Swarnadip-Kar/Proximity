// PoseGate: the ONE narrow per-angle pose interface for enrollment.
//
// The `face_verification` gallery API is image-path only and never surfaces
// head pose, so guided angles would otherwise be instruction-only (the old
// 3-still flow pretended nothing, but also proved nothing about the angle).
// This gate runs ML Kit face detection on each captured STILL FILE
// (InputImage.fromFilePath — no camera image-stream, no extra battery) and
// checks headEulerAngleY/X against per-slot windows, so every angle is
// REALLY gated, never pretend detection.
//
// What this buys (honest): genuine-match robustness (5 pose-diverse
// templates) + some spoof cost (a single frontal print no longer suffices —
// the attacker needs 5 pose-consistent views). What it does NOT buy:
// photo/video-spoof immunity — the passive FaceNet matcher still matches a
// good screen replay held at the right angle. See the residual in
// PROXIMITY_DESIGN.md §4 and the honesty note on the session screen.
//
// Layering: pure window math lives here ([EnrollPoseWindows], unit-tested,
// no native dep). The ML Kit detector lives in pose_gate_mlkit.dart (native)
// / pose_gate_stub.dart (web fail-closed) behind the conditional export
// below — same pattern as face_verifier.dart, so records builds never link
// the detector. Tests inject [FakePoseGate]; production never constructs
// [MlkitPoseGate] where [canUseFace] is false (the session screen gates).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'face_verifier.dart';

export 'pose_gate_mlkit.dart'
    if (dart.library.html) 'pose_gate_stub.dart';

/// One pose check outcome. `ok` true advances the angle; false keeps the
/// slot with [hint] shown as the retry notice (amber targeted-rescan copy,
///
/// never a session failure).
class PoseDecision {
  final bool ok;
  final String hint;
  const PoseDecision._(this.ok, this.hint);
  const PoseDecision.ok() : this._(true, '');
  const PoseDecision.retry(String hint) : this._(false, hint);
}

/// Per-slot head-pose windows in ML Kit degrees (pure, no native calls).
///
/// ML Kit semantics (verified against the ML Kit face-detection docs +
/// google_mlkit_face_detection 0.15.1 Face model): yaw (Y) positive = facing
/// the camera's right, negative = facing left; pitch (X) positive = facing
/// up, negative = facing down. Euler Y is guaranteed only in accurate mode —
/// the ML Kit impl below uses accurate mode (same options as the plugin's
/// own detector). Null yaw/pitch (detector could not estimate) fails closed.
abstract final class EnrollPoseWindows {
  /// Max |yaw|/|pitch| for the frontal slot (near-frontal throughout).
  static const centreDeg = 12.0;

  /// Side slots: a genuine slight turn (8°) through a clear turn (35°).
  /// Beyond 35° reads as "too far" (retake hint), inside 8° as "more turn".
  static const sideMinDeg = 8.0;
  static const sideMaxDeg = 35.0;

  /// Up/down slots: slight tilt (8°) through a clear tilt (30°).
  static const tiltMinDeg = 8.0;
  static const tiltMaxDeg = 30.0;

  /// Off-axis tolerance for the non-target axis + sideways head roll (Z)
  /// for every slot: tilt tolerance, not a balance test.
  static const offAxisDeg = 15.0;
  static const rollMaxDeg = 20.0;

  /// Pure window check. Null yaw/pitch/unknown slot fail closed (never a
  /// silent accept). Roll null is tolerated (Z is advisory, not gating).
  static PoseDecision check(
      String slot, double? yaw, double? pitch, double? roll) {
    if (yaw == null || pitch == null) {
      return const PoseDecision.retry(
          'Could not read the head angle — hold still in good light and try again.');
    }
    if (roll != null && roll.abs() > rollMaxDeg) {
      return const PoseDecision.retry(
          'Straighten your head (no sideways tilt) and try again.');
    }
    switch (slot) {
      case 'centre':
        if (yaw.abs() > centreDeg || pitch.abs() > centreDeg) {
          return const PoseDecision.retry(
              'Look straight at the lens — face centred in the oval.');
        }
        return const PoseDecision.ok();
      case 'left':
        // The user turns THEIR left = faces the camera's left = yaw < 0.
        if (pitch.abs() > offAxisDeg) {
          return const PoseDecision.retry(
              'Just the sideways turn — no nodding up or down.');
        }
        if (yaw > -sideMinDeg) {
          return const PoseDecision.retry(
              'Turn a little more to your left — keep both eyes visible.');
        }
        if (yaw < -sideMaxDeg) {
          return const PoseDecision.retry(
              'Too far left — turn back a touch, keep both eyes visible.');
        }
        return const PoseDecision.ok();
      case 'right':
        if (pitch.abs() > offAxisDeg) {
          return const PoseDecision.retry(
              'Just the sideways turn — no nodding up or down.');
        }
        if (yaw < sideMinDeg) {
          return const PoseDecision.retry(
              'Turn a little more to your right — keep both eyes visible.');
        }
        if (yaw > sideMaxDeg) {
          return const PoseDecision.retry(
              'Too far right — turn back a touch, keep both eyes visible.');
        }
        return const PoseDecision.ok();
      case 'up':
        if (yaw.abs() > offAxisDeg) {
          return const PoseDecision.retry(
              'Just the slight upward tilt — no sideways turn.');
        }
        if (pitch < tiltMinDeg) {
          return const PoseDecision.retry(
              'Tilt your chin up just slightly — eyes still on the lens.');
        }
        if (pitch > tiltMaxDeg) {
          return const PoseDecision.retry(
              'Too far up — tilt back down a touch, eyes on the lens.');
        }
        return const PoseDecision.ok();
      case 'down':
        if (yaw.abs() > offAxisDeg) {
          return const PoseDecision.retry(
              'Just the slight downward tilt — no sideways turn.');
        }
        if (pitch > -tiltMinDeg) {
          return const PoseDecision.retry(
              'Tilt your chin down just slightly — eyes still on the lens.');
        }
        if (pitch < -tiltMaxDeg) {
          return const PoseDecision.retry(
              'Too far down — tilt back up a touch, eyes on the lens.');
        }
        return const PoseDecision.ok();
      default:
        return const PoseDecision.retry(
            'Unknown angle — restart the scan.');
    }
  }
}

/// Raw head-pose reading for one still file. Null yaw/pitch means the
/// detector could not estimate the angle — always fails closed downstream
/// (never a silent accept). Roll null is tolerated (advisory, not gating).
class PoseReading {
  final double? yaw;
  final double? pitch;
  final double? roll;
  const PoseReading({this.yaw, this.pitch, this.roll});
}

/// Narrow pose interface: one still file → accept/retry per slot, or a raw
/// reading for bucket classification. Never throws for unreadable/no-face/
/// multi-face (those are retry decisions / null readings); only the
/// records-only L1 gate throws, fail-closed.
abstract class PoseGate {
  Future<PoseDecision> checkSlot(String imagePath, String slot);

  /// Single detection pass for one still file. Null when the still is
  /// unreadable or holds anything but exactly one face — the caller
  /// classifies (or silently retries), never throws past the L1 gate.
  Future<PoseReading?> readPose(String imagePath);
  Future<void> close();
}

/// Bucket classifier (pure, no native calls): which UNFILLED slot does this
/// reading satisfy, in [faceEnrollSlots] priority order (centre first)?
/// Null when the reading fits nothing unfilled — a wasted still the loop
/// silently skips (BleLog only), never a guidance change. Overlaps resolve
/// by priority: a near-frontal still fills centre even mid-turn, which is
/// honest (it IS a valid frontal template); the turn buckets fill from
/// clearer turns. Filled buckets are skipped outright, so progress is
/// monotonic and filled angles are never re-requested.
abstract final class EnrollBucketFill {
  static String? classifyInto(
      double? yaw, double? pitch, double? roll, Set<String> filled) {
    for (final slot in faceEnrollSlots) {
      if (filled.contains(slot)) continue;
      if (EnrollPoseWindows.check(slot, yaw, pitch, roll).ok) return slot;
    }
    return null;
  }
}

/// Test-only fake: scripted per-call decisions (shifted in order) with an
/// accept-all default, plus call logs. [readings] scripts raw pose
/// readings (shifted in order); when exhausted it cycles the five canonical
/// bucket views, so an unscripted fake still drives a full session to
/// completion deterministically. Never shipped (DI overrides it).
class FakePoseGate implements PoseGate {
  final List<PoseDecision> _script;
  final PoseDecision fallback;
  final List<String> calls = [];
  final List<PoseReading?> _readings;
  final List<String> readCalls = [];
  static const _cycle = [
    PoseReading(yaw: 0, pitch: 0, roll: 0),
    PoseReading(yaw: -20, pitch: 0, roll: 0),
    PoseReading(yaw: 20, pitch: 0, roll: 0),
    PoseReading(yaw: 0, pitch: 15, roll: 0),
    PoseReading(yaw: 0, pitch: -15, roll: 0),
  ];
  int _cycled = 0;
  FakePoseGate(
      [List<PoseDecision> script = const [],
      this.fallback = const PoseDecision.ok(),
      List<PoseReading?> readings = const []])
      : _script = List.of(script),
        _readings = List.of(readings);

  @override
  Future<PoseDecision> checkSlot(String imagePath, String slot) async {
    calls.add('$slot:$imagePath');
    if (_script.isEmpty) return fallback;
    return _script.removeAt(0);
  }

  @override
  Future<PoseReading?> readPose(String imagePath) async {
    readCalls.add(imagePath);
    if (_readings.isNotEmpty) return _readings.removeAt(0);
    return _cycle[_cycled++ % _cycle.length];
  }

  @override
  Future<void> close() async {}
}

/// DI seam: main wires [MlkitPoseGate] (resolving to the web fail-closed
/// stub on records builds via the conditional export above — same pattern
/// as faceVerifierProvider); tests override with [FakePoseGate].
final poseGateProvider = Provider<PoseGate>((ref) {
  throw UnimplementedError('Override in main / tests');
});
