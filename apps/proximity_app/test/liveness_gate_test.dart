// sec-liveness (2B): LivenessGate contract tests — passive interface,
// enroll shuffle, fail-closed native gate, scripted fake.
//
// Offline, no native channels: the native gate is exercised only on its
// fail-closed paths (missing/empty/garbage stills throw before any
// decode/model load); model pre/post-processing is covered via the pure
// [minifasnetInputFromRgba]/[liveScoreFromProbs] helpers. The vendored
// weights file itself is pinned by presence + size (never loaded here —
// the TFLite native lib only exists on device builds).
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';

void main() {
  group('liveness pipeline tag', () {
    test('kLivenessVer names the real model + weights hash', () {
      expect(kLivenessVer.startsWith('liveness/'), isTrue);
      expect(kLivenessVer, contains('minifasnet-v2'));
      // model scale + input size + weights hash8 (mirrors the
      // face_verification/<pkgVer>+<assetHash8> shape).
      expect(kLivenessVer, contains('27-80x80'));
      expect(kLivenessVer, matches(RegExp(r'\+[0-9a-f]{8}$')));
      // No heuristic tag anywhere: the false pipeline name is gone.
      expect(kLivenessVer, isNot(contains('heuristic')));
    });

    test('vendored weights exist at the declared asset path', () {
      final f = File(kLivenessModelAsset);
      expect(f.existsSync(), isTrue,
          reason: '$kLivenessModelAsset must ship (tag pins its hash)');
      // MiniFASNetV2-27 TFLite is ~1.85MB; a stub/empty file fails here.
      expect(f.lengthSync(), greaterThan(1000000));
    });
  });

  group('enroll active challenges (shuffled blink+smile)', () {
    test('shuffle is a permutation of blink+smile', () {
      for (var seed = 0; seed < 20; seed++) {
        final got = shuffledActiveChallenges(rng: Random(seed));
        expect(got, hasLength(2));
        expect(got.toSet(),
            {LivenessAction.blink, LivenessAction.smile});
      }
    });

    test('same seed shuffles deterministically', () {
      expect(shuffledActiveChallenges(rng: Random(7)),
          shuffledActiveChallenges(rng: Random(7)));
    });

    test('shuffle varies order across seeds (anti-replay property)', () {
      final orders = <String>{
        for (var seed = 0; seed < 20; seed++)
          shuffledActiveChallenges(rng: Random(seed)).join(','),
      };
      // 2! = 2 possible orders; a real shuffle hits both over 20 seeds.
      expect(orders, hasLength(2));
    });
  });

  group('liveScoreFromProbs (pure post-processing)', () {
    test('score IS the LIVE class probability (index 1)', () {
      expect(liveScoreFromProbs([0.05, 0.90, 0.05]),
          moreOrLessEquals(0.90));
      expect(liveScoreFromProbs([0.5, 0.0, 0.5]), 0.0);
      expect(liveScoreFromProbs([0.0, 1.0, 0.0]), 1.0);
    });

    test('spoof-dominant outputs score low (spoof still fails)', () {
      // Print attack.
      expect(liveScoreFromProbs([0.93, 0.04, 0.03]), lessThan(0.5));
      // Replay attack.
      expect(liveScoreFromProbs([0.03, 0.04, 0.93]), lessThan(0.5));
    });

    test('wrong shape or non-finite input throws (fail-closed)', () {
      expect(() => liveScoreFromProbs([0.5, 0.5]), throwsArgumentError);
      expect(
          () => liveScoreFromProbs([0.3, 0.3, 0.3, 0.1]),
          throwsArgumentError);
      expect(() => liveScoreFromProbs([0.5, double.nan, 0.5]),
          throwsArgumentError);
      expect(() => liveScoreFromProbs([0.5, double.infinity, 0.0]),
          throwsArgumentError);
    });
  });

  group('minifasnetInputFromRgba (pure pre-processing)', () {
    test('packs NCHW BGR /255 with the [1,3,80,80] model shape', () {
      // 4x2 frame: R=255,G=128,B=64,A=255 everywhere.
      final rgba = Uint8List(4 * 2 * 4);
      for (var i = 0; i < 4 * 2; i++) {
        rgba[i * 4] = 255; // R
        rgba[i * 4 + 1] = 128; // G
        rgba[i * 4 + 2] = 64; // B
        rgba[i * 4 + 3] = 255; // A
      }
      final input =
          minifasnetInputFromRgba(rgba: rgba, width: 4, height: 2);
      expect(input.length, 1);
      expect(input[0].length, 3);
      expect(input[0][0].length, kLivenessInputSize);
      expect(input[0][0][0].length, kLivenessInputSize);
      // BGR order, /255.
      expect(input[0][0][0][0], moreOrLessEquals(64 / 255));
      expect(input[0][1][0][0], moreOrLessEquals(128 / 255));
      expect(input[0][2][0][0], moreOrLessEquals(1.0));
    });

    test('centre-square crop drops the side margins of wide frames', () {
      // 4x2 frame: left 2 cols red, right 2 cols blue.
      final rgba = Uint8List(4 * 2 * 4);
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 4; x++) {
          final o = (y * 4 + x) * 4;
          final left = x < 2;
          rgba[o] = left ? 255 : 0; // R
          rgba[o + 1] = 0; // G
          rgba[o + 2] = left ? 0 : 255; // B
          rgba[o + 3] = 255; // A
        }
      }
      final input =
          minifasnetInputFromRgba(rgba: rgba, width: 4, height: 2);
      // Centre 2x2 square straddles the seam: left half of the crop is
      // red (B channel 0), right half is blue (B channel 1).
      final b00 = input[0][0][0][0];
      final bLast = input[0][0][0][kLivenessInputSize - 1];
      expect(b00, moreOrLessEquals(0.0));
      expect(bLast, moreOrLessEquals(1.0));
    });

    test('size mismatch throws (fail-closed)', () {
      expect(
          () => minifasnetInputFromRgba(
              rgba: Uint8List(10), width: 4, height: 2),
          throwsArgumentError);
      expect(
          () => minifasnetInputFromRgba(
              rgba: Uint8List(0), width: 0, height: 0),
          throwsArgumentError);
    });

    test('faceBox crops the face region (not the centre)', () {
      // 20x20 frame: left 10 cols red, right 10 cols blue.
      const w = 20, h = 20;
      final rgba = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final o = (y * w + x) * 4;
          final left = x < 10;
          rgba[o] = left ? 255 : 0; // R
          rgba[o + 1] = 0; // G
          rgba[o + 2] = left ? 0 : 255; // B
          rgba[o + 3] = 255; // A
        }
      }
      // Face box on the blue right side (8x8 square).
      final input = minifasnetInputFromRgba(
        rgba: rgba,
        width: w,
        height: h,
        faceBox: (left: 12, top: 6, right: 20, bottom: 14),
      );
      // Entire 80x80 crop is blue (B channel 1.0 everywhere).
      expect(input[0][0][0][0], moreOrLessEquals(1.0));
      expect(input[0][0][kLivenessInputSize - 1][kLivenessInputSize - 1],
          moreOrLessEquals(1.0));
    });

    test('invalid faceBox falls back to centre-square (same scorer)', () {
      // 4x2 frame: left red, right blue (same fixture as the centre test).
      final rgba = Uint8List(4 * 2 * 4);
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 4; x++) {
          final o = (y * 4 + x) * 4;
          final left = x < 2;
          rgba[o] = left ? 255 : 0; // R
          rgba[o + 1] = 0; // G
          rgba[o + 2] = left ? 0 : 255; // B
          rgba[o + 3] = 255; // A
        }
      }
      final centre =
          minifasnetInputFromRgba(rgba: rgba, width: 4, height: 2);
      // Empty box → squared helper returns null → centre fallback, bit-equal.
      final fallback = minifasnetInputFromRgba(
        rgba: rgba,
        width: 4,
        height: 2,
        faceBox: (left: 0, top: 0, right: 0, bottom: 0),
      );
      expect(fallback[0][0][0][0], centre[0][0][0][0]);
      expect(fallback[0][0][0][kLivenessInputSize - 1],
          centre[0][0][0][kLivenessInputSize - 1]);
    });
  });

  group('squareCropFromFaceBox (pure face-box)', () {
    test('squares around the centre and clamps to the frame', () {
      // Wide box in a 100x80 frame → 60px square centred on the box.
      final c = squareCropFromFaceBox(
        frameWidth: 100,
        frameHeight: 80,
        faceLeft: 10,
        faceTop: 10,
        faceRight: 70,
        faceBottom: 40,
      );
      expect(c, isNotNull);
      expect(c!.edge, 60);
      // Centre of (10..70, 10..40) is (40, 25); 60-square from (10, -5)
      // clamps top to 0.
      expect(c.left, 10);
      expect(c.top, 0);
    });

    test('invalid boxes return null (caller falls back)', () {
      expect(
          squareCropFromFaceBox(
              frameWidth: 100,
              frameHeight: 100,
              faceLeft: 0,
              faceTop: 0,
              faceRight: 0,
              faceBottom: 0),
          isNull);
      expect(
          squareCropFromFaceBox(
              frameWidth: 100,
              frameHeight: 100,
              faceLeft: 50,
              faceTop: 50,
              faceRight: 10,
              faceBottom: 10),
          isNull);
      // <8px detail is detection noise → fallback.
      expect(
          squareCropFromFaceBox(
              frameWidth: 100,
              frameHeight: 100,
              faceLeft: 10,
              faceTop: 10,
              faceRight: 15,
              faceBottom: 15),
          isNull);
      // Box larger than the frame on a non-square sensor → cannot fit a
      // square → fallback (square frames clamp to the whole frame, which
      // equals the centre crop, so the null path needs a wide frame).
      expect(
          squareCropFromFaceBox(
              frameWidth: 20,
              frameHeight: 10,
              faceLeft: -100,
              faceTop: -100,
              faceRight: 200,
              faceBottom: 200),
          isNull);
    });
  });

  group('expandedSquareCropFromFaceBox (2.7x training crop)', () {
    test('scale 1.0 matches the legacy tight square', () {
      final tight = squareCropFromFaceBox(
        frameWidth: 100,
        frameHeight: 80,
        faceLeft: 10,
        faceTop: 10,
        faceRight: 70,
        faceBottom: 40,
      );
      final expanded = expandedSquareCropFromFaceBox(
        frameWidth: 100,
        frameHeight: 80,
        faceLeft: 10,
        faceTop: 10,
        faceRight: 70,
        faceBottom: 40,
        contextScale: 1.0,
      );
      expect(expanded, isNotNull);
      expect(expanded!.edge, tight!.edge);
      expect(expanded.left, tight.left);
      expect(expanded.top, tight.top);
    });

    test('2.7x expands around the centre (training distribution)', () {
      // 20px box in a 200x200 frame → 54px square centred on the box.
      final c = expandedSquareCropFromFaceBox(
        frameWidth: 200,
        frameHeight: 200,
        faceLeft: 90,
        faceTop: 90,
        faceRight: 110,
        faceBottom: 110,
        contextScale: kLivenessContextScale,
      );
      expect(c, isNotNull);
      expect(c!.edge, 54);
      // Centre (100, 100) → square from (73, 73).
      expect(c.left, 73);
      expect(c.top, 73);
    });

    test('overflow fits the largest centred square (same scorer)', () {
      // 8px box with 2.7x context in a 20x20 frame → 21px request, 20px
      // fit (whole frame, never null for a usable box).
      final c = expandedSquareCropFromFaceBox(
        frameWidth: 20,
        frameHeight: 20,
        faceLeft: 6,
        faceTop: 6,
        faceRight: 14,
        faceBottom: 14,
        contextScale: kLivenessContextScale,
      );
      expect(c, isNotNull);
      expect(c!.edge, 20);
      expect(c.left, 0);
      expect(c.top, 0);
    });

    test('unusable boxes still return null (caller falls back)', () {
      expect(
          expandedSquareCropFromFaceBox(
              frameWidth: 100,
              frameHeight: 100,
              faceLeft: 0,
              faceTop: 0,
              faceRight: 0,
              faceBottom: 0,
              contextScale: kLivenessContextScale),
          isNull);
      expect(
          expandedSquareCropFromFaceBox(
              frameWidth: 0,
              frameHeight: 0,
              faceLeft: 10,
              faceTop: 10,
              faceRight: 50,
              faceBottom: 50,
              contextScale: kLivenessContextScale),
          isNull);
    });

    test('production packer accepts the 2.7x scale (shape [1,3,80,80])', () {
      final rgba = Uint8List(20 * 20 * 4);
      for (var i = 0; i < 20 * 20; i++) {
        rgba[i * 4] = 200;
        rgba[i * 4 + 1] = 150;
        rgba[i * 4 + 2] = 100;
        rgba[i * 4 + 3] = 255;
      }
      final input = minifasnetInputFromRgba(
        rgba: rgba,
        width: 20,
        height: 20,
        faceBox: (left: 6, top: 6, right: 14, bottom: 14),
        contextScale: kLivenessContextScale,
      );
      expect(input.length, 1);
      expect(input[0].length, 3);
      expect(input[0][0].length, kLivenessInputSize);
      expect(input[0][0][0].length, kLivenessInputSize);
    });
  });

  group('mapFaceBoxToFrame (pure box mapping)', () {
    test('scales original pixels onto the decoded frame', () {
      // 640x480 original → 160x120 decoded (0.25x each axis).
      final m = mapFaceBoxToFrame(
        origLeft: 100,
        origTop: 100,
        origRight: 300,
        origBottom: 300,
        origWidth: 640,
        origHeight: 480,
        frameWidth: 160,
        frameHeight: 120,
      );
      expect(m, isNotNull);
      expect(m!.left, 25);
      expect(m.top, 25);
      expect(m.right, 75);
      expect(m.bottom, 75);
    });

    test('invalid geometry returns null (caller falls back)', () {
      expect(
          mapFaceBoxToFrame(
              origLeft: 10,
              origTop: 10,
              origRight: 5,
              origBottom: 5,
              origWidth: 100,
              origHeight: 100,
              frameWidth: 40,
              frameHeight: 40),
          isNull);
      expect(
          mapFaceBoxToFrame(
              origLeft: 0,
              origTop: 0,
              origRight: 10,
              origBottom: 10,
              origWidth: 0,
              origHeight: 100,
              frameWidth: 40,
              frameHeight: 40),
          isNull);
    });
  });

  group('originalDimsFromBytes (pure header parser)', () {
    test('parses PNG IHDR without a full decode', () {
      // Minimal PNG: sig + len(13) + 'IHDR' + 640x480 + padding to 32B.
      final bytes = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x02, 0x80, // 640
        0x00, 0x00, 0x01, 0xE0, // 480
        0x08, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ]);
      final dims = originalDimsFromBytes(bytes);
      expect(dims, isNotNull);
      expect(dims!.width, 640);
      expect(dims.height, 480);
    });

    test('parses JPEG SOF0 without a full decode', () {
      // Minimal JPEG: SOI + APP0 + SOF0 (320x240, 1 component) + pad.
      final bytes = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10,
        0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
        0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0xFF, 0xC0, 0x00, 0x0B, 0x08,
        0x00, 0xF0, // height 240
        0x01, 0x40, // width 320
        0x01, 0x01, 0x11, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ]);
      final dims = originalDimsFromBytes(bytes);
      expect(dims, isNotNull);
      expect(dims!.width, 320);
      expect(dims.height, 240);
    });

    test('garbage returns null (caller falls back)', () {
      expect(originalDimsFromBytes(Uint8List.fromList(List.filled(64, 0x41))),
          isNull);
      expect(originalDimsFromBytes(Uint8List(0)), isNull);
    });
  });

  group('FakeLivenessGate (test double)', () {
    test('scripted score/ver round-trip + calls recorded', () async {
      final g = FakeLivenessGate();
      final r = await g.detectPassive('still.jpg');
      expect(r.score, 0.92);
      expect(r.ver, kLivenessVer);
      expect(g.calls, ['still.jpg']);
    });

    test('throwOnDetect fails closed (spoof/unreadable path)', () async {
      final g = FakeLivenessGate(throwOnDetect: true);
      expect(() => g.detectPassive('still.jpg'), throwsStateError);
    });
  });

  group('HeuristicLivenessGate fail-closed (native)', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('missing still throws (never a pass)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const g = HeuristicLivenessGate();
      expect(
          () => g.detectPassive('/nonexistent-prox-still.jpg'),
          throwsStateError);
    });

    test('empty path throws before any decode', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const g = HeuristicLivenessGate();
      expect(() => g.detectPassive('   '), throwsStateError);
    });

    test('non-image bytes throw (magic gate)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final f = File(
          '${Directory.systemTemp.path}/prox-liveness-garbage-${DateTime.now().microsecondsSinceEpoch}.bin');
      // >4KB so the size gate passes and the magic gate is the decider.
      await f.writeAsBytes(List<int>.filled(8192, 0x41));
      try {
        const g = HeuristicLivenessGate();
        await expectLater(
            () => g.detectPassive(f.path), throwsStateError);
      } finally {
        if (await f.exists()) await f.delete();
      }
    });

    test('records-only devices refuse before the filesystem', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      const g = HeuristicLivenessGate();
      expect(() => g.detectPassive('/any.jpg'), throwsStateError);
    });

    test('concurrent passes serialize and fail closed (no hang)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // The interpreter is single-flight: overlapping passes (rapid rescan
      // taps) must queue behind the turnstile, never share one invoke.
      // All three stills are unreadable, so every pass must throw
      // StateError promptly — never a pass, never a hung Future.
      const g = HeuristicLivenessGate();
      final results = await Future.wait([
        g.detectPassive('/nonexistent-prox-still-a.jpg')
            .then((_) => 'pass', onError: (_) => 'throw'),
        g.detectPassive('/nonexistent-prox-still-b.jpg')
            .then((_) => 'pass', onError: (_) => 'throw'),
        g.detectPassive('   ').then((_) => 'pass', onError: (_) => 'throw'),
      ]).timeout(const Duration(seconds: 30));
      expect(results, everyElement('throw'));
    });
  });

  group('EnrollLivenessPlan (per-session active walk)', () {
    test('fresh plan is a permutation of blink+smile, starting unacked',
        () {
      for (var seed = 0; seed < 20; seed++) {
        final plan = EnrollLivenessPlan.fresh(rng: Random(seed));
        expect(plan.order, hasLength(2));
        expect(plan.order.toSet(),
            {LivenessAction.blink, LivenessAction.smile});
        expect(plan.current, plan.order.first);
        expect(plan.acknowledged, 0);
        expect(plan.isComplete, isFalse);
      }
    });

    test('acknowledgeFill walks the shuffled order, then no-ops', () {
      final plan = EnrollLivenessPlan.fresh(rng: Random(3));
      final first = plan.current!;
      plan.acknowledgeFill();
      expect(plan.acknowledged, 1);
      expect(plan.isComplete, isFalse);
      // Advanced to the OTHER challenge (a 2-walk has no repeats).
      expect(plan.current, isNot(first));
      plan.acknowledgeFill();
      expect(plan.acknowledged, 2);
      expect(plan.isComplete, isTrue);
      expect(plan.current, isNull);
      // Extra fills never over-advance (no wraparound, no third state).
      plan.acknowledgeFill();
      expect(plan.acknowledged, 2);
      expect(plan.isComplete, isTrue);
      expect(plan.current, isNull);
    });

    test('order varies across sessions (anti-replay property)', () {
      final orders = <String>{
        for (var seed = 0; seed < 20; seed++)
          EnrollLivenessPlan.fresh(rng: Random(seed)).order.join(','),
      };
      // 2! = 2 possible orders; a real shuffle hits both over 20 seeds.
      expect(orders, hasLength(2));
    });
  });

  group('DI seam', () {
    test('livenessGateProvider throws without override', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(() => container.read(livenessGateProvider),
          throwsUnimplementedError);
    });

    test('override resolves (FakeLivenessGate)', () async {
      final container = ProviderContainer(overrides: [
        livenessGateProvider.overrideWithValue(FakeLivenessGate(score: 0.5)),
      ]);
      addTearDown(container.dispose);
      final r =
          await container.read(livenessGateProvider).detectPassive('x');
      expect(r.score, 0.5);
    });
  });
}
