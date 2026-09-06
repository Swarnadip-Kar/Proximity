import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:proximity_app/core/face_camera.dart';
import 'package:proximity_app/core/face_detect.dart';

List<List<double>> _zeroBoxes() =>
    List.generate(896, (_) => List.filled(16, 0.0));

FaceDetection _det(List<Offset> kps) => FaceDetection(
      box: const [0.3, 0.3, 0.7, 0.7],
      keypoints: kps,
      score: 0.9,
    );

void main() {
  group('frame routing', () {
    test('analyzeFrame routes detection, sanity and luminance', () {
      expect(analyzeFrame(faces: 0, luma: 128), FrameQuality.noFace);
      expect(analyzeFrame(faces: 1, luma: 128, sane: false),
          FrameQuality.badPose);
      expect(analyzeFrame(faces: 1, luma: null), FrameQuality.unclear);
      expect(analyzeFrame(faces: 1, luma: 10), FrameQuality.tooDark);
      expect(analyzeFrame(faces: 1, luma: 250), FrameQuality.tooBright);
      expect(analyzeFrame(faces: 1, luma: 128), FrameQuality.good);
    });
  });

  group('anchors', () {
    test('896 fixed-size anchors, 16px grid first', () {
      final a = blazeAnchors();
      expect(a, hasLength(896));
      // First cell (0.5/16), aspect + interpolated pair.
      expect(a[0][0], closeTo(0.03125, 1e-9));
      expect(a[0][1], closeTo(0.03125, 1e-9));
      expect(a[0][2], 1.0);
      expect(a[0][3], 1.0);
      expect(a[1][0], closeTo(0.03125, 1e-9));
      // Second cell steps one stride in x.
      expect(a[2][0], closeTo(0.09375, 1e-9));
      // 16x16 grid x2 anchors, then three 8x8 grids x2.
      expect(a[510][0], closeTo(0.96875, 1e-9));
      expect(a[510][1], closeTo(0.96875, 1e-9));
      expect(a[511][0], closeTo(0.96875, 1e-9));
      expect(a[512][0], closeTo(0.0625, 1e-9));
      expect(a[512][1], closeTo(0.0625, 1e-9));
    });
  });

  group('decode', () {
    test('all-zero raw output decodes to anchor centers at score 0.5', () {
      final dets = decodeBlaze(
          _zeroBoxes(), List.filled(896, 0.0));
      // sigmoid(0) = 0.5 clears the 0.5 floor.
      expect(dets, hasLength(896));
      final d = dets.firstWhere((e) =>
          (e.v[1] - 0.03125).abs() < 1e-9 && (e.v[0] - 0.03125).abs() < 1e-9);
      expect(d.score, closeTo(0.5, 1e-9));
      // Zero-size box collapses onto the anchor center.
      expect(d.v[2], closeTo(d.v[0], 1e-9));
      // Keypoints coincide with the anchor center too.
      expect(d.v[4], closeTo(0.03125, 1e-9));
      expect(d.v[5], closeTo(0.03125, 1e-9));
    });

    test('scores below floor are dropped', () {
      final dets = decodeBlaze(_zeroBoxes(), List.filled(896, -10.0));
      expect(dets, isEmpty);
    });

    test('crafted regression decodes to exact geometry', () {
      final boxes = _zeroBoxes();
      // Anchor 0 center (0.03125, 0.03125): shift +0.1 in x, box 0.1 wide.
      boxes[0] = [
        12.8, // dx: 12.8/128*1 + 0.03125 = 0.13125
        0.0,
        12.8, // w: 12.8/128 = 0.1
        12.8, // h: 0.1
        6.4, -6.4, // kp0: (0.08125, -0.01875)
        ...List.filled(10, 0.0),
      ];
      final scores = List.filled(896, -10.0)..[0] = 0.0;
      final dets = decodeBlaze(boxes, scores);
      expect(dets, hasLength(1));
      final v = dets.single.v;
      expect(v[1], closeTo(0.08125, 1e-9)); // xmin
      expect(v[3], closeTo(0.18125, 1e-9)); // xmax
      expect(v[0], closeTo(-0.01875, 1e-9)); // ymin
      expect(v[4], closeTo(0.08125, 1e-9)); // kp0.x
      expect(v[5], closeTo(-0.01875, 1e-9)); // kp0.y
      expect(dets.single.score, closeTo(0.5, 1e-9));
    });
  });

  group('weighted NMS', () {
    BlazeRawDet box(double y0, double x0, double y1, double x1, double s) {
      final v = List.filled(16, 0.0);
      v[0] = y0;
      v[1] = x0;
      v[2] = y1;
      v[3] = x1;
      return BlazeRawDet(v, s);
    }

    test('overlapping boxes blend into one score-weighted mean', () {
      final out = blazeNms([
        box(0.2, 0.2, 0.6, 0.6, 0.9),
        box(0.25, 0.25, 0.6, 0.6, 0.3),
      ]);
      expect(out, hasLength(1));
      // Weighted mean of the two boxes.
      expect(out.single.box[0], closeTo((0.2 * 0.9 + 0.25 * 0.3) / 1.2, 1e-9));
      expect(out.single.score, closeTo(0.6, 1e-9));
      expect(out.single.keypoints, hasLength(6));
    });

    test('distant boxes both survive, best first', () {
      final out = blazeNms([
        box(0.0, 0.0, 0.1, 0.1, 0.6),
        box(0.8, 0.8, 0.9, 0.9, 0.9),
      ]);
      expect(out, hasLength(2));
      expect(out.first.score, 0.9);
    });
  });

  group('similarity alignment', () {
    test('recovers an exact similarity transform', () {
      // Ground truth: scale 2, rotate 30°, translate (5, -3).
      const ang = math.pi / 6;
      final a = 2 * math.cos(ang), b = 2 * math.sin(ang);
      const tx = 5.0, ty = -3.0;
      final src = [
        const Offset(10, 20),
        const Offset(40, 25),
        const Offset(25, 60),
        const Offset(30, 80),
      ];
      final dst = [
        for (final p in src)
          Offset(a * p.dx - b * p.dy + tx, b * p.dx + a * p.dy + ty)
      ];
      final t = similarityTransform(src, dst);
      expect(t[0], closeTo(a, 1e-9));
      expect(t[1], closeTo(b, 1e-9));
      expect(t[2], closeTo(tx, 1e-9));
      expect(t[3], closeTo(ty, 1e-9));
    });

    test('identity keypoints reproduce the source image', () {
      // Square whose keypoints already sit on the template grid: warp must
      // reproduce the source pixels (bilinear exact on integer coords).
      const s = 112;
      final srcImg = img.Image(width: s, height: s);
      for (var y = 0; y < s; y++) {
        for (var x = 0; x < s; x++) {
          srcImg.setPixel(x, y, img.ColorRgb8(x, y, 128));
        }
      }
      final det = FaceDetection(
        box: const [0, 0, 1, 1],
        keypoints: [
          for (final p in alignTemplate) Offset(p.dx / s, p.dy / s),
        ],
        score: 1,
      );
      final out = alignFace(srcImg, det);
      expect(out.width, 112);
      expect(out.height, 112);
      expect(out.getPixel(56, 56).r, 56);
      expect(out.getPixel(10, 90).g, 90);
    });

    test('tilted landmarks warp eyes onto the template grid', () {
      // Regression: the inverse warp once had flipped off-diagonal signs.
      // Invisible for frontal faces (b≈0 — every earlier test), it shifted
      // tilted faces by tens of pixels and destroyed identity separation
      // (measured: genuine 0.21 vs impostor 0.56 broken, 0.80 vs ~0.0
      // fixed). Landmark markers must land on the template grid.
      //
      // Construction: source landmarks = template pushed through a KNOWN
      // similarity (scale 1.8, rotate -12°, translate (30, 40)), so the
      // least-squares fit is exact (zero residuals) with b != 0.
      const s = 240;
      final srcImg = img.Image(width: s, height: s);
      img.fill(srcImg, color: img.ColorRgb8(0, 0, 0));
      const ang = -12 * math.pi / 180;
      const sc = 1.8;
      final A = sc * math.cos(ang), B = sc * math.sin(ang);
      Offset fwd(Offset p) =>
          Offset(A * p.dx - B * p.dy + 30, B * p.dx + A * p.dy + 40);
      final srcPts = [for (final p in alignTemplate) fwd(p)];
      void dot(Offset p, img.Color c) {
        for (var dy = -3; dy <= 3; dy++) {
          for (var dx = -3; dx <= 3; dx++) {
            srcImg.setPixel(p.dx.round() + dx, p.dy.round() + dy, c);
          }
        }
      }

      dot(srcPts[0], img.ColorRgb8(255, 0, 0));
      dot(srcPts[1], img.ColorRgb8(0, 255, 0));
      dot(srcPts[2], img.ColorRgb8(0, 0, 255));
      final det = _det([
        for (final p in srcPts) Offset(p.dx / s, p.dy / s),
        const Offset(0.25, 0.50),
        const Offset(0.78, 0.48),
      ]);
      final out = alignFace(srcImg, det);
      // Template eyes (38.29, 51.69) / (73.53, 51.69): red left, green right.
      final pl = out.getPixel(38, 52);
      expect(pl.r, greaterThan(80));
      expect(pl.g, lessThan(80));
      expect(pl.b, lessThan(80));
      final pr = out.getPixel(74, 52);
      expect(pr.g, greaterThan(80));
      expect(pr.r, lessThan(80));
      expect(pr.b, lessThan(80));
      // Template nose (56.02, 71.74): blue.
      final pn = out.getPixel(56, 72);
      expect(pn.b, greaterThan(80));
      expect(pn.r, lessThan(80));
      expect(pn.g, lessThan(80));
    });

    test('constant image aligns to a constant image', () {      final srcImg = img.Image(width: 200, height: 200);
      img.fill(srcImg, color: img.ColorRgb8(10, 20, 30));
      final det = _det(const [
        Offset(0.42, 0.42),
        Offset(0.58, 0.42),
        Offset(0.50, 0.55),
        Offset(0.50, 0.66),
        Offset(0.34, 0.50),
        Offset(0.66, 0.50),
      ]);
      final out = alignFace(srcImg, det);
      final p = out.getPixel(0, 0);
      expect(p.r, 10);
      expect(p.g, 20);
      expect(p.b, 30);
    });
  });

  group('geometry sanity + sharpness', () {
    test('centered frontal detection is sane', () {
      expect(
          saneGeometry(_det(const [
            Offset(0.42, 0.42),
            Offset(0.58, 0.42),
            Offset(0.50, 0.55),
            Offset(0.50, 0.66),
            Offset(0.34, 0.50),
            Offset(0.66, 0.50),
          ])),
          isTrue);
    });

    test('tilted eyes, inverted order and tiny span are rejected', () {
      // Steep eye slope.
      expect(
          saneGeometry(_det(const [
            Offset(0.42, 0.30),
            Offset(0.58, 0.60),
            Offset(0.50, 0.55),
            Offset(0.50, 0.66),
            Offset(0.34, 0.50),
            Offset(0.66, 0.50),
          ])),
          isFalse);
      // Mouth above eyes.
      expect(
          saneGeometry(_det(const [
            Offset(0.42, 0.60),
            Offset(0.58, 0.60),
            Offset(0.50, 0.55),
            Offset(0.50, 0.30),
            Offset(0.34, 0.50),
            Offset(0.66, 0.50),
          ])),
          isFalse);
      // Collapsed eye distance.
      expect(
          saneGeometry(_det(const [
            Offset(0.50, 0.42),
            Offset(0.51, 0.42),
            Offset(0.50, 0.55),
            Offset(0.50, 0.66),
            Offset(0.34, 0.50),
            Offset(0.66, 0.50),
          ])),
          isFalse);
    });

        test('sharpness separates texture from mush', () {
      expect(estimateSharpness(const [7, 7, 7, 7]), isNull);
      final flat = img.Image(width: 64, height: 64);
      img.fill(flat, color: img.ColorRgb8(128, 128, 128));
      expect(estimateSharpness(img.encodeJpg(flat))!,
          lessThan(kMinSharpness));
      final textured = img.Image(width: 96, height: 96);
      for (var y = 0; y < 96; y++) {
        for (var x = 0; x < 96; x++) {
          final v = 128 + (((x ~/ 4) + (y ~/ 4)) % 2 == 0 ? 18 : -18);
          textured.setPixel(x, y, img.ColorRgb8(v, v, v));
        }
      }
      expect(estimateSharpness(img.encodeJpg(textured))!,
          greaterThan(kMinSharpness));
    });
  });

  group('pose zones (guided enrollment)', () {
    FaceDetection detAt(double noseX, [double noseY = 0.55]) => _det([
          const Offset(0.42, 0.42),
          const Offset(0.58, 0.42),
          Offset(noseX, noseY),
          const Offset(0.50, 0.66),
          const Offset(0.34, 0.50),
          const Offset(0.66, 0.50),
        ]);

    test('yaw proxy measures nose offset in eye widths', () {
      expect(poseYawOf(detAt(0.50)), closeTo(0.0, 1e-9));
      expect(poseYawOf(detAt(0.55)), closeTo(0.3125, 1e-9));
      expect(poseYawOf(detAt(0.45)), closeTo(-0.3125, 1e-9));
    });

    test('pitch proxy measures nose height in the eye-mouth segment', () {
      // Frontal geometry (0.42/0.55/0.66) reads ≈0.54.
      expect(posePitchOf(detAt(0.50, 0.55)), closeTo(0.5417, 0.01));
      // Chin-up pulls the nose toward the eyes; chin-down toward mouth.
      expect(posePitchOf(detAt(0.50, 0.505)), lessThan(kPitchUpMax));
      expect(posePitchOf(detAt(0.50, 0.60)), greaterThan(kPitchDownMin));
    });

    test('zones enforce real turns, never plausible frontals', () {
      expect(poseOkFor(PoseTarget.any, 0.9), isTrue);
      // Front slot: measured frontal spread (±0.12) passes with margin.
      expect(poseOkFor(PoseTarget.front, 0.10), isTrue);
      expect(poseOkFor(PoseTarget.front, 0.19), isFalse);
      // Side slots REQUIRE the turn: frontal and opposite frames are held
      // out (Pointing'04: ±15° reads 0.09–0.25, ±30° reads ±0.40).
      expect(poseOkFor(PoseTarget.left, 0.0), isFalse);
      expect(poseOkFor(PoseTarget.left, -0.20), isFalse);
      expect(poseOkFor(PoseTarget.left, 0.30), isTrue);
      expect(poseOkFor(PoseTarget.left, 0.46), isTrue);
      expect(poseOkFor(PoseTarget.left, 0.71), isFalse);
      expect(poseOkFor(PoseTarget.right, -0.30), isTrue);
      expect(poseOkFor(PoseTarget.right, 0.0), isFalse);
      expect(poseOkFor(PoseTarget.right, -0.71), isFalse);
      // Up/down REQUIRE the tilt: a frontal stare (pitch ≈0.54) can never
      // complete Top/Bottom — staring straight is held out, not counted.
      expect(poseOkFor(PoseTarget.up, 0.0, 0.54), isFalse);
      expect(poseOkFor(PoseTarget.up, 0.0, 0.35), isTrue);
      expect(poseOkFor(PoseTarget.down, 0.0, 0.54), isFalse);
      expect(poseOkFor(PoseTarget.down, 0.0, 0.75), isTrue);
      expect(poseOkFor(PoseTarget.up, 0.0, null), isFalse);
    });

    test('relative pitch gates measure from the holder\'s own frontal', () {
      // A long-faced holder idles at 0.60: absolute gates demand a big
      // down-tilt (0.55 barely moves) and an extreme up-tilt (≤0.53).
      // Relative gates ask both directions for the same small motion.
      expect(poseOkWithRef(PoseTarget.up, 0.0, 0.57, 0.60), isTrue);
      expect(poseOkWithRef(PoseTarget.up, 0.0, 0.59, 0.60), isFalse);
      expect(poseOkWithRef(PoseTarget.down, 0.0, 0.63, 0.60), isTrue);
      expect(poseOkWithRef(PoseTarget.down, 0.0, 0.61, 0.60), isFalse);
      // Jitter inside the margin never counts.
      expect(poseOkWithRef(PoseTarget.up, 0.0, 0.595, 0.60), isFalse);
      // Null reference (resume without a front section) falls back.
      expect(poseOkWithRef(PoseTarget.up, 0.0, 0.35, null), isTrue);
      expect(poseOkWithRef(PoseTarget.up, 0.0, 0.54, null), isFalse);
      expect(poseOkWithRef(PoseTarget.front, 0.10, 0.60, 0.60), isTrue);
      expect(poseGuidanceWithRef(PoseTarget.up, 0.0, 0.57, 0.60), isNull);
      expect(poseGuidanceWithRef(PoseTarget.up, 0.0, 0.59, 0.60),
          contains('A bit more up'));
      expect(poseGuidanceWithRef(PoseTarget.down, 0.0, 0.63, 0.60), isNull);
      expect(poseGuidanceWithRef(PoseTarget.down, 0.0, 0.61, 0.60),
          contains('A bit more down'));
    });

    test('guidance arrows match mirrored-preview motion', () {
      expect(poseGuidanceFor(PoseTarget.any, 0.5), isNull);
      expect(poseGuidanceFor(PoseTarget.front, 0.05), isNull);
      expect(
          poseGuidanceFor(PoseTarget.front, 0.25), contains('straight on'));
      expect(poseGuidanceFor(PoseTarget.left, 0.30), isNull);
      expect(poseGuidanceFor(PoseTarget.left, 0.0), contains('←'));
      expect(poseGuidanceFor(PoseTarget.left, -0.20), contains('Other way'));
      expect(poseGuidanceFor(PoseTarget.left, 0.80), contains('Too far'));
      expect(poseGuidanceFor(PoseTarget.right, -0.30), isNull);
      expect(poseGuidanceFor(PoseTarget.right, 0.0), contains('→'));
      // Up/down share the same live line: frontal frames nudge, tilted
      // frames clear, and every arrow duplicates its word.
      expect(poseGuidanceFor(PoseTarget.up, 0.0, 0.35), isNull);
      expect(poseGuidanceFor(PoseTarget.up, 0.0, 0.54), contains('↑'));
      expect(poseGuidanceFor(PoseTarget.down, 0.0, 0.75), isNull);
      expect(poseGuidanceFor(PoseTarget.down, 0.0, 0.54), contains('↓'));
    });
  });
}
