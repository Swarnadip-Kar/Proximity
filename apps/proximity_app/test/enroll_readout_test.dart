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
        LivenessGate? sessionLiveness}) =>
    ProviderScope(
      overrides: [
        enrollmentControllerProvider.overrideWith((ref) => ctl),
        enrollSessionCameraProvider
            .overrideWithValue(FakeEnrollSessionCamera()),
        poseGateProvider.overrideWithValue(gate ?? FakePoseGate()),
        enrollSessionLivenessProvider.overrideWithValue(
            sessionLiveness ?? FakeLivenessGate()),
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
      // (off-target stills never reach the scorer).
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
      expect(find.text('Tilt down into the glowing band'), findsOneWidget);
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
  });
}
