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
