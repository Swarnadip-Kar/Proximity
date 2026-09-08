// Continuous-session enrollment contracts: pose-window math (pure),
// overlay-only preview composition at true ratio, no-tap auto-capture
// advance (accept/reject/auto-retry with progress kept), cancel, dispose
// safety, and fail-closed save.
//
// NOTE on the live preview: the camera plugin has no test double
// (availableCameras + permission channels throw in flutter_test), so the
// Stack(CameraPreview + FaceCaptureOvalOverlay) composition is verified
// on-device; CI pumps the placeholder Stack (same construction) and the
// full session below through the FakeEnrollSessionCamera + FakePoseGate
// seams (the real camera opens exactly once per session in production).
//
// NOTE on the clock: the auto-capture loop always has its next one-shot
// beat scheduled while running, so tests drive it with bounded
// [_pumpUntil]/[_drain] pumps — never pumpAndSettle mid-loop (it would
// time out on the live loop instead of failing loudly).
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
import 'package:proximity_app/widgets/prox_cards.dart';

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

/// Pushed-route harness (production shape: capture is always pushed onto
/// the bundle flow, never root — a root pop is a framework no-op, so a
/// bare home: harness could never exercise Cancel-dispose).
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

/// Pushes the session and lets the camera open (loop still in its initial
/// beat afterwards — deterministic overlay state). Two stepped pumps: the
/// pushed route needs a second frame to materialize in the test binding.
Future<void> _openSession(WidgetTester t) async {
  await t.tap(find.text('open-capture'));
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 300));
}

/// Clock driver for the auto-capture loop: bounded pumps that fail loudly
/// if [f] never appears (never pumpAndSettle mid-loop — the loop always
/// has its next beat scheduled while running).
Future<void> _pumpUntil(WidgetTester t, Finder f, {int ticks = 60}) async {
  for (var i = 0; i < ticks; i++) {
    if (f.evaluate().isNotEmpty) return;
    await t.pump(const Duration(milliseconds: 200));
  }
  fail('auto-capture loop never settled: $f');
}

/// Lets pending one-shot beats and pop transitions finish after
/// cancel/dispose so teardown never sees a live timer. Stepped (never one
/// big pump — transitions need successive frames). The loop schedules
/// nothing further once done.
Future<void> _drain(WidgetTester t) async {
  for (var i = 0; i < 15; i++) {
    await t.pump(const Duration(milliseconds: 200));
  }
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
    testWidgets('preview is overlay-only at self-sized ratio', (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      // Camera open, loop still in its initial beat (600ms) — the overlay
      // deterministically names angle 1.
      await _openSession(t);
      // Overlay ONLY in the preview Stack: dots + one instruction line +
      // oval. No cards, no capture buttons, no slot rows, no progress bar.
      expect(find.byType(EnrollAngleDots), findsOneWidget);
      expect(find.text('Look straight'), findsWidgets);
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      expect(find.byType(ProxCard), findsNothing);
      expect(find.text('Retake'), findsNothing);
      expect(find.textContaining('Capture'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      // The overlay never affects preview layout: it hangs off Positioned
      // + IgnorePointer inside the Stack (ancestor existence; Scaffold
      // internals own other IgnorePointers, so this asserts presence).
      expect(
          find.ancestor(
              of: find.byType(EnrollAngleDots),
              matching: find.byType(IgnorePointer)),
          findsWidgets);
      expect(
          find.ancestor(
              of: find.byType(EnrollAngleDots),
              matching: find.byType(Positioned)),
          findsOneWidget);
      // …and the preview area is constraint-loose (Expanded + Center, the
      // certified FaceCaptureScreen construction — CameraPreview, an
      // AspectRatio internally, sizes itself), never a fixed-height box.
      expect(
          find.ancestor(
              of: find.byType(FaceCaptureOvalOverlay),
              matching: find.byType(Center)),
          findsOneWidget);
      expect(
          find.ancestor(
              of: find.byType(FaceCaptureOvalOverlay),
              matching: find.byType(Expanded)),
          findsOneWidget);
      expect(
          find.byWidgetPredicate(
              (w) => w is SizedBox && w.height == 300),
          findsNothing);
      expect(t.takeException(), isNull);
      // Drain: cancel the live loop (pops back to the launcher), then
      // let the beat fire post-dispose.
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(find.text('open-capture'), findsOneWidget);
      expect(find.byType(EnrollCaptureScreen), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('no taps: auto-capture advances all 5 gated angles',
        (t) async {
      final camera = FakeEnrollSessionCamera();
      final gate = FakePoseGate();
      final ctl = await _keyReady();
      await t.pumpWidget(
          _captureHarness(ctl: ctl, camera: camera, gate: gate));
      await _openSession(t);
      // No capture buttons exist at any point — the loop drives itself.
      expect(find.byType(FilledButton), findsNothing);
      // All 5 validate → auto-advance to the result step, one camera open.
      await _pumpUntil(t, find.text('Save enrollment'));
      // Result screen is static: settle its entrance before asserting.
      await t.pumpAndSettle();
      expect(camera.openCount, 1);
      expect(camera.closeCount, 0);
      // Every angle really went through the gate, in slot order.
      expect(
          gate.calls.map((c) => c.split(':').first),
          ['centre', 'left', 'right', 'up', 'down']);
      expect(t.takeException(), isNull);
    });

    testWidgets('pose reject hints then auto-retries, progress kept',
        (t) async {
      final gate = FakePoseGate([
        const PoseDecision.retry(
            'Turn a little more to your left — keep both eyes visible.'),
      ]);
      final verifier = FakeFaceVerifier();
      final ctl = await _keyReady(verifier: verifier);
      await t.pumpWidget(
          _captureHarness(ctl: ctl, gate: gate));
      await _openSession(t);
      // Rejected: the hint becomes the overlay line, gallery untouched.
      await _pumpUntil(
          t, find.textContaining('a little more to your left'));
      expect(verifier.calls.where((c) => c.startsWith('enroll:')), isEmpty);
      // Auto-retry accepts (fallback) and the session completes — centre
      // went through the gate twice, nothing lost.
      await _pumpUntil(t, find.text('Save enrollment'));
      await t.pumpAndSettle();
      expect(
          gate.calls.map((c) => c.split(':').first),
          ['centre', 'centre', 'left', 'right', 'up', 'down']);
      expect(t.takeException(), isNull);
    });

    testWidgets('blank capture auto-retries the slot', (t) async {
      final camera = FakeEnrollSessionCamera([StateError('blank')]);
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, camera: camera));
      await _openSession(t);
      await _pumpUntil(t, find.textContaining('blank'));
      // One wasted still, then the session completes on its own.
      await _pumpUntil(t, find.text('Save enrollment'));
      await t.pumpAndSettle();
      expect(camera.captures, 6);
      expect(t.takeException(), isNull);
    });

    testWidgets('controller error offers Try again, save stays blocked',
        (t) async {
      final ctl = await _keyReady(verifier: _EnrollBoom());
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      await _pumpUntil(t, find.widgetWithText(FilledButton, 'Try again'));
      expect(find.textContaining('No face detected'), findsOneWidget);
      // Still on capture (no auto-advance), all 5 accepted stills kept.
      expect(find.text('Save enrollment'), findsNothing);
      // Retrying a poisoned gallery fails closed again — never a save.
      await t.tap(find.widgetWithText(FilledButton, 'Try again'));
      await _pumpUntil(t, find.widgetWithText(FilledButton, 'Try again'));
      expect(find.text('Save enrollment'), findsNothing);
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('cancel mid-loop disposes the session, enrolls nothing',
        (t) async {
      final camera = FakeEnrollSessionCamera();
      final verifier = FakeFaceVerifier();
      final ctl = await _keyReady(verifier: verifier);
      await t.pumpWidget(
          _captureHarness(ctl: ctl, camera: camera));
      await _openSession(t);
      // Wait for the first accept (dots semantics), then cancel.
      await _pumpUntil(
          t, find.bySemanticsLabel('Captured 1 of 5 angles'));
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      // Popped back to the launcher, camera closed, gallery untouched.
      expect(find.text('open-capture'), findsOneWidget);
      expect(find.byType(EnrollCaptureScreen), findsNothing);
      expect(camera.closeCount, 1);
      expect(verifier.calls.where((c) => c.startsWith('enroll:')), isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('in-flight angle check after dispose never touches UI',
        (t) async {
      final gate = _HangingGate();
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, gate: gate));
      await _openSession(t);
      // Initial beat + capture fire, validation now hangs in the gate.
      await _pumpUntil(t, find.text('Checking angle…'));
      expect(gate.calls, 1);
      // Dispose mid-validation, then let the check complete late.
      await t.pumpWidget(const MaterialApp(home: Scaffold()));
      gate.completer.complete(const PoseDecision.ok());
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('camera open failure is fail-closed, never a throw',
        (t) async {
      final camera = FakeEnrollSessionCamera([], true);
      final ctl = await _keyReady();
      await t.pumpWidget(
          _captureHarness(ctl: ctl, camera: camera));
      await _openSession(t);
      await t.pumpAndSettle();
      // Message replaces the preview (no loop, no captures, no throw).
      expect(find.textContaining('did not start'), findsWidgets);
      expect(camera.captures, 0);
      expect(find.byType(EnrollCaptureScreen), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('records-only device sees the blocked card', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      await t.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      expect(find.textContaining('needs the mobile app'), findsOneWidget);
      expect(find.textContaining('Capture'), findsNothing);
      expect(t.takeException(), isNull);
    });
  });
}
