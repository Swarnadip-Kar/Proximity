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

    testWidgets('unknown previous clears to system, never strands max',
        (t) async {
      // Previous unknown (channel failure): restore clears the window
      // override (-1 = follow system) instead of leaving max applied —
      // a stranded max is what showed "controlled by another app" after
      // back navigation (same Activity window survives the pop).
      final fake = FakeScreenBrightnessControl(scriptedCurrent: null);
      await pumpSync(t, active: true, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0]);
      await t.pumpWidget(const MaterialApp(home: Scaffold()));
      await t.pump();
      expect(fake.sets, [1.0, -1.0]);
      expect(t.takeException(), isNull);
    });

    testWidgets('system-follow previous restores verbatim', (t) async {
      // Window already followed system (-1): max then restore to -1, never
      // clamped to 0 (darkest) — clamping stranded the slider.
      final fake = FakeScreenBrightnessControl(scriptedCurrent: -1.0);
      await pumpSync(t, active: true, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0]);
      await pumpSync(t, active: false, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0, -1.0]);
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
      // Every beat throws dim: the fast glow stalls at the second probe,
      // the graded ring fades in, brightness maxes; cancel pops the screen
      // and the previous value is restored. Brightness evidence is absent
      // (throws carry none), so the stall fallback level (0.5) applies.
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
      Finder overlay() => find.byType(CaptureOverlay);
      for (var i = 0;
          i < 40 &&
              !(overlay().evaluate().isNotEmpty &&
                  t.widget<CaptureOverlay>(overlay()).flashLevel > 0.05);
          i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      final level = t.widget<CaptureOverlay>(overlay()).flashLevel;
      expect(level, greaterThan(0.05));
      expect(level, lessThanOrEqualTo(0.5));
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
      expect(
          t.widget<CaptureOverlay>(find.byType(CaptureOverlay)).flashLevel,
          0.0);
      expect(brightness.sets, isEmpty);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(brightness.sets, isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('graded level tracks measured darkness', (t) async {
      // Scored-dark probes (bright 45 of hint 70) grade the ring to
      // (70-45)/70 ≈ 0.36 — darker would glow brighter, brighter lower.
      // Fixed pump: beats 1-2 fill down (stash, confirm), beats 3-5 miss
      // centre — brightness stays fresh throughout, so the level settles
      // at the measured mapping instead of the stall fallback.
      const down = PoseReading(yaw: 0, pitch: -15, roll: 0);
      final gate =
          FakePoseGate(readings: List<PoseReading?>.filled(6, down));
      final ctl = await keyReady();
      final brightness = FakeScreenBrightnessControl();
      await t.pumpWidget(harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(
            score: 0.95, scriptedBrightness: 45.0),
        brightness: brightness,
      ));
      await openSession(t);
      await t.pump(const Duration(milliseconds: 3000));
      final level =
          t.widget<CaptureOverlay>(find.byType(CaptureOverlay)).flashLevel;
      expect(level, moreOrLessEquals(0.36, epsilon: 0.08));
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('faceless beats stall with assist, then recover',
        (t) async {
      // Pose reads nothing four beats running (dark-room signature): the
      // stall nudge + assist fire with no probe evidence at all. A later
      // readable frame fills and clears both back to guidance.
      final gate = FakePoseGate(readings: [
        null,
        null,
        null,
        null,
        null,
        const PoseReading(yaw: 0, pitch: -15, roll: 0),
        const PoseReading(yaw: 0, pitch: -15, roll: 0),
      ]);
      final ctl = await keyReady();
      final brightness = FakeScreenBrightnessControl();
      await t.pumpWidget(harness(
        ctl: ctl,
        gate: gate,
        sessionLiveness: FakeLivenessGate(score: 0.95),
        brightness: brightness,
      ));
      await openSession(t);
      final stalled = find.text(
          'No good capture yet — face the lens in brighter light');
      for (var i = 0; i < 40 && stalled.evaluate().isEmpty; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(stalled, findsOneWidget);
      expect(
          t
              .widget<CaptureOverlay>(find.byType(CaptureOverlay))
              .flashLevel,
          greaterThan(0.05));
      expect(brightness.sets, [1.0]);
      // Readable frames resume the walk: the stall line yields back to
      // the guided prompt (down fills on the confirming beat).
      await t.pump(const Duration(milliseconds: 2500));
      expect(stalled, findsNothing);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('ring paints inside the overlay, frame stays bare',
        (t) async {
      // Squish-fix guard for the assist path: with the ring on, the seam
      // frame is still a direct Stack child (loose + centered) with no
      // Container/decoration/fit/transform between it and the Stack — the
      // ring lives inside the overlay painter (above the scrim, uniform
      // light), never as a sibling widget.
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
              flashLevel: 0.5,
            ),
          ),
        ),
      ));
      await t.pump();
      expect(
          t.widget<CaptureOverlay>(find.byType(CaptureOverlay)).flashLevel,
          0.5);
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

    test('flash ring frame hugs the edges, clears the bar', () {
      // Full-bleed rect (the bottom bar paints over the band — no gap);
      // inner corners stay rounded (see ringInnerRadius).
      expect(CaptureOverlay.flashRingRectFor(const Size(800, 400)),
          Offset.zero & const Size(800, 400));
      expect(CaptureOverlay.ringBandWidth, moreOrLessEquals(30));
      expect(CaptureOverlay.ringInnerRadius, greaterThan(0));
    });

    testWidgets('capture scaffold ignores keyboard insets', (t) async {
      final ctl = await keyReady();
      await t.pumpWidget(harness(ctl: ctl));
      await openSession(t);
      expect(t.takeException(), isNull);
      // The capture screen owns its Scaffold (builds it below itself —
      // hence descendant, not ancestor: the home shell's Scaffold is a
      // sibling route, correctly excluded).
      final scaffold = find.descendant(
          of: find.byType(EnrollCaptureScreen),
          matching: find.byType(Scaffold));
      expect(t.widget<Scaffold>(scaffold).resizeToAvoidBottomInset, isFalse);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('capture entry drops keyboard focus', (t) async {
      // ID-field stand-in with autofocus (keyboard up on the previous
      // step): entering capture must drop ITS focus so the preview never
      // inherits the keyboard resize (backed by resizeToAvoidBottomInset
      // above — no editable text lives on the capture screen itself).
      // Note the modal route scope itself takes focus on push (correct) —
      // what matters is the field losing it.
      final ctl = await keyReady();
      final fieldNode = FocusNode();
      addTearDown(fieldNode.dispose);
      await t.pumpWidget(ProviderScope(
        overrides: [
          enrollmentControllerProvider.overrideWith((ref) => ctl),
          enrollSessionCameraProvider
              .overrideWithValue(FakeEnrollSessionCamera()),
          poseGateProvider.overrideWithValue(FakePoseGate()),
          enrollSessionLivenessProvider
              .overrideWithValue(FakeLivenessGate()),
          enrollScreenBrightnessProvider
              .overrideWithValue(FakeScreenBrightnessControl()),
        ],
        child: MaterialApp(
          theme: proxLightTheme(),
          routes: buildProxRoutes(),
          onGenerateRoute: proxOnGenerateRoute,
          onUnknownRoute: proxOnUnknownRoute,
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  TextField(autofocus: true, focusNode: fieldNode),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const EnrollCaptureScreen()),
                    ),
                    child: const Text('open-capture'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(fieldNode.hasFocus, isTrue);
      await openSession(t);
      expect(fieldNode.hasFocus, isFalse);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await drain(t);
      expect(t.takeException(), isNull);
    });
  });
}
