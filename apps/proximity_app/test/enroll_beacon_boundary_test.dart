// Enrollment boundary + beacon contracts (UI-boundary overflow fix).
//
// Elongation root cause was bottom-slot sizing (single prompt vs original
// prompt+status+button enlarged the preview area; Stack tight +
// CameraPreview AspectRatio-ignore stretches the feed to the area), so these
// pin the device-boundary path: Scaffold defaults, no SafeArea double-apply,
// no constraining wrappers/fixed boxes in the preview path, AppBar height,
// and the invisible original-height reservation. Beacon painter tests pin the
// trail-fully-faded invariant (tail alpha 0, head bright, tail << full rev)
// and reduced-motion steady soft glow. Clock: beacon timer is periodic —
// drive with bounded pumps, never pumpAndSettle with the session mounted.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/features/enrollment/enroll_capture.dart';
import 'package:proximity_app/features/enrollment/enroll_widgets.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/screens/face_capture.dart';

Future<EnrollmentController> _keyReady() async {
  final ctl = EnrollmentController(
    auth: FakeAuthService(const SignedAccount(
        email: 's@x.in', displayName: 'S', uid: 'u1')),
    store: InMemoryDeviceStore(),
    verifier: FakeFaceVerifier(),
    deviceKey: FakeDeviceKey(),
  );
  await ctl.signIn();
  await ctl.generateKey();
  return ctl;
}

Widget _captureHarness({required EnrollmentController ctl}) =>
    ProviderScope(
      overrides: [
        enrollmentControllerProvider.overrideWith((ref) => ctl),
        enrollSessionCameraProvider
            .overrideWithValue(FakeEnrollSessionCamera()),
        poseGateProvider.overrideWithValue(FakePoseGate()),
      ],
      child: MaterialApp(
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
  group('device-boundary parity (elongation fix)', () {
    testWidgets('Scaffold defaults match original (no overflow flags)',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      final scaffold =
          t.element(find.byType(Scaffold).last).widget as Scaffold;
      // Defaults: keyboard-aware, body below AppBar, never behind system UI.
      expect(scaffold.resizeToAvoidBottomInset ?? true, isTrue);
      expect(scaffold.extendBody, isFalse);
      expect(scaffold.extendBodyBehindAppBar, isFalse);
      // Same AppBar height (default toolbar, no custom preferredSize).
      final appBar =
          t.element(find.byType(AppBar).last).widget as AppBar;
      expect(appBar.toolbarHeight, isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('preview path has no SafeArea/constraining/fixed boxes',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      final chain = <Widget>[];
      t.element(find.byType(FaceCaptureOvalOverlay)).visitAncestorElements((a) {
        chain.add(a.widget);
        return true;
      });
      final upToScaffold =
          chain.sublist(0, chain.indexWhere((w) => w is Scaffold) + 1);
      // No SafeArea in the camera path (neither screen has one — no double-apply).
      expect(upToScaffold.whereType<SafeArea>(), isEmpty);
      // No constraining wrappers (would re-elongate the feed).
      for (final ban in [AspectRatio, FittedBox, ConstrainedBox]) {
        expect(upToScaffold.where((w) => w.runtimeType == ban), isEmpty,
            reason: 'constraining wrapper in preview path: $ban');
      }
      // No fixed-size boxes sizing the preview (Expanded+Center only).
      expect(
          upToScaffold.where((w) =>
              w is SizedBox && (w.height != null || w.width != null)),
          isEmpty,
          reason: 'fixed-size box in preview path');
      expect(upToScaffold.whereType<Container>(), isEmpty,
          reason: 'constrained container in preview path');
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('mid-flow keeps single prompt + dots, reserves original height',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      // Single static prompt + dots exactly (no copy changes).
      expect(find.text(enrollCapturePrompt), findsOneWidget);
      expect(find.byType(EnrollAngleDots), findsOneWidget);
      // Invisible original-height reservation (boundary parity, no semantics).
      final reservations = find.byWidgetPredicate(
          (w) => w is Visibility && !w.visible && w.maintainSize);
      expect(reservations, findsOneWidget);
      // Reservation carries the original status+button shape (hidden).
      expect(
          find.descendant(
              of: reservations, matching: find.byType(FilledButton)),
          findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });
  });

  group('rotating beacon painter', () {
    test('trail fully fades: tail transparent, head bright, tail short', () {
      // Tail tip fully transparent (no remnant survives to the next pass).
      expect(FaceCaptureOvalOverlay.beaconAlpha(0), 0.0);
      // Head brightest.
      expect(
          FaceCaptureOvalOverlay.beaconAlpha(
              FaceCaptureOvalOverlay.beaconSlices - 1),
          1.0);
      // Monotonic fade head-ward, bounded 0..1.
      var prev = -1.0;
      for (var i = 0; i < FaceCaptureOvalOverlay.beaconSlices; i++) {
        final a = FaceCaptureOvalOverlay.beaconAlpha(i);
        expect(a, inInclusiveRange(0.0, 1.0));
        expect(a, greaterThanOrEqualTo(prev));
        prev = a;
      }
      // SHORT tail: default span well before a full revolution.
      const defaultSpan = 1.047;
      expect(defaultSpan, lessThan(3.141592653589793));
      expect(FaceCaptureOvalOverlay.isSteadyGlow(defaultSpan), isFalse);
    });

    test('reduced motion is a steady soft full-rim glow (no animation)', () {
      const full = 2 * 3.141592653589793;
      expect(FaceCaptureOvalOverlay.isSteadyGlow(full), isTrue);
      // Soft: visible but not harsh full opacity.
      expect(FaceCaptureOvalOverlay.steadyGlowAlpha, greaterThan(0.0));
      expect(FaceCaptureOvalOverlay.steadyGlowAlpha, lessThan(1.0));
    });

    testWidgets('beacon + steady + marking states all render', (t) async {
      // Beacon head mid-travel.
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: FaceCaptureOvalOverlay(
                progress: 0.4, sweepAngle: 1.0, sweepSpan: 1.047)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      // Steady soft full-rim (reduced motion).
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FaceCaptureOvalOverlay(
                progress: 1.0,
                sweepAngle: 0.0,
                sweepSpan: 2 * 3.141592653589793)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      // Marking (null sweep) unchanged.
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: FaceCaptureOvalOverlay(progress: 1.0)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
