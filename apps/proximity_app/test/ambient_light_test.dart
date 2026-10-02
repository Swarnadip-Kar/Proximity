// Live ambient light contracts: log-scale mapping (gradual, never a snap),
// provider default, and session wiring (dark room glows + maxes fast with
// no capture beats; bright room stays quiet; readout always carries B).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/security/integrity.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/features/setup/ambient_light.dart';
import 'package:proximity_app/features/setup/enroll_capture.dart';
import 'package:proximity_app/features/setup/enroll_flow.dart';
import 'package:proximity_app/features/setup/flash_assist.dart';
import 'package:proximity_app/routes.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';

class _CleanProbe implements IntegrityProbe {
  const _CleanProbe();
  @override
  Future<IntegritySignals> check() async => const IntegritySignals();
}

/// Stepped lux source for grading tests (replay lists flush all values in
/// one drain; this yields one value per pump).
class _SteppedAmbient implements AmbientLight {
  final Stream<double> stream;
  _SteppedAmbient(this.stream);
  @override
  Stream<double> watch() => stream;
}

void main() {
  setUp(() => IntegrityGate.probe = const _CleanProbe());
  tearDown(() => IntegrityGate.probe = const PlatformIntegrityProbe());
  setUp(EnrollFlow.debugReset);
  tearDown(EnrollFlow.debugReset);

  group('lux mapping', () {
    test('dark maps high, bright maps zero, monotonic between', () {
      expect(luxToLevel(0), 1.0);
      expect(luxToLevel(5), greaterThan(0.6));
      expect(luxToLevel(500), 0.0);
      expect(luxToLevel(5000), 0.0);
      var prev = 2.0;
      for (final lux in [0.0, 5.0, 15.0, 30.0, 60.0, 150.0, 300.0, 500.0]) {
        final level = luxToLevel(lux);
        expect(level, lessThan(prev), reason: 'lux=$lux');
        prev = level;
      }
    });

    test('unknown lux is never darkness evidence', () {
      expect(luxToLevel(double.nan), 0.0);
      expect(luxToLevel(double.infinity), 0.0);
      expect(luxToLevel(-5), 0.0);
      expect(luxIsDark(double.nan), isFalse);
    });

    test('brightness token runs dark-low to bright-high', () {
      expect(luxToBrightness(0), 0.0);
      expect(luxToBrightness(500), 255.0);
      expect(luxToBrightness(5), lessThan(luxToBrightness(300)));
    });

    test('dark switch boundary', () {
      expect(luxIsDark(5), isTrue);
      expect(luxIsDark(29.9), isTrue);
      expect(luxIsDark(30), isFalse);
      expect(luxIsDark(400), isFalse);
    });

    test('provider resolves the channel impl by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(enrollAmbientLightProvider),
          isA<ChannelAmbientLight>());
    });

    test('fake replays scripted lux', () async {
      final fake = FakeAmbientLight(luxes: [10, 200]);
      expect(await fake.watch().toList(), [10, 200]);
      expect(await FakeAmbientLight().watch().toList(), isEmpty);
    });
  });

  group('preview-frame brightness', () {
    test('Y plane mean reads dark and bright', () {
      final dark = Uint8List.fromList(List.filled(1600, 12));
      final bright = Uint8List.fromList(List.filled(1600, 230));
      expect(meanFrameBrightness(dark, PreviewFrameFormat.y), 12.0);
      expect(meanFrameBrightness(bright, PreviewFrameFormat.y), 230.0);
    });

    test('BGRA luma reads white and black pixels', () {
      // Byte order B,G,R,A: white pixel + black pixel.
      final bytes = Uint8List.fromList([
        for (var i = 0; i < 16; i++) ...[255, 255, 255, 255],
        for (var i = 0; i < 16; i++) ...[0, 0, 0, 255],
      ]);
      final level = meanFrameBrightness(bytes, PreviewFrameFormat.bgra);
      expect(level, greaterThan(100));
      expect(level, lessThan(160));
    });

    test('empty input is no evidence, never darkness', () {
      expect(meanFrameBrightness(Uint8List(0), PreviewFrameFormat.y), isNaN);
      expect(luxToLevel(double.nan), 0.0);
    });
  });

  group('session tracks the live room', () {
    Future<EnrollmentController> keyReady() async {
      final ctl = EnrollmentController(
        auth: FakeAuthService(const SignedAccount(
            email: 's@x.in', displayName: 'S', uid: 'u1')),
        store: InMemoryDeviceStore(),
        verifier: FakeFaceVerifier(),
        deviceKey: FakeDeviceKey(),
        livenessGate: FakeLivenessGate(),
      );
      await ctl.signIn();
      await ctl.generateKey();
      return ctl;
    }

    Widget harness(
            {required EnrollmentController ctl,
            AmbientLight? ambient,
            EnrollSessionCamera? camera,
            PoseGate? gate,
            LivenessGate? sessionLiveness,
            ScreenBrightnessControl? brightness}) =>
        ProviderScope(
          overrides: [
            enrollmentControllerProvider.overrideWith((ref) => ctl),
            enrollSessionCameraProvider
                .overrideWithValue(camera ?? FakeEnrollSessionCamera()),
            poseGateProvider.overrideWithValue(gate ?? FakePoseGate()),
            enrollSessionLivenessProvider.overrideWithValue(
                sessionLiveness ?? FakeLivenessGate()),
            enrollScreenBrightnessProvider.overrideWithValue(
                brightness ?? FakeScreenBrightnessControl()),
            enrollAmbientLightProvider
                .overrideWithValue(ambient ?? FakeAmbientLight()),
          ],
          child: MaterialApp(
            theme: proxLightTheme(),
            routes: buildProxRoutes(),
            onGenerateRoute: proxOnGenerateRoute,
            onUnknownRoute: proxOnUnknownRoute,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const EnrollCaptureScreen()),
                  ),
                  child: const Text('open-capture'),
                ),
              ),
            ),
          ),
        );

    Future<void> openSession(WidgetTester t) async {
      await t.tap(find.text('open-capture'));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 300));
    }

    Future<void> drain(WidgetTester t) async {
      for (var i = 0; i < 15; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
    }

    double ringOf(WidgetTester t) =>
        t.widget<CaptureOverlay>(find.byType(CaptureOverlay)).flashLevel;

    String readoutOf(WidgetTester t) {
      // The bottom-bar readout is the only LIVE line on screen (the hidden
      // terminal chrome also carries Texts, so a scoped descendant find
      // over-matches).
      final lives = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data ?? '')
          .where((s) => s.startsWith('LIVE'));
      return lives.isEmpty ? '' : lives.first;
    }

    testWidgets('dark room glows and maxes with no beats waited',
        (t) async {
      // Pose never reads (all null) so no capture probe ever runs — the
      // old path would sit dark and silent. Live lux 5 fires the ring +
      // window max on the first sensor event instead.
      final ctl = await keyReady();
      final brightness = FakeScreenBrightnessControl(scriptedCurrent: 0.35);
      await t.pumpWidget(harness(
        ctl: ctl,
        ambient: FakeAmbientLight(luxes: [5]),
        brightness: brightness,
      ));
      await openSession(t);
      await t.pump(const Duration(milliseconds: 500));
      expect(ringOf(t), greaterThan(0.6));
      expect(brightness.sets, [1.0]);
      expect(readoutOf(t), contains('B'));
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(brightness.sets, [1.0, 0.35]);
      expect(t.takeException(), isNull);
    });

    testWidgets('bright room paints no ring, touches nothing', (t) async {
      final ctl = await keyReady();
      final brightness = FakeScreenBrightnessControl(scriptedCurrent: 0.5);
      await t.pumpWidget(harness(
        ctl: ctl,
        ambient: FakeAmbientLight(luxes: [400]),
        brightness: brightness,
      ));
      await openSession(t);
      await t.pump(const Duration(milliseconds: 1500));
      // Near-zero (faint tail of the log curve), never exactly zero above
      // 0 lux — what matters is no window-max and a live B token.
      expect(ringOf(t), lessThan(0.05));
      expect(brightness.sets, isEmpty);
      // Live number still rides the readout (never a stuck lineless B):
      // lux 400 maps to B246 on the 0-255 token scale.
      expect(readoutOf(t), contains('B246'));
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('ring grades up as the room darkens', (t) async {
      // Controller-driven lux (one value per pump): replay lists flush all
      // values in the same microtask drain, so stepped rooms need a
      // stepped source.
      final ctrl = StreamController<double>.broadcast();
      addTearDown(() => ctrl.close());
      final ctl = await keyReady();
      await t.pumpWidget(harness(
        ctl: ctl,
        ambient: _SteppedAmbient(ctrl.stream),
      ));
      await openSession(t);
      ctrl.add(300);
      await t.pump(const Duration(milliseconds: 300));
      final first = ringOf(t);
      ctrl.add(100);
      await t.pump(const Duration(milliseconds: 300));
      final mid = ringOf(t);
      ctrl.add(10);
      await t.pump(const Duration(milliseconds: 300));
      final last = ringOf(t);
      expect(first, lessThan(0.3));
      expect(mid, greaterThan(first));
      expect(last, greaterThan(0.5));
      expect(last, greaterThan(mid));
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('dark preview frames glow with no sensor and no probes',
        (t) async {
      // iOS path: no light-sensor side (empty ambient) and the pose gate
      // never reads, so no probe ever runs — preview frames alone (B12)
      // grade the ring to (70-12)/70 ≈ 0.83 and max the window on the
      // first frame. Faceless throughout (no fills, no completion race).
      final ctl = await keyReady();
      final brightness = FakeScreenBrightnessControl(scriptedCurrent: 0.35);
      final blind =
          FakePoseGate(readings: List<PoseReading?>.filled(40, null));
      await t.pumpWidget(harness(
        ctl: ctl,
        camera: FakeEnrollSessionCamera([], false, [12]),
        gate: blind,
        brightness: brightness,
      ));
      await openSession(t);
      await t.pump(const Duration(milliseconds: 800));
      expect(ringOf(t), moreOrLessEquals(0.83, epsilon: 0.1));
      expect(brightness.sets, [1.0]);
      expect(readoutOf(t), contains('B12'));
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(brightness.sets, [1.0, 0.35]);
      expect(t.takeException(), isNull);
    });

    testWidgets('bright preview frames stay quiet with a live B token',
        (t) async {
      final ctl = await keyReady();
      final brightness = FakeScreenBrightnessControl(scriptedCurrent: 0.5);
      final blind =
          FakePoseGate(readings: List<PoseReading?>.filled(40, null));
      await t.pumpWidget(harness(
        ctl: ctl,
        camera: FakeEnrollSessionCamera([], false, [200]),
        gate: blind,
        brightness: brightness,
      ));
      await openSession(t);
      await t.pump(const Duration(milliseconds: 1500));
      expect(ringOf(t), 0.0);
      expect(brightness.sets, isEmpty);
      expect(readoutOf(t), contains('B200'));
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('refused sampler falls back to capture brightness',
        (t) async {
      // Sampler throws (unsupported concurrency): scored-dark probes still
      // grade the ring to (70-45)/70 ≈ 0.36 through the capture path.
      const down = PoseReading(yaw: 0, pitch: -15, roll: 0);
      final ctl = await keyReady();
      await t.pumpWidget(harness(
        ctl: ctl,
        camera: FakeEnrollSessionCamera([], false, [], true),
        gate: FakePoseGate(readings: List<PoseReading?>.filled(6, down)),
        sessionLiveness:
            FakeLivenessGate(score: 0.95, scriptedBrightness: 45.0),
      ));
      await openSession(t);
      await t.pump(const Duration(milliseconds: 3000));
      expect(ringOf(t), moreOrLessEquals(0.36, epsilon: 0.08));
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(t.takeException(), isNull);
    });
  });
}
