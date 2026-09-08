// Continuous-session enrollment contracts: pose windows, bucket
// classification, dot anchors (all pure), preview parity with the 5186c65
// original (source-to-source), overlay-only composition, bucket-fill
// advance with latched guidance (no flicker), stale eviction,
// cancel/dispose safety, fail-closed save.
//
// Guidance model (Apple Face ID + Tobii "follow the dot"): every still
// classifies into ANY matching unfilled bucket; dot + line name the
// latched target, moving ONLY on fill or eviction — never on per-frame
// output. Camera plugin has no test double, so the live CameraPreview
// composition is verified on-device; CI drives the placeholder Stack
// (same shape) through the FakeEnrollSessionCamera + FakePoseGate seams.
// Clock: the loop always has its next one-shot beat due — drive it with
// bounded [_pumpUntil]/[_drain], never pumpAndSettle mid-loop.
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

/// Pose gate that hangs until released (dispose-safety: an in-flight pose
/// read must never touch the screen after dispose).
class _HangingGate implements PoseGate {
  final completer = Completer<PoseReading?>();
  int reads = 0;
  @override
  Future<PoseDecision> checkSlot(String imagePath, String slot) async =>
      const PoseDecision.ok();

  @override
  Future<PoseReading?> readPose(String imagePath) async {
    reads++;
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
      expect(() => gate.readPose('a.jpg'), throwsStateError);
    });

    test('readPose maps unreadable stills to null, never throws', () async {
      final gate = MlkitPoseGate();
      expect(await gate.readPose(''), isNull);
      expect(await gate.readPose('   '), isNull);
      expect(await gate.readPose('/nonexistent/still.jpg'), isNull);
      // No ML Kit channel in flutter_test: the detector throw collapses
      // to null (the loop wastes the beat silently), never propagates.
      final f = File(
          '${Directory.systemTemp.path}/prox-pose-garbage-${DateTime.now().microsecondsSinceEpoch}.jpg');
      await f.writeAsBytes([0, 1, 2, 3]);
      try {
        expect(await gate.readPose(f.path), isNull);
      } finally {
        if (await f.exists()) await f.delete();
      }
    });
  });

  group('bucket classification (pure, no native calls)', () {
    const empty = <String>{};
    test('canonical views fill their own bucket first', () {
      expect(
          EnrollBucketFill.classifyInto(0, 0, 0, empty), 'centre');
      expect(
          EnrollBucketFill.classifyInto(-20, 0, 0, empty), 'left');
      expect(
          EnrollBucketFill.classifyInto(20, 0, 0, empty), 'right');
      expect(
          EnrollBucketFill.classifyInto(0, 15, 0, empty), 'up');
      expect(
          EnrollBucketFill.classifyInto(0, -15, 0, empty), 'down');
    });

    test('overlap resolves by slot priority, filled buckets skipped', () {
      // yaw -10 sits in both centre (±12) and left (−35…−8) windows:
      // centre wins while unfilled (it IS a valid frontal template)…
      expect(EnrollBucketFill.classifyInto(-10, 0, 0, empty), 'centre');
      // …then the same reading fills left once centre is taken.
      expect(EnrollBucketFill.classifyInto(-10, 0, 0, {'centre'}), 'left');
      // A reading matching only filled buckets fills nothing (wasted
      // still — the loop stays silent, guidance never moves).
      expect(
          EnrollBucketFill.classifyInto(
              0, 0, 0, {'centre', 'left', 'right', 'up'}),
          isNull);
    });

    test('unreadable and out-of-window readings fill nothing', () {
      expect(EnrollBucketFill.classifyInto(null, 0, 0, empty), isNull);
      expect(EnrollBucketFill.classifyInto(0, null, 0, empty), isNull);
      expect(EnrollBucketFill.classifyInto(null, null, null, empty), isNull);
      // Overshoot past every window (too far left) is wasted, not forced.
      expect(EnrollBucketFill.classifyInto(-40, 0, 0, empty), isNull);
      expect(EnrollBucketFill.classifyInto(0, 35, 0, empty), isNull);
      // Nothing left to fill.
      expect(
          EnrollBucketFill.classifyInto(
              0, 0, 0, {'centre', 'left', 'right', 'up', 'down'}),
          isNull);
    });
  });

  group('guide-dot anchors (pure)', () {
    test('turns sit on the rim toward the turn, centre sits centred', () {
      expect(guideDotUnit('left'), const Offset(-1, 0));
      expect(guideDotUnit('right'), const Offset(1, 0));
      expect(guideDotUnit('up'), const Offset(0, -1));
      expect(guideDotUnit('down'), const Offset(0, 1));
      expect(guideDotUnit('centre'), Offset.zero);
      expect(guideDotUnit('nope'), Offset.zero);
    });
  });

  group('preview parity with the 5186c65 original', () {
    // The ratio-critical lines of the FaceCaptureScreen preview block,
    // byte-identical in the enrollment session (see the provenance note
    // in enroll_capture.dart). If this fails, the preview construction
    // drifted from the certified original — do not "fix" the test, fix
    // the block. Paths are package-relative (flutter test runs at the
    // package root). The CameraPreview line carries 2sp extra from the
    // fake-guard `if` (documented delta b), so it is pinned unindented.
    const originalLines = [
      '          Expanded(',
      '            child: Center(',
      '                  ? Padding(',
      '                      padding: const EdgeInsets.all(24),',
      '                      ? const CircularProgressIndicator()',
      '                          fit: StackFit.expand,',
      'CameraPreview(ctl)',
      '                            // The oval ACTUALLY renders on the preview: this',
      '                            // overlay is inside the preview Stack (not beside',
      '                            // it), pointer-transparent, repainting per shot.',
    ];

    test('ratio-critical lines survive verbatim, in order', () {
      final session = File(
              'lib/features/enrollment/enroll_capture.dart')
          .readAsStringSync();
      var from = 0;
      for (final line in originalLines) {
        final at = session.indexOf(line, from);
        expect(at, isNot(-1), reason: 'missing verbatim line: $line');
        from = at + line.length;
      }
    });

    test('exactly the three documented deltas, nothing else', () {
      final session = File(
              'lib/features/enrollment/enroll_capture.dart')
          .readAsStringSync();
      // (a) three-state message instead of the single status…
      expect(session.contains('child: Text(_status,'), isFalse);
      expect(session.contains('previewMessage'), isTrue);
      // (b) spinner branch restored verbatim, but its CONDITION now keys
      // on opening — the original `ctl == null … ? spinner` two-liner is
      // gone (that exact condition survives only in the camera seam's
      // null-safe accessor, which short-circuits before any dereference).
      expect(session.contains('const CircularProgressIndicator()'), isTrue);
      expect(
          session.contains('!ctl.value.isInitialized\n'
              '                      ? const CircularProgressIndicator()'),
          isFalse);
      expect(session.contains('FaceOval('), isTrue);
      // (c) ONE Positioned overlay child + dotUnit on the oval…
      expect('Positioned('.allMatches(session).length, 1);
      expect(session.contains('dotUnit:'), isTrue);
      // …and the original single-status/progress expressions are gone.
      expect(session.contains('_taken / widget.captures'), isFalse);
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

    testWidgets('camera oval overlay renders + repaints (dot included)',
        (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: FaceCaptureOvalOverlay(progress: 0)),
      ));
      expect(find.byType(CustomPaint), findsWidgets);
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: FaceCaptureOvalOverlay(
                progress: 0.5, dotUnit: Offset(1, 0))),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    test('fake gate cycles the five canonical views unscripted', () async {
      // No readings scripted: the cycle drives a full bucket set in
      // slot-priority order through classifyInto — the e2e default.
      final gate = FakePoseGate();
      final filled = <String>{};
      for (var i = 0; i < 5; i++) {
        final r = await gate.readPose('still-$i.jpg');
        final slot = EnrollBucketFill.classifyInto(
            r!.yaw, r.pitch, r.roll, filled);
        expect(slot, faceEnrollSlots[i]);
        filled.add(slot!);
      }
      expect(filled, faceEnrollSlots.toSet());
    });
  });

  group('EnrollCaptureScreen continuous session', () {
    testWidgets('preview is overlay-only at self-sized ratio', (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      // Camera open, loop still in its initial beat (600ms) — the overlay
      // deterministically names the latched target (centre first).
      await _openSession(t);
      // Overlay ONLY in the preview Stack: dots + one stable imperative +
      // oval. No cards, no buttons, no narration of checker internals.
      expect(find.byType(EnrollAngleDots), findsOneWidget);
      expect(find.text('Look straight'), findsWidgets);
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      expect(find.byType(ProxCard), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      // No checker-state narration anywhere user-facing (BleLog only).
      expect(find.text('Hold still…'), findsNothing);
      expect(find.text('Checking angle…'), findsNothing);
      expect(find.text('Checking…'), findsNothing);
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

    testWidgets('no taps: buckets fill in gate order, one camera open',
        (t) async {
      final camera = FakeEnrollSessionCamera();
      final gate = FakePoseGate();
      final ctl = await _keyReady();
      await t.pumpWidget(
          _captureHarness(ctl: ctl, camera: camera, gate: gate));
      await _openSession(t);
      // All 5 buckets validate → auto-advance to the result step.
      await _pumpUntil(t, find.text('Save enrollment'));
      // Result screen is static: settle its entrance before asserting.
      await t.pumpAndSettle();
      expect(camera.openCount, 1);
      expect(camera.closeCount, 0);
      // One pose read per still, nothing else touched the gate.
      expect(gate.readCalls, hasLength(5));
      expect(gate.calls, isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('alternating classifications never move latched guidance',
        (t) async {
      // Stills arrive left/right/left/right… while the target is centre:
      // buckets fill opportunistically, but the dot + line stay on centre
      // until CENTRE fills — per-frame output never steers guidance.
      const left = PoseReading(yaw: -20, pitch: 0, roll: 0);
      const right = PoseReading(yaw: 20, pitch: 0, roll: 0);
      final gate = FakePoseGate([], const PoseDecision.ok(), [left, right]);
      final camera = FakeEnrollSessionCamera();
      final verifier = FakeFaceVerifier();
      final ctl = await _keyReady(verifier: verifier);
      await t.pumpWidget(_captureHarness(
          ctl: ctl, gate: gate, camera: camera));
      await _openSession(t);
      // Two buckets filled by "wrong"-order stills — guidance unmoved.
      await _pumpUntil(
          t, find.bySemanticsLabel('Captured 2 of 5 angles'));
      expect(find.text('Look straight'), findsWidgets);
      expect(find.text('Turn slightly left'), findsNothing);
      expect(find.text('Turn slightly right'), findsNothing);
      expect(verifier.calls.where((c) => c.startsWith('enroll:')), isEmpty);
      // The session still completes (centre fills from the cycle next).
      await _pumpUntil(t, find.text('Save enrollment'));
      await t.pumpAndSettle();
      expect(camera.captures, 7);
      expect(t.takeException(), isNull);
    });

    testWidgets('stale target evicts the dot, bucket still fills later',
        (t) async {
      // 31 wasted stills (matching nothing) with centre missing: the dot
      // moves on to left WITHOUT accepting anything — eviction, not a
      // pass. Then the cycle's centre still fills centre opportunistically.
      final gate = FakePoseGate(
          [],
          const PoseDecision.ok(),
          List.filled(
              31, const PoseReading(yaw: -40, pitch: 0, roll: 0)));
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, gate: gate));
      await _openSession(t);
      await _pumpUntil(t, find.text('Turn slightly left'), ticks: 250);
      // Eviction accepted nothing: dots still empty, gallery untouched.
      expect(
          find.bySemanticsLabel('Captured 0 of 5 angles'), findsOneWidget);
      // …and the evicted bucket fills the moment a matching still arrives.
      await _pumpUntil(t, find.text('Save enrollment'), ticks: 120);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('blank capture stays silent, slot fills next still',
        (t) async {
      final camera = FakeEnrollSessionCamera([StateError('blank')]);
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, camera: camera));
      await _openSession(t);
      // First fill arrives with no error text ever shown (silent retry).
      await _pumpUntil(
          t, find.bySemanticsLabel('Captured 1 of 5 angles'));
      expect(find.textContaining('blank'), findsNothing);
      expect(find.byType(EnrollNotice), findsNothing);
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
      // Wait for the first fill (dots semantics), then cancel.
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

    testWidgets('in-flight pose read after dispose never touches UI',
        (t) async {
      final gate = _HangingGate();
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, gate: gate));
      await _openSession(t);
      // Initial beat + capture fire, the pose read now hangs in the gate.
      for (var i = 0; i < 30 && gate.reads < 1; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(gate.reads, 1);
      // Dispose mid-read, then let the read complete late.
      await t.pumpWidget(const MaterialApp(home: Scaffold()));
      gate.completer.complete(const PoseReading(yaw: 0, pitch: 0, roll: 0));
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
