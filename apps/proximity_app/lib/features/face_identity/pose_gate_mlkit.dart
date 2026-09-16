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

import 'dart:async';
import 'dart:io';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../core/platformx.dart';
import 'pose_gate.dart';

/// Production backend: ML Kit on the still file. Mobile-only — the L1 gate
/// fires first (records-only devices fail closed before any channel call).
///
/// MAIN-ISOLATE ONLY: every call here must run on the main isolate. ML Kit
/// face detection answers over a MethodChannel, and a reply redeemed on a
/// background isolate's response handle aborts the engine with
/// `FATAL platform_message_response_dart_port.cc Check failed: did_send` →
/// SIGABRT (temp.log 2026-09-10: the plugin's `verifyFromImagePathIsolate`
/// worker detected 0 faces successfully and THEN the success reply killed
/// the process — uncatchable in Dart). The enrollment loop that drives
/// this gate already runs on the main isolate; never wrap these calls in
/// `compute`/`Isolate.spawn`, and never pass this gate across isolates.
class MlkitPoseGate implements PoseGate {
  final FaceDetector _detector;

  /// Upper bound for one still-file detection pass (device log showed
  /// ~290ms). A hung detector degrades to null (the caller wastes the
  /// beat silently) instead of stalling the enrollment loop.
  final Duration detectTimeout;

  MlkitPoseGate({
    FaceDetector? detector,
    this.detectTimeout = const Duration(seconds: 10),
  }) : _detector = detector ??
            FaceDetector(
              options: FaceDetectorOptions(
                // Landmarks/contours are never consumed (pose needs Euler
                // angles + the liveness gate needs the box only) — leaving
                // them on only spams logcat (`Unknown landmark type`) on
                // detectors whose landmark enum is newer than the plugin's,
                // plus wasted native latency per still.
                enableLandmarks: false,
                enableContours: false,
                // Accurate mode stays: Euler Y is only guaranteed there.
                performanceMode: FaceDetectorMode.accurate,
              ),
            );

  /// One detection pass, shared by every caller. Null on all non-usable
  /// outcomes (blank/missing/unreadable file, anything but exactly one
  /// face, detector/channel error, timeout) — the caller maps null to a
  /// silent wasted beat, never a throw past the L1 gate, never an accept.
  /// The nullable detector result is guarded WITHOUT `!`.
  Future<Face?> _detect(String imagePath) async {
    if (imagePath.trim().isEmpty) return null;
    try {
      if (!File(imagePath).existsSync()) return null;
      final faces = await _detector
          .processImage(InputImage.fromFilePath(imagePath))
          .timeout(detectTimeout);
      if (faces.length != 1) return null;
      return faces.first;
    } on TimeoutException {
      // Hung detector: same fail-closed null as any other unreadable
      // outcome — the loop wastes the beat silently, never throws.
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PoseReading?> readPose(String imagePath) async {
    requireMobileFace();
    final face = await _detect(imagePath);
    if (face == null) return null;
    // Front-camera mirror correction (field-verified 2026-09-13: turning
    // to YOUR left filled the RIGHT bucket): the enrollment camera is the
    // front lens and takePicture stills are stored unmirrored, while the
    // preview the holder follows is mirrored. ML Kit reports yaw in file
    // space, so file-space yaw has the opposite sign of the holder's own
    // left/right. Negating here converts to holder-perspective yaw —
    // the convention [EnrollPoseWindows]/[EnrollBucketFill] and every
    // canonical test vector already use (left = negative). Pitch/roll are
    // unaffected by a horizontal mirror and pass through untouched.
    final fileYaw = face.headEulerAngleY;
    return PoseReading(
      yaw: fileYaw == null ? null : -fileYaw,
      pitch: face.headEulerAngleX,
      roll: face.headEulerAngleZ,
    );
  }

  @override
  Future<void> close() async => _detector.close();
}
