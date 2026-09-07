// Fake face detector + provider wiring, split out of face_detect.dart.
// Extraction only — no math, thresholds, or pose behavior changed here.
// face_detect.dart re-exports this file, so existing
// `import 'core/face_detect.dart'` call sites keep working untouched
// (including files owned by sibling tracks, which this track must not edit).
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'face_detect.dart';

/// Test / preview stand-in: scripted face cycling front/left/right/up/down
/// poses so guided-slot scans complete in tests exactly as on device —
/// each slot waits for its own pose. Yaw cycles via nose-x
/// [0.0/+0.30/−0.30]; pitch cycles via nose-y (frontal 0.55 → up 0.505 →
/// down 0.60, i.e. pitch ≈0.54/0.35/0.75). Pair with [FakeFaceCamera]
/// (textured stills) to exercise the scan loop without a camera.
class FakeFaceDetector implements FaceDetector {
  int _calls = 0;
  @override
  bool get isLoaded => true;
  @override
  Future<void> load() async {}
  @override
  Future<List<FaceDetection>> detect(Uint8List jpegBytes) async {
    _calls++;
    // 5-pose cycle: front, left, right, up, down.
    const noseX = [0.50, 0.548, 0.452, 0.50, 0.50];
    const noseY = [0.55, 0.55, 0.55, 0.505, 0.60];
    final i = (_calls - 1) % 5;
    return [
      FaceDetection(
        box: const [0.3, 0.3, 0.7, 0.7],
        keypoints: [
          const Offset(0.42, 0.42),
          const Offset(0.58, 0.42),
          Offset(noseX[i], noseY[i]),
          const Offset(0.50, 0.66),
          const Offset(0.34, 0.50),
          const Offset(0.66, 0.50),
        ],
        score: 0.95,
      ),
    ];
  }

  @override
  void close() {}
}

final faceDetectorProvider = Provider<FaceDetector>((ref) {
  throw UnimplementedError('Override with BlazeFaceDetector / FakeFaceDetector');
});
