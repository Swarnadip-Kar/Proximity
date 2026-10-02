// Enroll readout contracts: the bottom-bar line names the live
// (vitality) score plus the bar that judged it, and surfaces a
// warn-only DIM/BLURRY/NO FACE hint after an unreadable probe.
// Presentation only — nothing here gates acceptance.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/security/user_presence.dart';
import 'package:proximity_app/core/security/integrity.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/features/setup/enroll_capture.dart';
import 'package:proximity_app/features/setup/enroll_flow.dart';
import 'package:proximity_app/features/setup/flash_assist.dart';
import 'package:proximity_app/routes.dart';

class _CleanProbe implements IntegrityProbe {
  const _CleanProbe();
  @override
  Future<IntegritySignals> check() async => const IntegritySignals();
}

Future<EnrollmentController> _keyReady() async {
  final ctl = EnrollmentController(
    auth: FakeAuthService(const SignedAccount(
        email: 's@x.in', displayName: 'S', uid: 'u1')),
    store: InMemoryDeviceStore(),
    verifier: FakeFaceVerifier(),
    deviceKey: FakeDeviceKey(),
    presenceGate: FakePresenceGate(),
    livenessGate: FakeLivenessGate(),
  );
  await ctl.signIn();
  await ctl.generateKey();
  return ctl;
}

Widget _harness(
        {required EnrollmentController ctl,
        PoseGate? gate,
        LivenessGate? sessionLiveness,
        ScreenBrightnessControl? brightness}) =>
    ProviderScope(
      overrides: [
        enrollmentControllerProvider.overrideWith((ref) => ctl),
        enrollSessionCameraProvider
            .overrideWithValue(FakeEnrollSessionCamera()),
        poseGateProvider.overrideWithValue(gate ?? FakePoseGate()),
        enrollSessionLivenessProvider.overrideWithValue(
            sessionLiveness ?? FakeLivenessGate()),
        // Brightness seam (same rule as camera/pose/liveness above): the
        // real channel's timeout timers never settle under FakeAsync (see
        // HardwareDeviceIds), so session tests always drive the fake —
        // the fail-soft channel path is pinned by unit tests instead.
        enrollScreenBrightnessProvider.overrideWithValue(
            brightness ?? FakeScreenBrightnessControl()),
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

Future<void> _openSession(WidgetTester t) async {
  await t.tap(find.text('open-capture'));
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _drain(WidgetTester t) async {
  for (var i = 0; i < 15; i++) {
    await t.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  setUp(EnrollFlow.debugReset);
  tearDown(EnrollFlow.debugReset);
  setUp(() => IntegrityGate.probe = const _CleanProbe());
  tearDown(() => IntegrityGate.probe = const PlatformIntegrityProbe());

  group('enroll live readout (vitality + bar + hint)', () {
    testWidgets('unreadable dim probe shows DIM hint with the bar',
        (t) async {
      // Walk asks down first: serve down so the vitality probe runs
      // (off-target stills never reach the scorer). Two scripted downs =
      // two dim throws (streak 2, below the 3-stall), then the default
      // cycle misses down, so the guided prompt stays put for this test
      // (the stall promotion has its own test below).
      final gate = FakePoseGate(readings: const [
        PoseReading(yaw: 0, pitch: -15, roll: 0),
        PoseReading(yaw: 0, pitch: -15, roll: 0),
      ]);
      final ctl = await _keyReady();
      await t.pumpWidget(_harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(
            throwOnDetect: true,
            throwReason: LivenessUnreadableReason.dim),
      ));
      await _openSession(t);
      await t.pump(const Duration(milliseconds: 1500));
      // Warn-only hint: score placeholder + bar + target + DIM.
      expect(find.textContaining('DIM'), findsOneWidget);
      expect(find.textContaining('/0.70'), findsOneWidget);
      // The overlay prompt stays frozen on the target (never narrates
      // checker state).
      expect(find.text('Tilt down into the glowing blue band'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('scored probe shows score with its bar', (t) async {
      final gate = FakePoseGate(readings: const [
        PoseReading(yaw: 0, pitch: -15, roll: 0),
      ]);
      final ctl = await _keyReady();
      await t.pumpWidget(_harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(score: 0.95),
      ));
      await _openSession(t);
      await t.pump(const Duration(milliseconds: 1500));
      expect(find.textContaining('0.95/0.70'), findsOneWidget);
      expect(find.textContaining('DIM'), findsNothing);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('three dark probes promote the overlay prompt', (t) async {
      // Dark room, passing probes: buckets still fill (warn-only, never a
      // gate) but the overlay prompt becomes the move-to-light line so the
      // holder cannot miss it. Doubled readings per slot: dark 0.95 parks
      // for confirmation (below-margin shaping), so each slot needs two
      // consecutive probes — three dark probes land by the third beat.
      const down = PoseReading(yaw: 0, pitch: -15, roll: 0);
      const centre = PoseReading(yaw: 0, pitch: 0, roll: 0);
      final gate = FakePoseGate(readings: const [down, down, centre]);
      final ctl = await _keyReady();
      await t.pumpWidget(_harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(
            score: 0.95, scriptedBrightness: 45.0),
      ));
      await _openSession(t);
      final dark = find.text('Too dark — move to brighter light');
      for (var i = 0; i < 30 && dark.evaluate().isEmpty; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(dark, findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('bright session keeps the guided prompt', (t) async {
      final gate = FakePoseGate(readings: const [
        PoseReading(yaw: 0, pitch: -15, roll: 0),
      ]);
      final ctl = await _keyReady();
      await t.pumpWidget(_harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(
            score: 0.95, scriptedBrightness: 90.0),
      ));
      await _openSession(t);
      await t.pump(const Duration(milliseconds: 1500));
      expect(find.text('Too dark — move to brighter light'), findsNothing);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });
    testWidgets('dark passing probes park and never fill', (t) async {
      // Low-brightness photos are not allowed: an auto-exposed dark-room
      // frame that scores 0.95 still parks (readout names score + DIM so
      // the holder moves to brighter light) and a back-to-back dark pass
      // parks again — the bucket only fills on a bright confirm.
      final gate = FakePoseGate(readings: const [
        PoseReading(yaw: 0, pitch: -15, roll: 0),
        PoseReading(yaw: 0, pitch: -15, roll: 0),
        PoseReading(yaw: 0, pitch: -15, roll: 0),
      ]);
      final ctl = await _keyReady();
      await t.pumpWidget(_harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(
            score: 0.95, scriptedBrightness: 45.0),
      ));
      await _openSession(t);
      await t.pump(const Duration(milliseconds: 1500));
      expect(find.textContaining('DIM'), findsOneWidget);
      expect(find.textContaining('0.95/0.70'), findsOneWidget);
      expect(find.text('Save enrollment'), findsNothing);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });
    testWidgets('marginal then failing never fills', (t) async {
      // Confirmation shaping: a marginal first sighting (0.75) parks, the
      // failing follow-up (0.40) clears the park — the bucket never fills
      // on a lone lucky single, and the session just continues.
      const down = PoseReading(yaw: 0, pitch: -15, roll: 0);
      final gate = FakePoseGate(
          readings: List<PoseReading?>.filled(12, down));
      final ctl = await _keyReady();
      await t.pumpWidget(_harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(
            score: 0.40, scriptedScores: [0.75]),
      ));
      await _openSession(t);
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 300));
      }
      expect(find.text('Save enrollment'), findsNothing);
      expect(ctl.state.phase, EnrollPhase.keyReady);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('two marginals confirm and fill with the fresh still',
        (t) async {
      // Back-to-back marginal passes fill the bucket carrying the SECOND
      // probe's score (the parked still is discarded, the fresh one kept).
      const down = PoseReading(yaw: 0, pitch: -15, roll: 0);
      final gate = FakePoseGate(
          readings: List<PoseReading?>.filled(6, down));
      final ctl = await _keyReady();
      await t.pumpWidget(_harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(
            score: 0.78, scriptedScores: [0.75]),
      ));
      await _openSession(t);
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 300));
      }
      // Confirming probe's score rides the readout (not the parked one's).
      expect(find.textContaining('0.78/0.70'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('readout shows numeric brightness when known', (t) async {
      // The holder sees the measured number (same probe the native gate
      // logs as `bright=`), not just the DIM verdict.
      const down = PoseReading(yaw: 0, pitch: -15, roll: 0);
      final gate = FakePoseGate(
          readings: List<PoseReading?>.filled(4, down));
      final ctl = await _keyReady();
      await t.pumpWidget(_harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(
            score: 0.95, scriptedBrightness: 139.0),
      ));
      await _openSession(t);
      await t.pump(const Duration(milliseconds: 1500));
      expect(find.textContaining('Brightness: 139'), findsOneWidget);
      expect(find.textContaining('DIM'), findsNothing);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('eight wasted beats promote the stall nudge', (t) async {
      // The reported dark-room spin: pose never reads the target, no probe
      // ever runs, brightness hints cannot fire — after ~10s with no fill
      // the overlay prompt becomes the stall nudge instead of silence.
      const centre = PoseReading(yaw: 0, pitch: 0, roll: 0);
      final gate = FakePoseGate(
          readings: List<PoseReading?>.filled(18, centre));
      final ctl = await _keyReady();
      await t.pumpWidget(_harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(score: 0.95),
      ));
      await _openSession(t);
      final stall = find.text(
          'No good capture yet — face the lens in brighter light');
      for (var i = 0; i < 60 && stall.evaluate().isEmpty; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(stall, findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });
  });
}
