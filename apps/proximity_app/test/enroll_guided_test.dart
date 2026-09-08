// Continuous-session enrollment contracts: pose windows, bucket
// classification (pure), preview parity with the 5186c65 original
// (source lines + ancestor chain), overlay-only composition, bucket-fill
// advance under one static prompt (no flicker), sweep glow,
// cancel/dispose safety, fail-closed save.
//
// Guidance model (Apple Face ID + Tobii "follow the target"): every still
// classifies into ANY matching unfilled bucket; rim sweep + one static
// prompt guide, progress dots report. Nothing user-facing ever narrates
// checker state. Camera plugin has no test double, so the live
// CameraPreview composition is verified on-device; CI drives the
// placeholder Stack (same shape) through the FakeEnrollSessionCamera +
// FakePoseGate seams. Clock: capture beats are one-shot, the sweep glow
// is periodic — drive tests with bounded [_pumpUntil]/[_drain], never
// pumpAndSettle with the session mounted.
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

    test('records-only devices throw before any channel call (L1)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final gate = MlkitPoseGate();
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

    test('exactly the four documented deltas, nothing else', () {
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
      // (c) TWO Positioned overlay children + sweep params on the oval, and
      // no trace of the removed green dot: dots (top) + save-error toast
      // (bottom, saveError-gated) — both positioned/paint-only, so overlay
      // count stays pinned and no inline copy ever sneaks over the feed…
      expect('Positioned('.allMatches(session).length, 2);
      expect(session.contains('if (saveError)'), isTrue);
      expect(session.contains('sweepAngle:'), isTrue);
      expect(session.contains('sweepSpan:'), isTrue);
      expect(session.contains('dotUnit'), isFalse);
      expect(session.contains('guideDotUnit'), isFalse);
      // …and the original single-status/progress expressions are gone.
      expect(session.contains('_taken / widget.captures'), isFalse);
      // …and no per-angle titles / narration strings survive anywhere.
      expect(session.contains('enrollAngleInstructions'), isFalse);
      expect(session.contains('Hold still'), isFalse);
      expect(session.contains('Checking angle'), isFalse);
    });
  });

  group('guided copy + dots (static contracts)', () {
    test('exactly one prompt, pinned verbatim', () {
      expect(enrollCapturePrompt,
          'Rotate your face slowly, following the glow.');
      expect(faceEnrollSlots, ['centre', 'left', 'right', 'up', 'down']);
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

    testWidgets('camera oval overlay renders + repaints (sweep included)',
        (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: FaceCaptureOvalOverlay(progress: 0)),
      ));
      expect(find.byType(CustomPaint), findsWidgets);
      // Animated sweep segment…
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: FaceCaptureOvalOverlay(
                progress: 0.5, sweepAngle: 1.0)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      // …advancing sweep repaints…
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: FaceCaptureOvalOverlay(
                progress: 0.5, sweepAngle: 2.0)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      // …and the reduced-motion steady full-rim glow renders too.
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FaceCaptureOvalOverlay(
                progress: 1.0,
                sweepAngle: 0.0,
                sweepSpan: 2 * 3.141592653589793)),
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
    testWidgets('preview is overlay-only: dots, prompt once, zero jargon',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      // Camera open, loop still in its initial beat (600ms).
      await _openSession(t);
      // Overlay ONLY in the preview Stack: dots + oval. The single static
      // prompt lives in the bottom bar (area constancy, see chain test).
      expect(find.byType(EnrollAngleDots), findsOneWidget);
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      expect(find.byType(ProxCard), findsNothing);
      // No VISIBLE buttons mid-flow (the boundary-parity reservation keeps
      // one hidden FilledButton to hold the original bottom-slot height —
      // invisible, no semantics, no interaction — so it never counts here).
      final filled = find.byType(FilledButton);
      if (filled.evaluate().isNotEmpty) {
        for (final e in filled.evaluate()) {
          var hidden = false;
          e.visitAncestorElements((a) {
            final w = a.widget;
            if (w is Visibility && !w.visible && w.maintainSize) {
              hidden = true;
            }
            return true;
          });
          expect(hidden, isTrue,
              reason: 'visible button mid-flow (only the hidden parity '
                  'reservation may exist)');
        }
      }
      // Exactly one instructional text during capture…
      expect(find.text(enrollCapturePrompt), findsOneWidget);
      // …and no per-angle titles, hints, or status narration anywhere.
      for (final banned in [
        'Look straight',
        'Turn slightly',
        'Tilt slightly',
        'Hold still',
        'Checking',
        'Verifying',
        'Analyzing',
        'Retake',
      ]) {
        expect(find.textContaining(banned), findsNothing,
            reason: 'banned mid-flow jargon: $banned');
      }
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
      // let beats and sweep ticks fire post-dispose.
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(find.text('open-capture'), findsOneWidget);
      expect(find.byType(EnrollCaptureScreen), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('preview ancestor chain matches the original screen',
        (t) async {
      // Root cause guard for the elongation bug: StackFit.expand lays
      // non-positioned children tight(biggest) and AspectRatio adopts
      // tight sizes ignoring ratio (SDK stack.dart/proxy_box.dart), so the
      // displayed ratio IS the preview-area ratio — and the area is set by
      // THIS chain. Any wrapper inserted here re-elongates the feed.
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);

      List<Element> chainOf(Finder f) {
        final out = <Element>[];
        t.element(f).visitAncestorElements((a) {
          out.add(a);
          return true;
        });
        return out;
      }

      // Preview path: overlay > Stack(expand) > Center > Expanded(flex 1)
      // > Column(max) > Scaffold — with no constraining wrapper between.
      final preview =
          chainOf(find.byType(FaceCaptureOvalOverlay)).map((e) => e.widget).toList();
      int after(int from, bool Function(Widget) test, String what) {
        final at = preview.indexWhere(test, from);
        expect(at, isNot(-1), reason: 'missing chain link: $what');
        return at;
      }

      var i = after(
          0, (w) => w is Stack && w.fit == StackFit.expand, 'Stack(expand)');
      i = after(i + 1, (w) => w is Center, 'Center');
      final expandedAt =
          after(i + 1, (w) => w is Expanded, 'Expanded');
      expect((preview[expandedAt] as Expanded).flex, 1);
      final bodyAt = after(
          expandedAt + 1,
          (w) => w is Column && w.mainAxisSize == MainAxisSize.max,
          'body Column(max)');
      i = after(bodyAt + 1, (w) => w is Scaffold, 'Scaffold');
      final between = preview.sublist(0, i);
      for (final ban in [AspectRatio, FittedBox, ConstrainedBox]) {
        expect(between.where((w) => w.runtimeType == ban), isEmpty,
            reason: 'constraining wrapper in preview path: $ban');
      }

      // Prompt path: prompt > Column(min) > Padding(16) — the original
      // bottom-bar slot, same padding, static content (constant area).
      final prompt =
          chainOf(find.text(enrollCapturePrompt)).map((e) => e.widget).toList();
      final promptColAt = prompt.indexWhere(
          (w) => w is Column && w.mainAxisSize == MainAxisSize.min);
      expect(promptColAt, isNot(-1),
          reason: 'missing chain link: prompt Column(min)');
      final padAt = prompt.indexWhere((w) => w is Padding, promptColAt + 1);
      expect(padAt, isNot(-1), reason: 'missing chain link: Padding(16)');
      expect((prompt[padAt] as Padding).padding,
          const EdgeInsets.all(16));
      expect(t.takeException(), isNull);
      // Drain via cancel (loop + sweep timer must both die on dispose).
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(find.text('open-capture'), findsOneWidget);
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
      expect(t.takeException(), isNull);
    });

    testWidgets('alternating classifications keep one static prompt',
        (t) async {
      // Stills arrive left/right while centre is missing: buckets fill
      // opportunistically, but the single prompt never changes and no
      // other instructional text ever appears — per-frame output steers
      // nothing user-facing.
      const left = PoseReading(yaw: -20, pitch: 0, roll: 0);
      const right = PoseReading(yaw: 20, pitch: 0, roll: 0);
      final gate = FakePoseGate(readings: [left, right]);
      final camera = FakeEnrollSessionCamera();
      final verifier = FakeFaceVerifier();
      final ctl = await _keyReady(verifier: verifier);
      await t.pumpWidget(_captureHarness(
          ctl: ctl, gate: gate, camera: camera));
      await _openSession(t);
      // Two buckets filled by "wrong"-order stills — prompt unchanged,
      // gallery untouched until the terminal write.
      await _pumpUntil(
          t, find.bySemanticsLabel('Captured 2 of 5 angles'));
      expect(find.text(enrollCapturePrompt), findsOneWidget);
      expect(find.textContaining('Turn'), findsNothing);
      expect(find.textContaining('Look straight'), findsNothing);
      expect(verifier.calls.where((c) => c.startsWith('enroll:')), isEmpty);
      // The session still completes (centre fills from the cycle next).
      await _pumpUntil(t, find.text('Save enrollment'));
      await t.pumpAndSettle();
      expect(camera.captures, 7);
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
