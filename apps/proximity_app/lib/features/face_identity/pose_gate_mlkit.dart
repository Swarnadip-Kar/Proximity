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

  @override
  Future<PoseDecision> checkSlot(String imagePath, String slot) async {
    requireMobileFace();
    if (imagePath.trim().isEmpty) {
      return const PoseDecision.retry(
          'The still came out blank — try that angle again.');
    }
    try {
      if (!File(imagePath).existsSync()) {
        return const PoseDecision.retry(
            'The still is unreadable (file missing) — try that angle again.');
      }
      final faces =
          await _detector.processImage(InputImage.fromFilePath(imagePath));
      // Nullable detector result, guarded WITHOUT `!`: an empty list is
      // no-face (retake), never an accept.
      if (faces.isEmpty) {
        return const PoseDecision.retry(
            'No face found — centre your face in the oval and try again.');
      }
      if (faces.length > 1) {
        return const PoseDecision.retry(
            'Only you in the oval — ask others to step out of frame.');
      }
      final face = faces.first;
      return EnrollPoseWindows.check(
        slot,
        face.headEulerAngleY,
        face.headEulerAngleX,
        face.headEulerAngleZ,
      );
    } catch (e) {
      // Detector/channel error (never a throw past here): retry the angle,
      // the rest of the session is kept.
      return PoseDecision.retry(
          'Angle check failed — try that angle again. ($e)');
    }
  }

  @override
  Future<void> close() async => _detector.close();
}
