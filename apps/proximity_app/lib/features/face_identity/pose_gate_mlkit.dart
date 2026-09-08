// MlkitPoseGate: production pose backend (native Android/iOS only).
//
// ML Kit face detection (google_mlkit_face_detection, accurate mode — the
// same options the face_verification plugin's own detector uses, so Euler Y
// is actually reported) on the captured STILL FILE. No image-stream: the
// session camera takes one takePicture per angle and this checks the file,
// which keeps battery/perf identical to the old stills flow.
//
// Fail-closed mapping (never a throw past the L1 gate, never a silent
// accept): empty path / missing file / detector error → retry; no face →
// "centre your face"; multiple faces → "only you"; null euler → retry via
// [EnrollPoseWindows]. Split from pose_gate.dart so the web records build
// never imports the ML Kit plugin (see pose_gate_stub.dart).
library;

import 'dart:io';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../core/platformx.dart';
import 'pose_gate.dart';

/// Production backend: ML Kit on the still file. Mobile-only — the L1 gate
/// fires first (records-only devices fail closed before any channel call).
class MlkitPoseGate implements PoseGate {
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      enableContours: true,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  MlkitPoseGate();

  /// One detection pass, shared by [checkSlot] and [readPose]. Null on
  /// every non-usable outcome (blank/missing/unreadable file, anything but
  /// exactly one face, detector/channel error) — callers map null to
  /// retry/silent-skip, never a throw past the L1 gate, never an accept.
  /// The nullable detector result is guarded WITHOUT `!`.
  Future<Face?> _detect(String imagePath) async {
    if (imagePath.trim().isEmpty) return null;
    try {
      if (!File(imagePath).existsSync()) return null;
      final faces =
          await _detector.processImage(InputImage.fromFilePath(imagePath));
      if (faces.length != 1) return null;
      return faces.first;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PoseDecision> checkSlot(String imagePath, String slot) async {
    requireMobileFace();
    if (imagePath.trim().isEmpty) {
      return const PoseDecision.retry(
          'The still came out blank — try that angle again.');
    }
    final face = await _detect(imagePath);
    if (face == null) {
      // Missing/unreadable file, no face, multiple faces, or detector
      // error: one fail-closed retry (the caller keeps the session).
      // NOTE: no-face vs multi-face copy merged here — the session's
      // bucket loop stays silent and only needs retry/null, not reasons.
      return const PoseDecision.retry(
          'That still is unusable — centre your face in the oval, only you in frame, and hold still.');
    }
    return EnrollPoseWindows.check(
      slot,
      face.headEulerAngleY,
      face.headEulerAngleX,
      face.headEulerAngleZ,
    );
  }

  @override
  Future<PoseReading?> readPose(String imagePath) async {
    requireMobileFace();
    final face = await _detect(imagePath);
    if (face == null) return null;
    return PoseReading(
      yaw: face.headEulerAngleY,
      pitch: face.headEulerAngleX,
      roll: face.headEulerAngleZ,
    );
  }

  @override
  Future<void> close() async => _detector.close();
}
