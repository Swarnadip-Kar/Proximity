// sec-liveness (2B): LivenessGate contract tests — passive interface,
// enroll shuffle, fail-closed native gate, scripted fake.
//
// Offline, no native channels: the native gate is exercised only on its
// fail-closed paths (missing/empty/garbage stills throw before any
// decode); scoring math is covered via the pure [combineLivenessFeatures].
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';

void main() {
  group('liveness pipeline tag', () {
    test('kLivenessVer carries the liveness/ allowlist prefix', () {
      expect(kLivenessVer.startsWith('liveness/'), isTrue);
      expect(kLivenessVer, contains('minifasnet-v2-se'));
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

  group('combineLivenessFeatures (pure scorer core)', () {
    test('all-zero features score 0, all-one score 1', () {
      expect(
          combineLivenessFeatures(
              sharpness: 0, chroma: 0, specular: 0),
          0.0);
      expect(
          combineLivenessFeatures(
              sharpness: 1, chroma: 1, specular: 1),
          moreOrLessEquals(1.0));
    });

    test('weights favour sharpness, then chroma, then specular', () {
      final s = combineLivenessFeatures(
          sharpness: 1, chroma: 0, specular: 0);
      final c = combineLivenessFeatures(
          sharpness: 0, chroma: 1, specular: 0);
      final p = combineLivenessFeatures(
          sharpness: 0, chroma: 0, specular: 1);
      expect(s, moreOrLessEquals(0.45));
      expect(c, moreOrLessEquals(0.35));
      expect(p, moreOrLessEquals(0.20));
      expect(s, greaterThan(c));
      expect(c, greaterThan(p));
    });

    test('out-of-range features clamp (never NaN, never >1)', () {
      expect(
          combineLivenessFeatures(
              sharpness: 9, chroma: -3, specular: double.nan),
          inInclusiveRange(0.0, 1.0));
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
