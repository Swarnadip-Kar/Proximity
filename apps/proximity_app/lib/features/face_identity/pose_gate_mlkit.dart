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

  /// One detection pass, shared by every caller. Null on all non-usable
  /// outcomes (blank/missing/unreadable file, anything but exactly one
  /// face, detector/channel error) — the caller maps null to a silent
  /// wasted beat, never a throw past the L1 gate, never an accept.
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
