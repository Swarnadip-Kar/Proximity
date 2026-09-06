import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:proximity_app/core/edgeface.dart';
import 'package:proximity_app/core/face_detect.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('aligned pipeline embeds a good frame, rejects garbage',
      () async {
    // Fake detector: deterministic centered keypoints so the alignment +
    // embedding path is exercised without a camera.
    final e = EdgeFaceEmbedder(detector: FakeFaceDetector());
    try {
      await e.load();
    } on FaceModelMissing {
      // Asset or TFLite native runtime unavailable in this test env:
      // embed must fail closed with the same actionable error.
      await expectLater(
          e.embed(const [1, 2, 3]), throwsA(isA<FaceModelMissing>()));
      return;
    }
    try {
      // Textured mid-grey frame: passes every quality gate → 512-D unit
      // vector, L2-normalized for cosine space.
      final frame = img.Image(width: 112, height: 112);
      for (var y = 0; y < 112; y++) {
        for (var x = 0; x < 112; x++) {
          final v = 128 + (((x ~/ 4) + (y ~/ 4)) % 2 == 0 ? 18 : -18);
          frame.setPixel(x, y, img.ColorRgb8(v, v, v));
        }
      }
      final emb = await e.embed(img.encodeJpg(frame));
      expect(emb, hasLength(EdgeFaceEmbedder.embeddingDim));
      final norm =
          math.sqrt(emb.fold<double>(0, (acc, v) => acc + v * v));
      expect(norm, closeTo(1.0, 1e-6));
      // Blank frame: unreadable input fails closed like undecodable bytes
      // (poor frames must never embed into matchable vectors).
      final blank = img.encodeJpg(img.Image(width: 112, height: 112));
      await expectLater(e.embed(blank), throwsA(isA<StateError>()));
    } finally {
      e.close();
    }
    expect(e.isLoaded, isFalse);
  });

  test('real detector rejects faceless bytes instead of embedding',
      () async {
    final e = EdgeFaceEmbedder();
    try {
      await e.load();
    } on FaceModelMissing {
      return; // covered above; nothing real to probe here.
    }
    try {
      final frame = img.encodeJpg(img.Image(width: 112, height: 112));
      await expectLater(e.embed(frame), throwsA(isA<StateError>()));
    } finally {
      e.close();
    }
  });
}
