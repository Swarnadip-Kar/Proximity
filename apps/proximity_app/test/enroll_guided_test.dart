// Guided-enrollment widget contracts: angle progress (dots + count +
// per-angle instruction), oval illustration prompt, blocked (desktop),
// blank-still notice, controller-error notice, and the standalone camera
// oval overlay.
//
// NOTE on the live preview Stack: the camera plugin has no test double
// (availableCameras + permission channels throw in flutter_test), so the
// Stack(CameraPreview + FaceCaptureOvalOverlay) composition is verified
// on-device; CI pumps the overlay standalone (renders + repaints) and the
// full guided flow below through the FakeStillCapturer seam.
import 'package:flutter/foundation.dart';
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
import 'package:proximity_app/screens/face_capture.dart';

class _EnrollBoom extends FakeFaceVerifier {
  _EnrollBoom() : super(match: true, score: 0.9);
  @override
  Future<void> enroll(String faceId, List<String> imagePaths) async {
    throw StateError('No face detected');
  }
}

Future<EnrollmentController> _keyReady(
    {FaceVerifier? verifier, InMemoryDeviceStore? store}) async {
  final ctl = EnrollmentController(
    auth: FakeAuthService(const SignedAccount(
        email: 's@x.in', displayName: 'S', uid: 'u1')),
    store: store ?? InMemoryDeviceStore(),
    verifier: verifier ?? FakeFaceVerifier(),
    deviceKey: FakeDeviceKey(),
  );
  await ctl.signIn();
  await ctl.generateKey();
  return ctl;
}

Widget _captureHarness(
        {required EnrollmentController ctl, StillCapturer? capturer}) =>
    ProviderScope(
      overrides: [
        enrollmentControllerProvider.overrideWith((ref) => ctl),
        stillCapturerProvider
            .overrideWithValue(capturer ?? const FakeStillCapturer()),
      ],
      child: const MaterialApp(home: EnrollCaptureScreen()),
    );

void main() {
  group('guided copy + dots (static contracts)', () {
    test('three instructions in slot order', () {
      expect(enrollAngleInstructions, hasLength(faceEnrollSlots.length));
      expect(enrollAngleInstructions[0].title, 'Look straight');
      expect(enrollAngleInstructions[1].title, contains('left'));
      expect(enrollAngleInstructions[2].title, contains('right'));
    });

    testWidgets('dots label tracks captured count', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: EnrollAngleDots(done: 1, total: 3, current: 1)),
      ));
      expect(find.byKey(const ValueKey('angle-dot-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('angle-dot-2')), findsOneWidget);
      expect(
          find.bySemanticsLabel('Captured 1 of 3 angles'), findsOneWidget);
    });

    testWidgets('camera oval overlay renders + repaints', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: FaceCaptureOvalOverlay(progress: 0)),
      ));
      expect(find.byType(CustomPaint), findsWidgets);
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: FaceCaptureOvalOverlay(progress: 0.5)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('EnrollCaptureScreen guided flow', () {
    testWidgets('angle 1 shows dots + instruction + oval prompt', (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await t.pumpAndSettle();
      expect(find.text('Angle 1 of 3'), findsOneWidget);
      expect(find.textContaining('Step 1: Look straight'), findsOneWidget);
      expect(find.text('Look straight'), findsWidgets);
      expect(find.textContaining('Capture centre still'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('per-angle captures advance to result', (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await t.pumpAndSettle();
      for (final label in ['centre', 'left', 'right']) {
        final btn = find.ancestor(
          of: find.textContaining('Capture $label still'),
          matching: find.byType(FilledButton),
        );
        await t.scrollUntilVisible(btn, 300,
            scrollable: find.byType(Scrollable).first);
        await t.pumpAndSettle();
        await t.tap(btn);
        await t.pumpAndSettle();
      }
      // All 3 validated → auto-advance to the result step.
      expect(find.text('Save enrollment'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('retake appears per captured slot', (t) async {
      var n = 0;
      final capturer = FakeStillCapturer((_) => ['still-${n++}.jpg']);
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, capturer: capturer));
      await t.pumpAndSettle();
      final retakeBtn = find.ancestor(
        of: find.textContaining('Capture centre still'),
        matching: find.byType(FilledButton),
      );
      await t.scrollUntilVisible(retakeBtn, 300,
          scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      await t.tap(retakeBtn);
      await t.pumpAndSettle();
      expect(find.text('Angle 2 of 3'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retake'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('blank still keeps progress with a notice', (t) async {
      final capturer = FakeStillCapturer((_) => ['']);
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, capturer: capturer));
      await t.pumpAndSettle();
      final blankBtn = find.ancestor(
        of: find.textContaining('Capture centre still'),
        matching: find.byType(FilledButton),
      );
      await t.scrollUntilVisible(blankBtn, 300,
          scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      await t.tap(blankBtn);
      await t.pumpAndSettle();
      expect(find.text('Angle 1 of 3'), findsOneWidget);
      expect(find.textContaining('came out blank'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('controller error shows verbatim + Save stays blocked',
        (t) async {
      final ctl = await _keyReady(verifier: _EnrollBoom());
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await t.pumpAndSettle();
      for (final label in ['centre', 'left', 'right']) {
        final btn = find.ancestor(
          of: find.textContaining('Capture $label still'),
          matching: find.byType(FilledButton),
        );
        await t.scrollUntilVisible(btn, 300,
            scrollable: find.byType(Scrollable).first);
        await t.pumpAndSettle();
        await t.tap(btn);
        await t.pumpAndSettle();
      }
      expect(find.textContaining('No face detected'), findsOneWidget);
      // Still on capture (no auto-advance), progress kept for retake.
      expect(find.text('3 of 3 captured — review below'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retake'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('records-only device sees the blocked card', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await t.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      expect(find.textContaining('needs the mobile app'), findsOneWidget);
      expect(find.textContaining('Capture'), findsNothing);
      expect(t.takeException(), isNull);
    });
  });
}
