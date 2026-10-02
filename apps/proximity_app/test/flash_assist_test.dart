// Flash assist seam contracts: fail-soft channel, fake round-trip, and
// the sync widget lifecycle (max on activate, restore on deactivate and
// on dispose; unknown previous skips restore instead of writing garbage).
//
// Session-level contracts live at the bottom: a dark session paints the
// ring, maxes brightness, and restores on cancel; a bright session never
// touches brightness; the ring is a Stack sibling, never a wrapper around
// the bare surface (squish-fix chain).
//
// Widget-test integrity fake: the real PlatformIntegrityProbe does native
// channel I/O with a .timeout budget, which never fires under the
// testWidgets FakeAsync clock — generateKey hangs forever without this.
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
import 'package:proximity_app/features/setup/enroll_capture.dart';
import 'package:proximity_app/features/setup/enroll_capture_sections.dart';
import 'package:proximity_app/features/setup/enroll_flow.dart';
import 'package:proximity_app/features/setup/enroll_widgets.dart';
import 'package:proximity_app/features/setup/flash_assist.dart';
import 'package:proximity_app/routes.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';

class _CleanProbe implements IntegrityProbe {
  const _CleanProbe();
  @override
  Future<IntegritySignals> check() async => const IntegritySignals();
}

void main() {
  // Widget-test integrity fake (see enroll_guided_test): the real probe's
  // native I/O never completes under FakeAsync and generateKey would hang.
  setUp(() => IntegrityGate.probe = const _CleanProbe());
  tearDown(() => IntegrityGate.probe = const PlatformIntegrityProbe());
  setUp(EnrollFlow.debugReset);
  tearDown(EnrollFlow.debugReset);

  group('ChannelScreenBrightnessControl fail-soft', () {
    test('no channel mock degrades to null / no-op, never throws', () async {
      // No TestDefaultBinaryMessenger mock: the unit-test engine has no
      // native side, so every hop raises MissingPluginException — the
      // control must degrade instead of throwing past the caller.
      const control = ChannelScreenBrightnessControl();
      expect(await control.current(), isNull);
      await control.set(1.0); // must not throw
    });

    test('provider resolves the channel impl by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(enrollScreenBrightnessProvider),
          isA<ChannelScreenBrightnessControl>());
    });
  });

  group('FakeScreenBrightnessControl', () {
    test('scripted current round-trips, sets recorded', () async {
      final fake = FakeScreenBrightnessControl(scriptedCurrent: 0.4);
      expect(await fake.current(), 0.4);
      await fake.set(1.0);
      await fake.set(0.4);
      expect(fake.sets, [1.0, 0.4]);
    });
  });

  group('FlashAssistSync lifecycle', () {
    Future<void> pumpSync(WidgetTester t,
        {required bool active,
        required FakeScreenBrightnessControl fake}) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: FlashAssistSync(active: active, control: fake))));
      await t.pump();
    }

    testWidgets('inactive never touches brightness', (t) async {
      final fake = FakeScreenBrightnessControl(scriptedCurrent: 0.4);
      await pumpSync(t, active: false, fake: fake);
      expect(fake.sets, isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('activate reads previous then sets max', (t) async {
      final fake = FakeScreenBrightnessControl(scriptedCurrent: 0.4);
      await pumpSync(t, active: false, fake: fake);
      await pumpSync(t, active: true, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0]);
      expect(t.takeException(), isNull);
    });

    testWidgets('deactivate restores the previous value', (t) async {
      final fake = FakeScreenBrightnessControl(scriptedCurrent: 0.4);
      await pumpSync(t, active: true, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0]);
      await pumpSync(t, active: false, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0, 0.4]);
      expect(t.takeException(), isNull);
    });

    testWidgets('dispose while active restores', (t) async {
      final fake = FakeScreenBrightnessControl(scriptedCurrent: 0.4);
      await pumpSync(t, active: true, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0]);
      await t.pumpWidget(const MaterialApp(home: Scaffold()));
      await t.pump();
      expect(fake.sets, [1.0, 0.4]);
      expect(t.takeException(), isNull);
    });

    testWidgets('unknown previous skips restore, never writes garbage',
        (t) async {
      final fake = FakeScreenBrightnessControl(scriptedCurrent: null);
      await pumpSync(t, active: true, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0]);
      await t.pumpWidget(const MaterialApp(home: Scaffold()));
      await t.pump();
      expect(fake.sets, [1.0]);
      expect(t.takeException(), isNull);
    });
  });

  group('flash assist in the enroll session', () {
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

    testWidgets('dark session rings, maxes, and restores on cancel',
        (t) async {
      // Every beat throws dim: the dark streak stalls at the third probe,
      // the ring paints, brightness maxes; cancel pops the screen and the
      // previous value is restored.
      const down = PoseReading(yaw: 0, pitch: -15, roll: 0);
      final gate =
          FakePoseGate(readings: List<PoseReading?>.filled(6, down));
      final ctl = await keyReady();
      final brightness =
          FakeScreenBrightnessControl(scriptedCurrent: 0.35);
      await t.pumpWidget(harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(
            throwOnDetect: true,
            throwReason: LivenessUnreadableReason.dim),
        brightness: brightness,
      ));
      await openSession(t);
      final ring = find.byKey(const Key('flash-ring'));
      for (var i = 0; i < 40 && ring.evaluate().isEmpty; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(ring, findsOneWidget);
      expect(brightness.sets, [1.0]);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(brightness.sets, [1.0, 0.35]);
      expect(t.takeException(), isNull);
    });

    testWidgets('bright session paints no ring, touches nothing',
        (t) async {
      const down = PoseReading(yaw: 0, pitch: -15, roll: 0);
      final gate =
          FakePoseGate(readings: List<PoseReading?>.filled(4, down));
      final ctl = await keyReady();
      final brightness =
          FakeScreenBrightnessControl(scriptedCurrent: 0.5);
      await t.pumpWidget(harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(
            score: 0.95, scriptedBrightness: 139.0),
        brightness: brightness,
      ));
      await openSession(t);
      await t.pump(const Duration(milliseconds: 1500));
      expect(find.byKey(const Key('flash-ring')), findsNothing);
      expect(brightness.sets, isEmpty);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(brightness.sets, isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('ring is a sibling, never a wrapper around the frame',
        (t) async {
      // Squish-fix guard for the assist path: with the ring on, the seam
      // frame is still a direct Stack child (loose + centered) with no
      // Container/decoration/fit/transform between it and the Stack.
      const seam = Key('assist-seam');
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: const Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: EnrollCapturePreview(
              controller: null,
              isOpening: false,
              failMessage: null,
              doneCount: 1,
              total: 5,
              nextAngle: 1,
              totalAngles: 5,
              statusLine: enrollCapturePrompt,
              sweepAngle: 0.5,
              saveError: false,
              saveMessage: '',
              preview: SizedBox(key: seam),
              previewAspectRatio: 3 / 4,
              flashAssist: true,
            ),
          ),
        ),
      ));
      await t.pump();
      expect(find.byKey(const Key('flash-ring')), findsOneWidget);
      final stack = find.byWidgetPredicate((w) =>
          w is Stack &&
          w.fit == StackFit.loose &&
          w.alignment == Alignment.center &&
          w.children.whereType<CaptureOverlay>().isNotEmpty);
      expect(stack, findsOneWidget);
      final between = <Widget>[];
      t.element(find.byKey(seam)).visitAncestorElements((a) {
        if (a.widget is Stack) return false;
        between.add(a.widget);
        return true;
      });
      for (final ban in [
        Container,
        DecoratedBox,
        ColoredBox,
        FittedBox,
        AspectRatio,
      ]) {
        expect(between.where((w) => w.runtimeType == ban), isEmpty,
            reason: 'wrapper in frame path: $ban');
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  });
}
