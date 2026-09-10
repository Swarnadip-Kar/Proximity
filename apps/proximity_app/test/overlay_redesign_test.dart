// Overlay redesign contracts (PRODUCT-OWNER OVERRIDE 2026-09-10 — see
// INTEGRATION_LOG.md `## Overlay redesign`): fullscreen preview, exactly
// three overlay elements (slim top progress bar, single oval + beacon, one
// prompt), both consumers render them, auto-capture driver semantics
// untouched (pinned by enroll_guided + student_driver suites, not here).
// NOTE (2026-09-10 `## Face-check single-shot`, tester-directed): mark/face
// is now single-shot — static oval + one look-at-the-camera line only (no
// bar, no beacon, no rotation copy). The mark/face pins below assert the
// new contract; the generic + enroll pins still assert the three-element
// uniformity.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/features/mark/face_check.dart';
import 'package:proximity_app/features/setup/enroll_capture.dart';
import 'package:proximity_app/features/setup/enroll_widgets.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';

Widget _app(Widget child) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: child),
    );

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

Widget _captureHarness({required EnrollmentController ctl}) => ProviderScope(
      overrides: [
        enrollmentControllerProvider.overrideWith((ref) => ctl),
        enrollSessionCameraProvider
            .overrideWithValue(FakeEnrollSessionCamera()),
        poseGateProvider.overrideWithValue(FakePoseGate()),
      ],
      child: MaterialApp(
        theme: proxLightTheme(),
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

void main() {
  group('single-oval geometry (pure)', () {
    test('guide rect is one centered oval inside the preview', () {
      const size = Size(400, 800);
      final oval = CaptureOverlay.guideRectFor(size);
      expect(oval.center, size.center(Offset.zero));
      expect(oval.width, lessThan(size.width));
      expect(oval.height, lessThan(size.height));
    });

    test('beacon point rides the oval perimeter', () {
      const size = Size(400, 800);
      final oval = CaptureOverlay.guideRectFor(size);
      for (final a in [0.0, 1.0, 2.5, -1.2, 3.14159]) {
        final p = CaptureOverlay.beaconPointFor(oval, a);
        // On-perimeter: normalized ellipse equation ≈ 1.
        final nx = (p.dx - oval.center.dx) / (oval.width / 2);
        final ny = (p.dy - oval.center.dy) / (oval.height / 2);
        expect(nx * nx + ny * ny, moreOrLessEquals(1.0, epsilon: 0.001));
      }
    });

    test('zero direction parks the beacon at the top', () {
      expect(CaptureOverlay.angleForDirection(Offset.zero),
          moreOrLessEquals(-3.141592653589793 / 2));
    });
  });

  group('CaptureOverlay three elements', () {
    testWidgets('bar + oval + one prompt, bar pinned top', (t) async {
      await t.pumpWidget(_app(const CaptureOverlay(
        progress: 0.4,
        currentAngle: 1,
        totalAngles: 5,
      )));
      await t.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.text(captureGuidePrompt), findsOneWidget);
      // Placement: bar above the oval center, prompt below it.
      final overlayBox =
          t.getRect(find.byType(CaptureOverlay).first);
      final barRect = t.getRect(find.byType(LinearProgressIndicator));
      final promptRect = t.getRect(find.text(captureGuidePrompt));
      expect(barRect.top - overlayBox.top, lessThanOrEqualTo(24));
      expect(barRect.center.dy, lessThan(overlayBox.center.dy));
      expect(promptRect.center.dy, greaterThan(overlayBox.center.dy));
      // Slim bar.
      expect(barRect.height, lessThanOrEqualTo(8));
      // Pill radius token on the bar clip, no raw colors anywhere new.
      final clip = t.widget<ClipRRect>(find.ancestor(
          of: find.byType(LinearProgressIndicator),
          matching: find.byType(ClipRRect)));
      expect(clip.borderRadius, ProxRadii.chipRadius);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('explicit status line replaces the default (still one)',
        (t) async {
      await t.pumpWidget(_app(const CaptureOverlay(
        progress: 0,
        currentAngle: 0,
        totalAngles: 5,
        statusLine: 'Hold still, retrying',
      )));
      await t.pump();
      expect(find.text('Hold still, retrying'), findsOneWidget);
      expect(find.text(captureGuidePrompt), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('reduced-motion beacon renders statically without crash',
        (t) async {
      await t.pumpWidget(MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: proxLightTheme(),
          home: const Scaffold(
            body: CaptureOverlay(
              progress: 0.2,
              currentAngle: 2,
              totalAngles: 5,
              sweepAngle: 2.0,
            ),
          ),
        ),
      ));
      await t.pump();
      // Sweep ignored under reduce-motion: static target prompt + bar stay.
      expect(find.text(captureGuidePrompt), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('mark/face consumer', () {
    test('signal mapping keeps mismatch out of this screen', () {
      expect(FaceCheckView.signalForNotice(''),
          CaptureSignal.neutral);
      expect(
          FaceCheckView.signalForNotice(
              'Scan unclear — retrying automatically… (1 of 2)'),
          CaptureSignal.inconclusive);
      expect(
          FaceCheckView.signalForNotice(
              'Could not read that scan — adjust light and try again.'),
          CaptureSignal.inconclusive);
    });

    testWidgets('fullscreen preview + overlay + one prompt + Scan fallback',
        (t) async {
      await t.pumpWidget(_app(FaceCheckView(
        faceNotice: '',
        canScan: true,
        onScan: () {},
      )));
      await t.pump();
      // Bare-surface preview Stack carrying the overlay (loose +
      // centered so the frame is never force-filled).
      final stack = find.byWidgetPredicate((w) =>
          w is Stack &&
          w.fit == StackFit.loose &&
          w.alignment == Alignment.center &&
          w.children.whereType<CaptureOverlay>().isNotEmpty);
      expect(stack, findsOneWidget);
      expect(find.byType(CaptureOverlay), findsOneWidget);
      // Single-shot (2026-09-10 `## Face-check single-shot`): no progress
      // bar, no rotation/beacon guidance — static oval + one look-at-the-
      // camera line only.
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text(faceCheckPrompt), findsOneWidget);
      expect(find.text(captureGuidePrompt), findsNothing);
      expect(find.textContaining('Rotate'), findsNothing);
      expect(find.textContaining('beacon'), findsNothing);
      // Scan fallback retained (host-owned zero-tap timing untouched).
      expect(find.text('Scan face'), findsOneWidget);
      // Clutter removed: no listening dot caption, no extra copy.
      expect(find.text('BLE listening'), findsNothing);
      expect(find.textContaining('Professor started marking'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('host notice becomes the one line when present', (t) async {
      const notice = 'Scan unclear — retrying automatically… (1 of 2)';
      await t.pumpWidget(_app(FaceCheckView(
        faceNotice: notice,
        canScan: true,
        onScan: () {},
      )));
      await t.pump();
      expect(find.text(notice), findsOneWidget);
      expect(find.text(faceCheckPrompt), findsNothing);
      expect(find.text(captureGuidePrompt), findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('enroll/capture consumer', () {
    testWidgets('fullscreen preview + overlay + single prompt, no Center',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      final stack = find.byWidgetPredicate((w) =>
          w is Stack &&
          w.fit == StackFit.loose &&
          w.alignment == Alignment.center &&
          w.children.whereType<CaptureOverlay>().isNotEmpty);
      expect(stack, findsOneWidget);
      expect(find.byType(CaptureOverlay), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // Exactly one prompt instance (overlay-owned; bottom bar empty).
      expect(find.text(enrollCapturePrompt), findsOneWidget);
      // Full-bleed: no Center wrapper between overlay and Expanded.
      expect(
          find.ancestor(
              of: find.byType(CaptureOverlay),
              matching: find.byType(Center)),
          findsNothing);
      expect(
          find.ancestor(
              of: find.byType(CaptureOverlay),
              matching: find.byType(Expanded)),
          findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      for (var i = 0; i < 15; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('open-capture'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
