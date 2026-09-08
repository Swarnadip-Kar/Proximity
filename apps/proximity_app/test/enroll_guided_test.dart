// Continuous-session enrollment contracts: pose-window math (pure),
// angle progress (dots + count + per-angle instruction), live-preview oval,
// gated advance (accept/reject/retake-without-loss), cancel, dispose
// safety, and fail-closed save.
//
// NOTE on the live preview: the camera plugin has no test double
// (availableCameras + permission channels throw in flutter_test), so the
// Stack(CameraPreview + FaceCaptureOvalOverlay) composition is verified
// on-device; CI pumps the overlay standalone (renders + repaints) and the
// full session below through the FakeEnrollSessionCamera + FakePoseGate
// seams (the real camera opens exactly once per session in production).
import 'dart:async';
import 'dart:io';

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
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/screens/face_capture.dart';

class _EnrollBoom extends FakeFaceVerifier {
  _EnrollBoom() : super(match: true, score: 0.9);
  @override
  Future<void> enroll(String faceId, List<String> imagePaths) async {
    throw StateError('No face detected');
  }
}

/// Pose gate that hangs until released (dispose-safety: an in-flight angle
/// check must never touch the screen after dispose).
class _HangingGate implements PoseGate {
  final completer = Completer<PoseDecision>();
  int calls = 0;
  @override
  Future<PoseDecision> checkSlot(String imagePath, String slot) async {
    calls++;
    return completer.future;
  }

  @override
  Future<void> close() async {}
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
        {required EnrollmentController ctl,
        EnrollSessionCamera? camera,
        PoseGate? gate}) =>
    ProviderScope(
      overrides: [
        enrollmentControllerProvider.overrideWith((ref) => ctl),
        enrollSessionCameraProvider
            .overrideWithValue(camera ?? FakeEnrollSessionCamera()),
        poseGateProvider.overrideWithValue(gate ?? FakePoseGate()),
      ],
      child: const MaterialApp(home: EnrollCaptureScreen()),
    );

/// Taps the primary capture button for the current angle.
Future<void> _tapCapture(WidgetTester t, String slot) async {
  final btn = find.ancestor(
    of: find.textContaining('Capture $slot still'),
    matching: find.byType(FilledButton),
  );
  await t.scrollUntilVisible(btn, 300,
      scrollable: find.byType(Scrollable).first);
  await t.pumpAndSettle();
  await t.tap(btn);
  await t.pumpAndSettle();
}

void main() {
  group('pose windows (pure, no native calls)', () {
    test('centre accepts near-frontal only', () {
      expect(EnrollPoseWindows.check('centre', 0, 0, 0).ok, isTrue);
      expect(EnrollPoseWindows.check('centre', 12, -12, 20).ok, isTrue);
      expect(EnrollPoseWindows.check('centre', 13, 0, 0).ok, isFalse);
      expect(EnrollPoseWindows.check('centre', 0, -13, 0).ok, isFalse);
    });

    test('side slots need a real turn, bounded each way', () {
      expect(EnrollPoseWindows.check('left', -20, 0, 0).ok, isTrue);
      expect(EnrollPoseWindows.check('right', 20, 0, 0).ok, isTrue);
      // Too frontal: not a left/right view.
      expect(EnrollPoseWindows.check('left', -3, 0, 0).ok, isFalse);
      expect(EnrollPoseWindows.check('right', 3, 0, 0).ok, isFalse);
      // Wrong direction never passes the opposite slot.
      expect(EnrollPoseWindows.check('left', 20, 0, 0).ok, isFalse);
      expect(EnrollPoseWindows.check('right', -20, 0, 0).ok, isFalse);
      // Too far reads as overshoot, not a pass.
      expect(EnrollPoseWindows.check('left', -40, 0, 0).ok, isFalse);
      expect(EnrollPoseWindows.check('right', 40, 0, 0).ok, isFalse);
      // Nodding during a turn is rejected (wrong axis).
      expect(EnrollPoseWindows.check('left', -20, 20, 0).ok, isFalse);
    });

    test('tilt slots need a slight nod, bounded each way', () {
      expect(EnrollPoseWindows.check('up', 0, 15, 0).ok, isTrue);
      expect(EnrollPoseWindows.check('down', 0, -15, 0).ok, isTrue);
      expect(EnrollPoseWindows.check('up', 0, 2, 0).ok, isFalse);
      expect(EnrollPoseWindows.check('down', 0, -2, 0).ok, isFalse);
      expect(EnrollPoseWindows.check('up', 0, -15, 0).ok, isFalse);
      expect(EnrollPoseWindows.check('down', 0, 15, 0).ok, isFalse);
      expect(EnrollPoseWindows.check('up', 0, 35, 0).ok, isFalse);
      // Sideways turn during a tilt is rejected (wrong axis).
      expect(EnrollPoseWindows.check('up', 20, 15, 0).ok, isFalse);
    });

    test('null euler, sideways roll and unknown slots fail closed', () {
      expect(EnrollPoseWindows.check('centre', null, 0, 0).ok, isFalse);
      expect(EnrollPoseWindows.check('centre', 0, null, 0).ok, isFalse);
      expect(EnrollPoseWindows.check('left', null, null, null).ok, isFalse);
      // Roll is advisory-tolerant inside the bound, gating outside it.
      expect(EnrollPoseWindows.check('centre', 0, 0, null).ok, isTrue);
      expect(EnrollPoseWindows.check('centre', 0, 0, 25).ok, isFalse);
      expect(EnrollPoseWindows.check('nope', 0, 0, 0).ok, isFalse);
    });
  });

  group('MlkitPoseGate fail-closed mapping (desktop-safe paths)', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('blank and missing stills are retries, never throws', () async {
      final gate = MlkitPoseGate();
      expect((await gate.checkSlot('', 'centre')).ok, isFalse);
      expect((await gate.checkSlot('   ', 'left')).ok, isFalse);
      expect(
          (await gate.checkSlot('/nonexistent/still.jpg', 'right')).ok,
          isFalse);
    });

    test('detector failure collapses to retry, never a throw', () async {
      // No ML Kit channel in flutter_test: processImage throws
      // MissingPluginException below the gate — the catch-all must map it
      // to a retry decision (session kept), never propagate.
      final f = File(
          '${Directory.systemTemp.path}/prox-pose-garbage-${DateTime.now().microsecondsSinceEpoch}.jpg');
      await f.writeAsBytes([0, 1, 2, 3]);
      try {
        final gate = MlkitPoseGate();
        final d = await gate.checkSlot(f.path, 'up');
        expect(d.ok, isFalse);
        expect(d.hint, isNotEmpty);
      } finally {
        if (await f.exists()) await f.delete();
      }
    });

    test('records-only devices throw before any channel call (L1)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final gate = MlkitPoseGate();
      expect(() => gate.checkSlot('a.jpg', 'centre'), throwsStateError);
    });
  });

  group('guided copy + dots (static contracts)', () {
    test('five instructions in slot order', () {
      expect(enrollAngleInstructions, hasLength(faceEnrollSlots.length));
      expect(faceEnrollSlots, ['centre', 'left', 'right', 'up', 'down']);
      expect(enrollAngleInstructions[0].title, 'Look straight');
      expect(enrollAngleInstructions[1].title, contains('left'));
      expect(enrollAngleInstructions[2].title, contains('right'));
      expect(enrollAngleInstructions[3].title, contains('up'));
      expect(enrollAngleInstructions[4].title, contains('down'));
    });

    testWidgets('dots label tracks captured count', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: EnrollAngleDots(done: 1, total: 5, current: 1)),
      ));
      expect(find.byKey(const ValueKey('angle-dot-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('angle-dot-4')), findsOneWidget);
      expect(
          find.bySemanticsLabel('Captured 1 of 5 angles'), findsOneWidget);
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

  group('EnrollCaptureScreen continuous session', () {
    testWidgets('camera opens once for the whole session', (t) async {
      final camera = FakeEnrollSessionCamera();
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, camera: camera));
      await t.pumpAndSettle();
      expect(camera.openCount, 1);
      // All 5 captures ride the same open session — no fall-out-and-back.
      for (final label in ['centre', 'left', 'right', 'up', 'down']) {
        await _tapCapture(t, label);
      }
      expect(camera.openCount, 1);
      expect(camera.closeCount, 0);
      expect(t.takeException(), isNull);
    });

    testWidgets('angle 1 shows dots + instruction + capture', (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await t.pumpAndSettle();
      expect(find.text('Angle 1 of 5'), findsOneWidget);
      expect(find.textContaining('Step 1: Look straight'), findsOneWidget);
      expect(find.textContaining('Capture centre still'), findsOneWidget);
      expect(find.text('Look straight'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('five gated captures advance to result', (t) async {
      final gate = FakePoseGate();
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, gate: gate));
      await t.pumpAndSettle();
      for (final label in ['centre', 'left', 'right', 'up', 'down']) {
        await _tapCapture(t, label);
      }
      // All 5 validated → auto-advance to the result step.
      expect(find.text('Save enrollment'), findsWidgets);
      // Every angle really went through the gate, in slot order.
      expect(
          gate.calls.map((c) => c.split(':').first),
          ['centre', 'left', 'right', 'up', 'down']);
      expect(t.takeException(), isNull);
    });

    testWidgets('pose reject keeps progress with a targeted hint',
        (t) async {
      final gate = FakePoseGate([
        const PoseDecision.retry(
            'Turn a little more to your left — keep both eyes visible.'),
      ]);
      final verifier = FakeFaceVerifier();
      final ctl = await _keyReady(verifier: verifier);
      await t.pumpWidget(
          _captureHarness(ctl: ctl, gate: gate));
      await t.pumpAndSettle();
      await _tapCapture(t, 'centre');
      // Rejected: still on angle 1, targeted hint shown, gallery untouched.
      expect(find.text('Angle 1 of 5'), findsOneWidget);
      expect(find.textContaining('a little more to your left'),
          findsOneWidget);
      expect(verifier.calls.where((c) => c.startsWith('enroll:')), isEmpty);
      // Retry accepts (fallback) and advances without losing anything.
      await _tapCapture(t, 'centre');
      expect(find.text('Angle 2 of 5'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retake'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('retake re-captures one slot without losing the rest',
        (t) async {
      var n = 0;
      final camera = FakeEnrollSessionCamera();
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, camera: camera));
      await t.pumpAndSettle();
      await _tapCapture(t, 'centre');
      expect(find.text('Angle 2 of 5'), findsOneWidget);
      // In-session retake of the accepted slot (no camera round-trip).
      n = camera.captures;
      final retake = find.widgetWithText(TextButton, 'Retake');
      await t.scrollUntilVisible(retake, 300,
          scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      await t.tap(retake);
      await t.pumpAndSettle();
      expect(camera.captures, n + 1);
      expect(camera.openCount, 1);
      expect(find.text('Angle 2 of 5'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('blank still keeps progress with a notice', (t) async {
      final camera = FakeEnrollSessionCamera([StateError('blank')]);
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, camera: camera));
      await t.pumpAndSettle();
      await _tapCapture(t, 'centre');
      expect(find.text('Angle 1 of 5'), findsOneWidget);
      expect(find.textContaining('blank'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('controller error shows verbatim + Save stays blocked',
        (t) async {
      final ctl = await _keyReady(verifier: _EnrollBoom());
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await t.pumpAndSettle();
      for (final label in ['centre', 'left', 'right', 'up', 'down']) {
        await _tapCapture(t, label);
      }
      expect(find.textContaining('No face detected'), findsOneWidget);
      // Still on capture (no auto-advance), progress kept for retake.
      expect(find.text('5 of 5 captured — review below'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retake'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('cancel disposes the session and enrolls nothing',
        (t) async {
      final camera = FakeEnrollSessionCamera();
      final verifier = FakeFaceVerifier();
      final ctl = await _keyReady(verifier: verifier);
      await t.pumpWidget(
          _captureHarness(ctl: ctl, camera: camera));
      await t.pumpAndSettle();
      await _tapCapture(t, 'centre');
      expect(find.text('Angle 2 of 5'), findsOneWidget);
      final cancel = find.widgetWithText(OutlinedButton, 'Cancel');
      await t.scrollUntilVisible(cancel, 300,
          scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      await t.tap(cancel);
      await t.pumpAndSettle();
      // Popped (session screen gone), camera closed, gallery untouched.
      expect(find.textContaining('Angle'), findsNothing);
      expect(camera.closeCount, 1);
      expect(verifier.calls.where((c) => c.startsWith('enroll:')), isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('in-flight angle check after dispose never touches UI',
        (t) async {
      final gate = _HangingGate();
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, gate: gate));
      await t.pumpAndSettle();
      final btn = find.ancestor(
        of: find.textContaining('Capture centre still'),
        matching: find.byType(FilledButton),
      );
      await t.scrollUntilVisible(btn, 300,
          scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      await t.tap(btn);
      await t.pump(); // capture fired, validation now hangs in the gate
      expect(gate.calls, 1);
      // Dispose mid-validation, then let the check complete late.
      await t.pumpWidget(const MaterialApp(home: Scaffold()));
      gate.completer.complete(const PoseDecision.ok());
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('camera open failure is fail-closed, never a throw',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(
          ctl: ctl, camera: FakeEnrollSessionCamera([], true)));
      await t.pumpAndSettle();
      expect(find.textContaining('Camera unavailable'), findsWidgets);
      expect(find.text('Angle 1 of 5'), findsOneWidget);
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
