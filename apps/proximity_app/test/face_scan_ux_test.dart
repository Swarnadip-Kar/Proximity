import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:proximity_app/core/ble_radio.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/face_camera.dart';
import 'package:proximity_app/core/face_detect.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/main.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/screens/face_capture.dart';
import 'package:proximity_app/widgets/animated.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_face/face.dart';

Uint8List _greyJpeg(int v, {int size = 96}) {
  final frame = img.Image(width: size, height: size);
  img.fill(frame, color: img.ColorRgb8(v, v, v));
  return Uint8List.fromList(img.encodeJpg(frame));
}

/// Driver with an open window (fast path to face check) that always reports
/// a confident mismatch → consumes attempts, needs-review path.
class _FailFaceDriver extends FakeStudentDriver {
  _FailFaceDriver() : super(windowOpenProbe: true);
  @override
  Future<FaceCheckResult> checkFace(Uint8List frameBytes) async =>
      const FaceCheckResult(FaceMatch.mismatch, 0.1);
}

/// Detector reporting a far-turned face (yaw +0.81): good quality but
/// past the side max — exercises the hold-out + arrow path.
class _TurnedDetector implements FaceDetector {
  @override
  bool get isLoaded => true;
  @override
  Future<void> load() async {}
  @override
  void close() {}
  @override
  Future<List<FaceDetection>> detect(Uint8List jpegBytes) async => const [
        FaceDetection(
          box: [0.3, 0.3, 0.7, 0.7],
          keypoints: [
            Offset(0.42, 0.42),
            Offset(0.58, 0.42),
            Offset(0.63, 0.55),
            Offset(0.50, 0.66),
            Offset(0.34, 0.50),
            Offset(0.66, 0.50),
          ],
          score: 0.95,
        ),
      ];
}

/// Scripted live verifier: passes from the [passOn]-th check (1-based),
/// mismatches before that; [passOn] < 0 never passes.
class _ScriptVerifier {
  int calls = 0;
  final int passOn;
  _ScriptVerifier({required this.passOn});
  Future<FaceCheckResult> call(Uint8List bytes) async {
    calls++;
    if (passOn >= 0 && calls >= passOn) {
      return const FaceCheckResult(FaceMatch.pass, 0.9);
    }
    return const FaceCheckResult(FaceMatch.mismatch, 0.2);
  }
}

Future<void> _enterIp(WidgetTester t, String ip) async {
  await t.enterText(find.byKey(const ValueKey('ipfield')), ip);
  await t.pump();
}

/// Embedder whose frames never agree (seeded 32-dim random unit vectors:
/// pairwise cosines concentrate near 0, never near the 0.70 pair bar) —
/// exercises the stayOpen fruitless-round path without any pass.
class _AltEmbedder implements FaceEmbedder {
  final _rnd = math.Random(7);
  @override
  Future<List<double>> embed(List<int> frameBytes) async {
    final v = List.generate(32, (_) => _rnd.nextDouble() * 2 - 1);
    final n = math.sqrt(v.fold(0.0, (a, b) => a + b * b));
    return [for (final x in v) x / n];
  }

  @override
  Future<bool> checkLiveness(List<int> frameBytes, String prompt) async =>
      true;
}

/// One full auto-scan round: the scan starts by itself (Samsung-style),
/// mismatches, and lands back on needs-review.
/// NOTE: bounded 1s pumps waiting for the expected landing — never a bare
/// settle: the scan loop idles on 350ms gaps with no scheduled frame,
/// which settle() alone exits early, and push/pop transitions need frames.
/// 30 rounds cover a full 30-frame verify session.
Future<void> _waitFor(WidgetTester t, Finder f) async {
  for (var i = 0; i < 30; i++) {
    await t.pump(const Duration(seconds: 1));
    if (f.evaluate().isNotEmpty) return;
  }
}

ProviderScope _scanScope({bool failFace = false}) {
  return ProviderScope(
    overrides: [
      deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
      cloudSyncProvider.overrideWithValue(FakeCloudSync()),
      appModeProvider.overrideWith((ref) => AppMode.student),
      faceCameraProvider.overrideWithValue(FakeFaceCamera()),
      faceDetectorProvider.overrideWithValue(FakeFaceDetector()),
      studentDriverProvider.overrideWithValue(
          failFace ? _FailFaceDriver() : FakeStudentDriver()),
      bleEngineProvider
          .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
      cameraPermissionProvider.overrideWithValue(() async => true),
      blePermissionProvider.overrideWithValue(() async => true),
      btPowerProvider.overrideWithValue(() async => BtState.on),
      linkedIdentityProvider.overrideWith((ref) => const LinkedIdentity(
          name: 'Test User',
          gmail: 'student@example.com',
          roll: '12342210')),
    ],
    child: const ProximityApp(),
  );
}

void main() {
  group('lighting gate (estimateBrightness)', () {
    test('mid-grey still reads ~128', () {
      expect(estimateBrightness(_greyJpeg(128)), closeTo(128, 6));
    });
    test('dark still reads low, bright still reads high', () {
      expect(estimateBrightness(_greyJpeg(10))!, lessThan(kDarkFrameLuma));
      expect(
          estimateBrightness(_greyJpeg(250))!, greaterThan(kBrightFrameLuma));
    });
    test('garbage bytes return null (fail-closed upstream)', () {
      expect(estimateBrightness(const [7, 7, 7, 7]), isNull);
    });
  });

  group('frame analysis (pure functions)', () {
    test('analyzeFrame classifies detection + luminance', () {
      expect(analyzeFrame(faces: 0, luma: 128), FrameQuality.noFace);
      expect(analyzeFrame(faces: 1, luma: null), FrameQuality.unclear);
      expect(analyzeFrame(faces: 1, luma: 10), FrameQuality.tooDark);
      expect(analyzeFrame(faces: 1, luma: 250), FrameQuality.tooBright);
      expect(analyzeFrame(faces: 1, luma: 128), FrameQuality.good);
      expect(analyzeFrame(faces: 2, luma: 128), FrameQuality.good);
    });

    test('analyzeFrame rejects motion mush when sharpness is known', () {
      expect(analyzeFrame(faces: 1, luma: 128, sharpness: 5),
          FrameQuality.tooBlurry);
      expect(analyzeFrame(faces: 1, luma: 128, sharpness: 500),
          FrameQuality.good);
      // Unassessed sharpness (null) never rejects on its own.
      expect(analyzeFrame(faces: 1, luma: 128), FrameQuality.good);
    });

    test('every verdict has user guidance copy', () {
      for (final q in FrameQuality.values) {
        expect(frameGuidance(q).isNotEmpty, isTrue);
      }
    });
  });
  group('scan widgets', () {
    testWidgets('FaceOval renders prompt', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              FaceOval(progress: 0.5, prompt: 'Position your face'),
            ],
          ),
        ),
      ));
      expect(find.text('Position your face'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('pose target steers arrows and holds out garbage',
        (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: [
          faceCameraProvider.overrideWithValue(FakeFaceCamera()),
          faceDetectorProvider.overrideWithValue(_TurnedDetector()),
          cameraPermissionProvider.overrideWithValue(() async => true),
        ],
        child: const MaterialApp(
            home: FaceCaptureScreen(
                sectionTargets: [PoseTarget.left], maxFrames: 5)),
      ));
      await t.pump();
      await t.pump(const Duration(seconds: 3));
      // Turned past the side max: ease-back arrow, never counted.
      expect(find.textContaining('Too far'), findsOneWidget);
      expect(find.text('Face scan'), findsWidgets);
      // Held out the whole run: explicit retry offer, never a pass.
      await t.pump(const Duration(seconds: 8));
      await t.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('live scan auto-captures and pops without any tap',
        (t) async {
      List<Uint8List>? result;
      await t.pumpWidget(ProviderScope(
        overrides: [
          faceCameraProvider.overrideWithValue(FakeFaceCamera()),
          faceDetectorProvider.overrideWithValue(FakeFaceDetector()),
          cameraPermissionProvider.overrideWithValue(() async => true),
        ],
        child: MaterialApp(
            home: Builder(builder: (ctx) {
          return ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(ctx).push<List<Uint8List>>(
                MaterialPageRoute(builder: (_) => const FaceCaptureScreen()),
              );
            },
            child: const Text('go'),
          );
        })),
      ));
      await t.tap(find.text('go'));
      // Explicit time pump: the auto-scan loop idles between stills.
      await t.pump();
      await t.pump(const Duration(seconds: 5));
      // Fake mid-grey stills pass detection + lighting → streak of 2 →
      // auto-pop with zero confirmation taps.
      expect(result, hasLength(1));
      expect(result!.first.isNotEmpty, isTrue);
      expect(
          estimateBrightness(result!.first), closeTo(128, 6));
      expect(t.takeException(), isNull);
    });

    testWidgets('scoring mode completes a section on a live 0.70+ pair',
        (t) async {
      List<Uint8List>? result;
      await t.pumpWidget(ProviderScope(
        overrides: [
          faceCameraProvider.overrideWithValue(FakeFaceCamera()),
          faceDetectorProvider.overrideWithValue(FakeFaceDetector()),
          cameraPermissionProvider.overrideWithValue(() async => true),
        ],
        child: MaterialApp(
            home: Builder(builder: (ctx) {
          return ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(ctx).push<List<Uint8List>>(
                MaterialPageRoute(
                    builder: (_) => FaceCaptureScreen(
                          sectionTargets: const [PoseTarget.front],
                          sectionTitles: const ['Front — look straight'],
                          scorer: MockFaceEmbedder(
                            enrolled: const [1, 0, 0, 0],
                            probe: const [1, 0, 0, 0],
                          ),
                        )),
              );
            },
            child: const Text('go'),
          );
        })),
      ));
      await t.tap(find.text('go'));
      await t.pump();
      // Frontal fake frames land every 3rd call (detector cycles poses):
      // two scoring frames ≈ 6 stills.
      await t.pump(const Duration(seconds: 8));
      // Identical mock embeddings pair at 1.0: section completes with
      // exactly its best pair, live score shown on the way.
      expect(result, hasLength(2));
      expect(t.takeException(), isNull);
    });

    testWidgets('resume starts at the first incomplete section', (t) async {
      List<Uint8List>? result;
      await t.pumpWidget(ProviderScope(
        overrides: [
          faceCameraProvider.overrideWithValue(FakeFaceCamera()),
          faceDetectorProvider.overrideWithValue(FakeFaceDetector()),
          cameraPermissionProvider.overrideWithValue(() async => true),
        ],
        child: MaterialApp(
            home: Builder(builder: (ctx) {
          return ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(ctx).push<List<Uint8List>>(
                MaterialPageRoute(
                    builder: (_) => FaceCaptureScreen(
                          sectionTargets: const [
                            PoseTarget.front,
                            PoseTarget.left,
                            PoseTarget.right,
                          ],
                          sectionTitles: const [
                            'Front',
                            'Left',
                            'Right',
                          ],
                          scorer: MockFaceEmbedder(
                            enrolled: const [1, 0, 0, 0],
                            probe: const [1, 0, 0, 0],
                          ),
                          startSection: 2,
                        )),
              );
            },
            child: const Text('go'),
          );
        })),
      ));
      await t.tap(find.text('go'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      // Opens directly on the remaining angle — no ghost sections, no
      // re-capture of completed ones.
      expect(find.textContaining('Right'), findsOneWidget);
      // Right needs two turned frames (1-in-5 cycle): allow the loop time.
      await t.pump(const Duration(seconds: 12));
      expect(result, hasLength(2));
      expect(t.takeException(), isNull);
    });

    testWidgets('stayOpen keeps the camera across fruitless rounds',
        (t) async {
      var popped = false;
      await t.pumpWidget(ProviderScope(
        overrides: [
          faceCameraProvider.overrideWithValue(FakeFaceCamera()),
          faceDetectorProvider.overrideWithValue(FakeFaceDetector()),
          cameraPermissionProvider.overrideWithValue(() async => true),
        ],
        child: MaterialApp(
            home: Builder(builder: (ctx) {
          return ElevatedButton(
            onPressed: () async {
              await Navigator.of(ctx).push<List<Uint8List>>(
                MaterialPageRoute(
                    builder: (_) => FaceCaptureScreen(
                          sectionTargets: const [PoseTarget.front],
                          maxFrames: 6,
                          stayOpen: true,
                          scorer: _AltEmbedder(),
                        )),
              );
              popped = true;
            },
            child: const Text('go'),
          );
        })),
      ));
      await t.tap(find.text('go'));
      await t.pump();
      // Random 32-dim embeddings never pair ≥0.70: past maxFrames a plain
      // screen pops partial (timeout offer); stayOpen starts a new round
      // instead — still scanning, Cancel offered, nothing popped.
      // (One round ≈ 6 × 700 ms gaps; the 3-fruitless bound trips ≈17 s+.)
      await t.pump(const Duration(seconds: 12));
      expect(popped, isFalse);
      expect(find.text('Try again'), findsNothing);
      expect(find.text('Cancel'), findsOneWidget);
      // …but a hopeless section still surfaces the timeout offer after
      // 3 consecutive fruitless rounds — no infinite camera trap.
      await t.pump(const Duration(seconds: 120));
      expect(find.text('Try again'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('multi-capture collects N stills for enrollment', (t) async {
      List<Uint8List>? result;
      await t.pumpWidget(ProviderScope(
        overrides: [
          faceCameraProvider.overrideWithValue(FakeFaceCamera()),
          faceDetectorProvider.overrideWithValue(FakeFaceDetector()),
          cameraPermissionProvider.overrideWithValue(() async => true),
        ],
        child: MaterialApp(
            home: Builder(builder: (ctx) {
          return ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(ctx).push<List<Uint8List>>(
                MaterialPageRoute(
                    builder: (_) =>
                        const FaceCaptureScreen(captures: 3)),
              );
            },
            child: const Text('go'),
          );
        })),
      ));
      await t.tap(find.text('go'));
      await t.pump();
      await t.pump(const Duration(seconds: 10));
      expect(result, hasLength(3));
      expect(t.takeException(), isNull);
    });
  });

  group('verify session (marking: live checks, one burned attempt)', () {
    List<Uint8List>? result;

    Future<void> pushVerify(
        WidgetTester t, _ScriptVerifier verifier, int maxFrames) async {
      await t.pumpWidget(ProviderScope(
        overrides: [
          faceCameraProvider.overrideWithValue(FakeFaceCamera()),
          faceDetectorProvider.overrideWithValue(FakeFaceDetector()),
          cameraPermissionProvider.overrideWithValue(() async => true),
        ],
        child: MaterialApp(
            home: Builder(builder: (ctx) {
          return ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(ctx).push<List<Uint8List>>(
                MaterialPageRoute(
                    builder: (_) => FaceCaptureScreen(
                          verifier: verifier.call,
                          maxFrames: maxFrames,
                        )),
              );
            },
            child: const Text('go'),
          );
        })),
      ));
      await t.tap(find.text('go'));
      await t.pump();
    }

    testWidgets('a later pass pops at once with only the passing frame',
        (t) async {
      result = null;
      final verifier = _ScriptVerifier(passOn: 2);
      await pushVerify(t, verifier, 30);
      await t.pump(const Duration(seconds: 5));
      // First check mismatched in-session (no early pop, no crash); the
      // second check passed and popped just the passing frame.
      expect(verifier.calls, 2);
      expect(result, hasLength(1));
      expect(t.takeException(), isNull);
    });

    testWidgets('a dead session pops every mismatch frame together',
        (t) async {
      result = null;
      final verifier = _ScriptVerifier(passOn: -1);
      await pushVerify(t, verifier, 6);
      await t.pump(const Duration(seconds: 5));
      // 6 analyzed: frame 1 warms the streak, frames 2..6 each checked
      // live (5 mismatches kept, none popped early); the spent session
      // pops them together so the caller burns exactly one attempt.
      expect(verifier.calls, 5);
      expect(result, hasLength(5));
      expect(t.takeException(), isNull);
    });

    testWidgets('live score feedback with countdown shows mid-session',
        (t) async {
      result = null;
      final verifier = _ScriptVerifier(passOn: -1);
      await pushVerify(t, verifier, 30);
      await t.pump(const Duration(seconds: 4));
      // Still scanning: the holder sees what to do + seconds remaining.
      expect(find.textContaining('Not matching yet'), findsOneWidget);
      expect(find.textContaining('s left'), findsOneWidget);
      await t.pump(const Duration(seconds: 40));
      // Spent session: all 29 checked frames pop together.
      expect(verifier.calls, 29);
      expect(result, hasLength(29));
      expect(t.takeException(), isNull);
    });
  });

  group('needs-review retries (4 mismatch sessions, then review)', () {
    testWidgets('dead sessions burn one attempt each → manual fallback',
        (t) async {
      await t.pumpWidget(_scanScope(failFace: true));
      await t.pumpAndSettle();
      // Window already open (probe) → face check auto-scans a 12s verify
      // session by itself (zero taps); the dead session burns ONE attempt.
      await _enterIp(t, '192.168.43.1');
      await t.tap(find.text('Join'));
      await _waitFor(t, find.textContaining('Retry face scan (3 left)'));
      expect(find.textContaining('Retry face scan (3 left)'), findsOneWidget);
      // Attempt 2 fails → two retries left; the retry auto-scans again.
      await t.tap(find.textContaining('Retry face scan'));
      await _waitFor(t, find.textContaining('Retry face scan (2 left)'));
      expect(find.textContaining('Retry face scan (2 left)'), findsOneWidget);
      // Attempt 3 fails → one retry left.
      await t.tap(find.textContaining('Retry face scan'));
      await _waitFor(t, find.textContaining('Retry face scan (1 left)'));
      expect(find.textContaining('Retry face scan (1 left)'), findsOneWidget);
      // Attempt 4 fails → budget exhausted → manual fallback offered.
      await t.tap(find.textContaining('Retry face scan'));
      await _waitFor(t, find.text('Request manual attendance instead'));
      expect(find.text('Request manual attendance instead'), findsOneWidget);
      // Drain the pre-warmed radio-listen timers armed during the rounds.
      await t.pump(const Duration(seconds: 35));
      expect(t.takeException(), isNull);
    });
  });
}
