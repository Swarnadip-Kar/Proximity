// Isolate-crash regression: the 2026-09-10 SIGABRT came from the plugin's
// background-isolate verify (`verifyFromImagePathIsolate` → ML Kit reply on
// a background response handle →
// `FATAL platform_message_response_dart_port.cc Check failed: did_send`).
// The fix moves verification onto the plugin's main-isolate path
// (`verifyFromImagePath`) with exactly one call per verify, bounded by
// timeouts that degrade to the frozen fail-closed `inconclusive` verdict.
//
// What this file pins (all runnable in `flutter test`, no native channels):
//  1. main-isolate path: verify delegates to the main-isolate call exactly
//     ONCE per verify (single-reply discipline — a second in-flight reply
//     for the same handle is the same crash class), with the frozen
//     threshold (0.70) and frozen null→mismatch / boundary-score mapping.
//  2. timeout → rescan-safe StateError (driver maps it to inconclusive,
//     burns nothing — never a hang of the face-check UI).
//  3. ANY infrastructure throw → rescan-safe StateError (never a raw leak,
//     never a mis-mark); driver composition maps it to inconclusive.
//  4. PoseGate: hang/throw/0-or-2-faces → null (silent wasted beat); one
//     face maps euler → PoseReading; detection stays main-isolate by
//     construction (no compute/spawn anywhere on this path).
//
// What CANNOT be reproduced in `flutter test` (documented, not skipped):
// the native SIGABRT itself — `flutter_test` has no engine, no
// platform-message response handles, and no `did_send` check, so the abort
// is unobservable here. The regression net is therefore the call-pattern
// elimination (isolate variant unreachable: no reference remains in lib/)
// plus the Dart-catchable layer above.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';

import 'student_driver_test.dart' as helpers;

/// Records main-isolate verify invocations (args + count) with a scripted
/// outcome. There is deliberately no retry/loop: one verify → one call.
class _RecordingVerify {
  int calls = 0;
  String? lastPath;
  double? lastThreshold;
  String? lastStaffId;
  Future<String?> Function()? script;

  Future<String?> call({
    required String imagePath,
    required double threshold,
    required String? staffId,
  }) async {
    calls++;
    lastPath = imagePath;
    lastThreshold = threshold;
    lastStaffId = staffId;
    if (script != null) return script!();
    return staffId;
  }
}

Future<String> _realStill() async {
  final f = File(
      '${Directory.systemTemp.path}/prox-crashfix-${DateTime.now().microsecondsSinceEpoch}.jpg');
  await f.writeAsBytes([0, 1, 2, 3, 4]);
  return f.path;
}

/// Scripted detector: hang / throw / N faces without native channels.
class _FakeDetector extends FaceDetector {
  Future<List<Face>> Function()? script;
  int calls = 0;
  _FakeDetector() : super(options: FaceDetectorOptions());

  @override
  Future<List<Face>> processImage(InputImage inputImage) async {
    calls++;
    if (script != null) return script!();
    return [];
  }
}

Face _face({double? yaw, double? pitch, double? roll}) => Face(
      boundingBox: const Rect.fromLTWH(0, 0, 10, 10),
      landmarks: const {},
      contours: const {},
      headEulerAngleX: pitch,
      headEulerAngleY: yaw,
      headEulerAngleZ: roll,
    );

/// Driver-level stand-in for a timed-out native call: the plugin wrapper
/// converts a timeout into exactly this shape of StateError.
class _TimeoutVerifier extends FakeFaceVerifier {
  _TimeoutVerifier() : super(match: false);
  @override
  Future<FaceVerifyResult> verify(String faceId, String imagePath,
      {double threshold = kFaceThreshold}) async {
    throw StateError(
        'Face check timed out — adjust light and try again (TimeoutException)');
  }
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('crash fix (1): main-isolate verify, single call, frozen mapping',
      () {
    test('match carries the frozen 0.70 boundary, exactly one call',
        () async {
      expect(kFaceThreshold, 0.70);
      final rec = _RecordingVerify();
      final v = PluginFaceVerifier(verifyForTest: rec.call);
      final path = await _realStill();
      try {
        final res = await v.verify('face-id', path);
        expect(res.match, isTrue);
        expect(res.score, kFaceThreshold);
        expect(rec.calls, 1,
            reason: 'single-reply discipline: one verify = one channel call');
        expect(rec.lastPath, path);
        expect(rec.lastThreshold, kFaceThreshold);
        expect(rec.lastStaffId, 'face-id');
      } finally {
        await File(path).delete();
      }
    });

    test('null (no-face / below-threshold) stays mismatch, never a pass',
        () async {
      final rec = _RecordingVerify()..script = () async => null;
      final v = PluginFaceVerifier(verifyForTest: rec.call);
      final path = await _realStill();
      try {
        final res = await v.verify('face-id', path);
        expect(res.match, isFalse);
        expect(res.score, 0.0);
        expect(rec.calls, 1);
      } finally {
        await File(path).delete();
      }
    });

    test('wrong-identity hit is mismatch, never attributed to faceId',
        () async {
      final rec = _RecordingVerify()..script = () async => 'someone-else';
      final v = PluginFaceVerifier(verifyForTest: rec.call);
      final path = await _realStill();
      try {
        final res = await v.verify('face-id', path);
        expect(res.match, isFalse);
        expect(rec.calls, 1);
      } finally {
        await File(path).delete();
      }
    });

    test('custom threshold is forwarded untouched (no re-tuning here)',
        () async {
      final rec = _RecordingVerify();
      final v = PluginFaceVerifier(verifyForTest: rec.call);
      final path = await _realStill();
      try {
        await v.verify('face-id', path, threshold: 0.8);
        expect(rec.lastThreshold, 0.8);
        expect(rec.calls, 1);
      } finally {
        await File(path).delete();
      }
    });
  });

  group('crash fix (2+3): timeout/throw degrade to rescan-safe errors', () {
    test('hung native call times out instead of hanging the UI', () async {
      final rec = _RecordingVerify()
        ..script = () => Completer<String?>().future;
      final v = PluginFaceVerifier(
        verifyForTest: rec.call,
        verifyTimeout: const Duration(milliseconds: 50),
      );
      final path = await _realStill();
      try {
        await expectLater(
          v.verify('face-id', path),
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message', contains('timed out'))),
        );
        expect(rec.calls, 1, reason: 'no retry loop behind the timeout');
      } finally {
        await File(path).delete();
      }
    });

    test('infrastructure throw becomes a rescan-safe StateError', () async {
      final rec = _RecordingVerify()
        ..script = () => throw Exception('channel boom');
      final v = PluginFaceVerifier(verifyForTest: rec.call);
      final path = await _realStill();
      try {
        await expectLater(
          v.verify('face-id', path),
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message', contains('did not read clearly'))),
        );
        expect(rec.calls, 1);
      } finally {
        await File(path).delete();
      }
    });

    test('driver maps the timeout-shaped throw to inconclusive (burns 0)',
        () async {
      final d = helpers.testDriver(
        store: await helpers.enrolledStore(),
        verifier: _TimeoutVerifier(),
        engine: ProxBleEngine(radio: FakeBleRadio()),
      );
      final res = await d.checkFace('still.jpg');
      expect(res.match, FaceMatch.inconclusive,
          reason: 'timeout must rescan, never pass or burn');
      expect(res.faceValidAtMs, 0);
    });

    test('driver mapping frozen: null-hit is still mismatch (burns 1)',
        () async {
      final d = helpers.testDriver(
        store: await helpers.enrolledStore(),
        verifier: helpers.mockVerifier(match: false),
        engine: ProxBleEngine(radio: FakeBleRadio()),
      );
      final res = await d.checkFace('still.jpg');
      expect(res.match, FaceMatch.mismatch);
    });
  });

  group('crash fix (4): pose gate stays main-isolate, fail-closed', () {
    test('hanging detector times out to null (loop never stalls)',
        () async {
      final det = _FakeDetector()
        ..script = () => Completer<List<Face>>().future;
      final gate = MlkitPoseGate(
          detector: det, detectTimeout: const Duration(milliseconds: 50));
      final path = await _realStill();
      try {
        expect(await gate.readPose(path), isNull);
        expect(det.calls, 1);
      } finally {
        await File(path).delete();
      }
    });

    test('detector throw / 0 faces / 2 faces all map to null', () async {
      final det = _FakeDetector();
      final gate = MlkitPoseGate(detector: det);
      final path = await _realStill();
      try {
        det.script = () => throw Exception('channel boom');
        expect(await gate.readPose(path), isNull);
        det.script = () async => [];
        expect(await gate.readPose(path), isNull);
        det.script = () async => [_face(yaw: 0, pitch: 0), _face(yaw: 0, pitch: 0)];
        expect(await gate.readPose(path), isNull);
      } finally {
        await File(path).delete();
      }
    });

    test('file yaw is mirrored to holder-perspective (front camera)',
        () async {
      // The takePicture file is unmirrored while the holder follows a
      // mirrored preview, so file-space yaw has the opposite sign of the
      // holder's own left/right (field 2026-09-13: turning to YOUR left
      // filled the RIGHT bucket). Here the fake detector reports
      // file-space -20 (a turn to the holder's own right); the gate must
      // surface holder-space +20 — the convention EnrollPoseWindows
      // speaks (right = positive). Pitch/roll are mirror-invariant and
      // pass through untouched.
      final det = _FakeDetector()
        ..script = () async => [_face(yaw: -20, pitch: 5, roll: 2)];
      final gate = MlkitPoseGate(detector: det);
      final path = await _realStill();
      try {
        final reading = await gate.readPose(path);
        expect(reading, isNotNull);
        expect(reading!.yaw, 20);
        expect(reading.pitch, 5);
        expect(reading.roll, 2);
        expect(det.calls, 1);
      } finally {
        await File(path).delete();
      }
    });

    test('null file yaw stays null (never a silent accept)', () async {
      final det = _FakeDetector()
        ..script = () async => [_face(yaw: null, pitch: 5, roll: 2)];
      final gate = MlkitPoseGate(detector: det);
      final path = await _realStill();
      try {
        final reading = await gate.readPose(path);
        expect(reading, isNotNull);
        expect(reading!.yaw, isNull);
        expect(reading.pitch, 5);
      } finally {
        await File(path).delete();
      }
    });
  });
}
