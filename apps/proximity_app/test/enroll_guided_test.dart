// Continuous-session enrollment contracts: pose windows, bucket
// classification (pure), preview parity with the 5186c65 original
// (source lines + ancestor chain), overlay-only composition, bucket-fill
// advance under one static prompt (no flicker), sweep glow,
// cancel/dispose safety, fail-closed save.
//
// Guidance model (Apple Face ID + Tobii "follow the target"): every still
// classifies into ANY matching unfilled bucket; the small oval + one static
// prompt guide, the large oval arc reports. Nothing user-facing ever narrates
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
import 'package:proximity_app/core/security/user_presence.dart';
import 'package:proximity_app/core/security/integrity.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/setup/enroll_capture.dart';
import 'package:proximity_app/features/setup/enroll_flow.dart';
import 'package:proximity_app/features/setup/enroll_result.dart';
import 'package:proximity_app/features/setup/enroll_widgets.dart';
import 'package:proximity_app/features/setup/flash_assist.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/routes.dart';
import 'package:proximity_app/screens/face_capture.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';
import 'package:proximity_app/widgets/prox_buttons.dart';
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
    {FaceVerifier? verifier,
    InMemoryDeviceStore? store,
    LivenessGate? livenessGate}) async {
  final ctl = EnrollmentController(
    auth: FakeAuthService(const SignedAccount(
        email: 's@x.in', displayName: 'S', uid: 'u1')),
    store: store ?? InMemoryDeviceStore(),
    verifier: verifier ?? FakeFaceVerifier(),
    deviceKey: FakeDeviceKey(),
    presenceGate: FakePresenceGate(),
    // enrollFace measures liveness: scripted pass unless a test passes its
    // own gate (liveness itself is pinned in enroll_liveness_gate_test).
    livenessGate: livenessGate ?? FakeLivenessGate(),
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
        PoseGate? gate,
        LivenessGate? sessionLiveness}) =>
    ProviderScope(
      overrides: [
        enrollmentControllerProvider.overrideWith((ref) => ctl),
        enrollSessionCameraProvider
            .overrideWithValue(camera ?? FakeEnrollSessionCamera()),
        poseGateProvider.overrideWithValue(gate ?? FakePoseGate()),
        // Brightness seam: the real channel's timeout timers never settle
        // under FakeAsync (see HardwareDeviceIds + enroll_readout_test),
        // so session tests always drive the fake.
        enrollScreenBrightnessProvider
            .overrideWithValue(FakeScreenBrightnessControl()),
        // Session vitality pre-check: scripted pass by default (the
        // terminal enrollFace gate pins scoring itself); pass a low-score
        // gate to prove non-live stills are discarded in-loop.
        enrollSessionLivenessProvider.overrideWithValue(
            sessionLiveness ?? FakeLivenessGate()),
      ],
      child: MaterialApp(
        // App theme: the shared two-oval overlay reads ProximityColors.
        theme: proxLightTheme(),
        // Named-route table: EnrollFlow.openResult (capture → result
        // auto-advance) goes through ProxNav.pushNamed, so the harness
        // must resolve enroll/* names like production does.
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

// Widget-test integrity fake: the real PlatformIntegrityProbe does native
// channel I/O with a .timeout(8s) budget, which never fires under the
// testWidgets FakeAsync clock — generateKey hangs forever (same stall as
// enroll_capture_breakup_test.dart).
class _CleanProbe implements IntegrityProbe {
  const _CleanProbe();
  @override
  Future<IntegritySignals> check() async => const IntegritySignals();
}

void main() {
  // EnrollFlow single-flight flags are static: a test that leaves a pushed
  // result on top must not block the next test's push.
  setUp(EnrollFlow.debugReset);
  tearDown(EnrollFlow.debugReset);
  // Clean integrity verdict for generateKey; restored afterwards so
  // probe-sensitive suites keep the real probe.
  setUp(() => IntegrityGate.probe = const _CleanProbe());
  tearDown(() => IntegrityGate.probe = const PlatformIntegrityProbe());
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

  group('guided walk order + wheel bands (pure, no native calls)', () {
    test('walk order is bottom, centre, top, left, right', () {
      expect(EnrollCaptureOrder.order,
          ['down', 'centre', 'up', 'left', 'right']);
      expect(EnrollCaptureOrder.order.toSet(), faceEnrollSlots.toSet());
    });

    test('bands match the pose windows per axis', () {
      // Centre: symmetric tight window on both axes.
      expect(EnrollCaptureOrder.pitchBand('centre')?.min, -12.0);
      expect(EnrollCaptureOrder.pitchBand('centre')?.max, 12.0);
      expect(EnrollCaptureOrder.yawBand('centre')?.min, -12.0);
      expect(EnrollCaptureOrder.yawBand('centre')?.max, 12.0);
      // Sides: yaw-only (pitch wheel shows the marker, no band).
      expect(EnrollCaptureOrder.yawBand('left')?.min, -35.0);
      expect(EnrollCaptureOrder.yawBand('left')?.max, -8.0);
      expect(EnrollCaptureOrder.yawBand('right')?.min, 8.0);
      expect(EnrollCaptureOrder.yawBand('right')?.max, 35.0);
      expect(EnrollCaptureOrder.pitchBand('left'), isNull);
      expect(EnrollCaptureOrder.pitchBand('right'), isNull);
      // Tilts: pitch-only.
      expect(EnrollCaptureOrder.pitchBand('up')?.min, 8.0);
      expect(EnrollCaptureOrder.pitchBand('up')?.max, 30.0);
      expect(EnrollCaptureOrder.pitchBand('down')?.min, -30.0);
      expect(EnrollCaptureOrder.pitchBand('down')?.max, -8.0);
      expect(EnrollCaptureOrder.yawBand('up'), isNull);
      expect(EnrollCaptureOrder.yawBand('down'), isNull);
      expect(EnrollCaptureOrder.pitchBand('nope'), isNull);
    });

    test('wheel fraction maps and clamps; in-band is exact', () {
      expect(CaptureOverlay.wheelFraction(null, 35), isNull);
      expect(CaptureOverlay.wheelFraction(double.nan, 35), isNull);
      expect(CaptureOverlay.wheelFraction(0, 35), 0.5);
      expect(CaptureOverlay.wheelFraction(-35, 35), 0.0);
      expect(CaptureOverlay.wheelFraction(35, 35), 1.0);
      expect(CaptureOverlay.wheelFraction(-99, 35), 0.0);
      expect(CaptureOverlay.wheelFraction(99, 35), 1.0);
      final down = EnrollCaptureOrder.pitchBand('down')!;
      expect(CaptureOverlay.wheelInBand(-15, down), isTrue);
      expect(CaptureOverlay.wheelInBand(-8, down), isTrue);
      expect(CaptureOverlay.wheelInBand(-30, down), isTrue);
      expect(CaptureOverlay.wheelInBand(0, down), isFalse);
      expect(CaptureOverlay.wheelInBand(null, down), isFalse);
      expect(CaptureOverlay.wheelInBand(-15, null), isFalse);
    });
  });

  group('preview parity with the 5186c65 original', () {
    // BREAKUP 2026-09-10 (see INTEGRATION_LOG.md `## Enroll capture
    // breakup`, hardened in `## Capture preview fidelity`): the monolith
    // is split three ways — session driver (enroll_capture_session.dart),
    // section widgets (enroll_capture_sections.dart), thin composer
    // (enroll_capture.dart). The tight-stretch chain, the cover-fit chain,
    // AND the outer-AspectRatio wrapper are all retired: the feed renders
    // as a BARE CameraPreview (zero treatment, direct child of a loose,
    // centered Stack — never stretched, never cover-cropped, never
    // double-boxed). These pins track the NEW homes: driver identifiers
    // byte-identical in the session file, the bare-surface chain in the
    // sections file, composition in the screen file. If this fails, the
    // split drifted — do not "fix" the test, fix the block. Paths are
    // package-relative (flutter test runs at the package root).
    String lib(String name) => File('lib/features/setup/$name')
        .readAsStringSync();
    String sessionLib() => lib('enroll_capture_session.dart');
    String sectionsLib() => lib('enroll_capture_sections.dart');
    String screenLib() => lib('enroll_capture.dart');

    void inOrder(String src, List<String> lines) {
      var from = 0;
      for (final line in lines) {
        final at = src.indexOf(line, from);
        expect(at, isNot(-1), reason: 'missing verbatim line: $line');
        from = at + line.length;
      }
    }

    test('driver lives in the session file, in order', () {
      // Relocation only: open/close, classify-fill loop, save, dispose,
      // timers — byte-identical bodies, called out in the breakup entry.
      inOrder(sessionLib(), [
        'Future<void> _openCamera()',
        'void _startLoop()',
        'Future<void> _autoLoop()',
        'Future<String?> _captureOne()',
        'Future<void> _saveAll()',
      ]);
      // Camera seam moved with the driver (screen re-exports for compat).
      expect(sessionLib().contains('class FakeEnrollSessionCamera'), isTrue);
      expect(sessionLib().contains('enrollSessionCameraProvider'), isTrue);
      expect(screenLib().contains('class FakeEnrollSessionCamera'), isFalse);
      expect(screenLib().contains('Future<void> _autoLoop'), isFalse);
    });

    test('bare-surface chain lives in the sections file, in order', () {
      inOrder(sectionsLib(), [
        'displayedPreviewAspect',
        'class EnrollCapturePreview',
        'CameraPreview(',
        'CaptureOverlay(',
        'if (saveError)',
      ]);
      // Fail branches kept their shapes (fail message + spinner).
      expect(sectionsLib().contains('previewMessage'), isFalse);
      expect(sectionsLib().contains('padding: const EdgeInsets.all(24),'),
          isTrue);
      expect(
          sectionsLib().contains(
              'const Center(child: CircularProgressIndicator())'),
          isTrue);
      // The overlay comment travels with the Stack it documents.
      expect(
          sectionsLib().contains(
              '// overlay is inside the preview Stack (not beside'),
          isTrue);
    });

    test('composer screen owns build only, in order', () {
      inOrder(screenLib(), [
        'Expanded(',
        'EnrollCapturePreview(',
        'EnrollCaptureBottomBar(',
      ]);
      expect(screenLib().contains('previewMessage'), isTrue);
      expect(screenLib().contains('EnrollCaptureBlocked'), isTrue);
      // The composer wires the per-target guided prompt into the preview,
      // overridden by the move-to-light line on a dark stall and the
      // stall nudge after wasted/faceless beats (all warn-only). Flash
      // assist rides the same stall state (graded ring level + brightness
      // shell).
      expect(screenLib().contains('enrollTargetPrompt(targetSlot)'), isTrue);
      expect(screenLib().contains('Too dark — move to brighter light'),
          isTrue);
      expect(screenLib().contains('No good capture yet'), isTrue);
      expect(screenLib().contains('FlashAssistSync'), isTrue);
      expect(screenLib().contains('flashAssist'), isTrue);
      expect(screenLib().contains('flashLevel'), isTrue);
    });

    test('exactly the documented breakup deltas, nothing else', () {
      // Combined surface: pins that moved files still read as one contract.
      // Code only for the negative pins: doc comments name the retired
      // chains (cover-fit, tight-stretch) for provenance.
      String codeOf(String src) => src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      final combined = sessionLib() + sectionsLib() + screenLib();
      final code = codeOf(sessionLib()) + codeOf(sectionsLib()) + codeOf(screenLib());
      // (a) three-state message instead of the single status…
      expect(combined.contains('child: Text(_status,'), isFalse);
      expect(combined.contains('previewMessage'), isTrue);
      // (b) spinner branch restored verbatim, keyed on opening.
      expect(
          combined.contains(
              'const Center(child: CircularProgressIndicator())'),
          isTrue);
      expect(
          combined.contains('!ctl.value.isInitialized\n'
              '                      ? const CircularProgressIndicator()'),
          isFalse);
      // (c) THE shared single-oval overlay (override 2026-09-10):
      // CaptureOverlay present with the angle count from the controller's
      // own slot list (verified 5 via faceEnrollSlots, never hardcoded)
      // and the frozen enroll prompt as its single line; the old single
      // oval + dots are gone.
      expect(combined.contains('CaptureOverlay('), isTrue);
      expect(combined.contains('faceEnrollSlots.length'), isTrue);
      expect(combined.contains('enrollTargetPrompt(targetSlot)'), isTrue);
      expect(combined.contains('FaceOval('), isFalse);
      expect(combined.contains('FaceCaptureOvalOverlay('), isFalse);
      expect(combined.contains('EnrollAngleDots('), isFalse);
      // (d) full-bleed cover: the sensor frame COVERS the loose Stack via
      // explicit cover math (OverflowBox centering inside a ClipRect —
      // uniform scale, zero transforms, no color treatment), so no
      // letterbox bars exist to diverge. NO fit transform and NO outer
      // ratio box anywhere (FittedBox, fill, contain, width/height
      // stretches retired). Code-only: doc comments keep naming the
      // retired chains for provenance.
      expect(code.contains('AspectRatio('), isFalse);
      expect(code.contains('LetterboxedPreview'), isFalse);
      expect(code.contains('StackFit.expand'), isFalse);
      expect(code.contains('CameraPreview('), isTrue);
      expect(code.contains('StackFit.loose'), isTrue);
      expect(code.contains('displayedPreviewAspect'), isTrue);
      expect(code.contains('OverflowBox('), isTrue);
      expect(code.contains('ClipRect('), isTrue);
      expect(code.contains('FittedBox('), isFalse);
      expect(code.contains('Transform('), isFalse);
      expect(code.contains('BoxFit.cover'), isFalse);
      expect(code.contains('BoxFit.fill'), isFalse);
      expect(code.contains('BoxFit.contain'), isFalse);
      // (e) save-error toast stays Positioned + saveError-gated with the
      // sweep param on the overlay, and no trace of the removed single-
      // oval beacon spans…
      expect(combined.contains('if (saveError)'), isTrue);
      expect(combined.contains('sweepAngle:'), isTrue);
      expect(combined.contains('sweepSpan'), isFalse);
      expect(combined.contains('dotUnit'), isFalse);
      expect(combined.contains('guideDotUnit'), isFalse);
      // …and the original single-status/progress expressions are gone.
      expect(combined.contains('_taken / widget.captures'), isFalse);
      // …and no per-angle titles / narration strings survive anywhere.
      expect(combined.contains('enrollAngleInstructions'), isFalse);
      expect(combined.contains('Hold still'), isFalse);
      expect(combined.contains('Checking angle'), isFalse);
    });
  });

  group('guided copy (per-target contracts)', () {
    test('one prompt per walk slot, pinned verbatim', () {
      expect(enrollCapturePrompt,
          'Rotate your face slowly, following the glow.');
      expect(enrollTargetPrompt('down'), 'Tilt down into the glowing band');
      expect(enrollTargetPrompt('centre'), 'Look straight at the lens');
      expect(enrollTargetPrompt('up'), 'Tilt up into the glowing band');
      expect(enrollTargetPrompt('left'), 'Turn left into the glowing band');
      expect(enrollTargetPrompt('right'), 'Turn right into the glowing band');
      expect(enrollTargetPrompt('nope'), enrollCapturePrompt);
      expect(faceEnrollSlots, ['centre', 'left', 'right', 'up', 'down']);
    });

    testWidgets('camera oval overlay renders + repaints on progress',
        (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: FaceCaptureOvalOverlay(progress: 0)),
      ));
      expect(find.byType(CustomPaint), findsWidgets);
      // Advancing progress repaints…
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: FaceCaptureOvalOverlay(progress: 0.5)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      // …to full.
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: FaceCaptureOvalOverlay(progress: 1.0)),
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
    /// Stored-key fixture: enrollment sealed on device (security §2 —
    /// DKey envelope, never a raw seed) with a FRESH controller holding
    /// an empty draft (restart / Accounts Re-scan entry shape).
    Future<EnrollmentController> storedKeyController() async {
      final store = InMemoryDeviceStore();
      final sealedFixture = hexEncode(await FakeDeviceKey()
          .seal(Uint8List.fromList(hexDecode('ab' * 32))));
      await store.writeEnrollment(StoredEnrollment(
        email: 's@x.in',
        name: 'S',
        roll: 'R1',
        pkHex: 'cd' * 32,
        sealedKeyHex: sealedFixture,
        faceId: 'face-1',
        enrolledAt: DateTime.utc(2026, 9, 1),
        verifierVer: kFaceVerifierVer,
        org: 'example.com',
        pkDHex: 'ef' * 32,
        attestationLevel: 'NONE',
        attestedAt: DateTime.utc(2026, 9, 1),
        attestedUntil: DateTime.utc(2026, 11, 30),
      ));
      final ctl = EnrollmentController(
        auth: FakeAuthService(const SignedAccount(
            email: 's@x.in', displayName: 'S', uid: 'u1')),
        store: store,
        verifier: FakeFaceVerifier(),
        deviceKey: FakeDeviceKey(),
        presenceGate: FakePresenceGate(),
        // enrollFace measures liveness on the fake stills: scripted pass
        // (liveness itself is pinned in enroll_liveness_gate_test).
        livenessGate: FakeLivenessGate(),
      );
      expect(ctl.state.pkHex, isEmpty);
      return ctl;
    }

    testWidgets('mount restores the stored key (rescan after restart)',
        (t) async {
      // Rescan regression: key generated earlier (stored on device), then
      // a fresh controller (restart) with an empty draft. Mounting the
      // capture screen must reconcile (refreshFromAuth) so Save does not
      // fail-closed with "Generate the device key first".
      final ctl = await storedKeyController();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      await t.pumpAndSettle();
      expect(ctl.state.pkHex.isNotEmpty, isTrue);
      expect(t.takeException(), isNull);
      // Drain: cancel the live loop (pops back to the launcher).
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('rescan entry scans without a key gate (stored key wins)',
        (t) async {
      // Accounts Re-scan shape: enrollment exists, controller draft is
      // empty, restartFace() ran (key kept). The session must restore
      // BEFORE the camera key gate — never strand on "Generate the device
      // key on the previous screen first".
      final ctl = await storedKeyController();
      final camera = FakeEnrollSessionCamera();
      await ctl.restartFace();
      await t.pumpWidget(
          _captureHarness(ctl: ctl, camera: camera));
      await _openSession(t);
      expect(find.textContaining('Generate the device key'), findsNothing);
      // The walk completes on its own against the cycling default gate.
      await _pumpUntil(t, find.text('Save enrollment'));
      await t.pumpAndSettle();
      expect(camera.openCount, 1);
      expect(find.text('Save enrollment'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('preview is overlay-only: dots, prompt once, zero jargon',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      // Camera open, loop still in its initial beat (600ms).
      await _openSession(t);
      // Full-bleed preview Stack: THE shared single-oval overlay (slim top
      // bar + oval + beacon + one prompt). No dots, no single oval, no
      // cards. The single static prompt rides inside the overlay (the
      // bottom bar stays empty mid-flow so it never duplicates).
      expect(find.byType(CaptureOverlay), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(FaceCaptureOvalOverlay), findsNothing);
      expect(find.byType(ProxCard), findsNothing);
      // No VISIBLE buttons mid-flow; area parity is a hidden same-subtree
      // replica (two maintainSize Visibilities: the replica shell + its
      // inner slot top-up), so terminal chrome never moves the feed.
      expect(find.byType(FilledButton), findsNothing);
      expect(
          find.byWidgetPredicate(
              (w) => w is Visibility && !w.visible && w.maintainSize),
          findsWidgets);
      // Exactly one instructional text during capture (overlay-owned,
      // guided to the current walk target)…
      expect(find.text(enrollTargetPrompt('down')), findsOneWidget);
      // …and no checker narration or status jargon anywhere.
      for (final banned in [
        'Hold still',
        'Checking',
        'Verifying',
        'Analyzing',
        'Retake',
      ]) {
        expect(find.textContaining(banned), findsNothing,
            reason: 'banned mid-flow jargon: $banned');
      }
      // The overlay never affects preview layout: CaptureOverlay is itself
      // pointer-transparent inside the Stack (ancestor existence; Scaffold
      // internals own other IgnorePointers, so this asserts presence).
      expect(
          find.ancestor(
              of: find.byType(CaptureOverlay),
              matching: find.byType(Stack)),
          findsWidgets);
      // …and the preview is full-bleed (Expanded, no Center wrapper, no
      // fixed-height box).
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

    testWidgets('preview ancestor chain matches the bare-surface screen',
        (t) async {
      // Squish-fix guard: the feed renders as a BARE frame (zero
      // treatment, direct child of a loose, centered Stack), so nothing
      // force-fills it — the area is set by THIS chain (Scaffold >
      // Column(max) > Expanded(flex 1) > preview Stack), with no wrapper
      // of any kind between the frame and the Stack. Any wrapper inserted
      // here must stay bare-surface-safe.
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

      // Preview path: overlay > Stack(loose, centered) > Expanded(flex 1)
      // > Column(max) > Scaffold — with no wrapper between.
      final preview =
          chainOf(find.byType(CaptureOverlay)).map((e) => e.widget).toList();
      int after(int from, bool Function(Widget) test, String what) {
        final at = preview.indexWhere(test, from);
        expect(at, isNot(-1), reason: 'missing chain link: $what');
        return at;
      }

      var i = after(
          0,
          (w) =>
              w is Stack &&
              w.fit == StackFit.loose &&
              w.alignment == Alignment.center,
          'Stack(loose, centered)');
      expect(
          preview.sublist(0, i).whereType<Center>(), isEmpty,
          reason: 'Center wrapper back in preview path');
      final expandedAt =
          after(i + 1, (w) => w is Expanded, 'Expanded');
      expect((preview[expandedAt] as Expanded).flex, 1);
      final bodyAt = after(
          expandedAt + 1,
          (w) => w is Column && w.mainAxisSize == MainAxisSize.max,
          'body Column(max)');
      i = after(bodyAt + 1, (w) => w is Scaffold, 'Scaffold');
      final between = preview.sublist(0, i);
      for (final ban in [AspectRatio, ConstrainedBox]) {
        expect(between.where((w) => w.runtimeType == ban), isEmpty,
            reason: 'constraining wrapper in preview path: $ban');
      }

      // Prompt path: the guided prompt rides inside the overlay's own
      // Stack (above the oval) — exactly one instance, never in the
      // bottom bar mid-flow.
      expect(find.text(enrollTargetPrompt('down')), findsOneWidget);
      expect(
          find.ancestor(
              of: find.text(enrollTargetPrompt('down')),
              matching: find.byType(CaptureOverlay)),
          findsOneWidget);
      expect(t.takeException(), isNull);
      // Drain via cancel (loop + sweep timer must both die on dispose).
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(find.text('open-capture'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('no taps: buckets fill in walk order, one camera open',
        (t) async {
      final camera = FakeEnrollSessionCamera();
      // Guided walk order (bottom → centre → top → left → right): script
      // the gate to serve exactly the asked angle per beat, so each of
      // the 5 reads fills one bucket with zero wasted stills.
      final gate = FakePoseGate(readings: const [
        PoseReading(yaw: 0, pitch: -15, roll: 0), // down
        PoseReading(yaw: 0, pitch: 0, roll: 0), // centre
        PoseReading(yaw: 0, pitch: 15, roll: 0), // up
        PoseReading(yaw: -20, pitch: 0, roll: 0), // left
        PoseReading(yaw: 20, pitch: 0, roll: 0), // right
      ]);
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
      // One pose read per still in walk order, nothing else touched.
      expect(gate.readCalls, hasLength(5));
      expect(t.takeException(), isNull);
    });

    testWidgets('vitality pre-check discards non-live stills in-loop',
        (t) async {
      // Auto-magic (2026-09-13): a pose-good but non-live still never
      // fills its bucket — the loop discards it silently and continues,
      // so the holder just keeps following the prompts (no Recapture tap).
      // The terminal enrollFace gate stays the decider (pinned in
      // enroll_liveness_gate_test); here the save must never run.
      final camera = FakeEnrollSessionCamera();
      final gate = FakePoseGate();
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(
        ctl: ctl,
        camera: camera,
        gate: gate,
        sessionLiveness: FakeLivenessGate(score: 0.31),
      ));
      await _openSession(t);
      // Several beats of pose-accepted, vitality-rejected stills: no
      // bucket fills, no save, no error — the session just continues.
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 300));
      }
      expect(find.text('Save enrollment'), findsNothing);
      expect(ctl.state.phase, EnrollPhase.keyReady);
      expect(ctl.state.message, isEmpty);
      expect(camera.captures, greaterThan(5));
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('validated Continue double-press navigates exactly once',
        (t) async {
      // Single-flight: two synchronous Continue presses fire one navigation,
      // so back from the top result lands on capture (not a second result).
      // (Two gesture taps cannot both land — the entering route obscures the
      // button — so the latch is driven directly, same call stack as a tap.)
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      await _pumpUntil(t, find.text('Save enrollment'));
      await t.pumpAndSettle();
      // Back to the validated capture step (loop stopped — settle-safe).
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.byType(EnrollCaptureScreen), findsOneWidget);
      final continueBtn = find.widgetWithText(ProxPrimaryButton, 'Continue');
      expect(continueBtn, findsOneWidget);
      final onContinue =
          t.widget<ProxPrimaryButton>(continueBtn).onPressed!;
      onContinue();
      onContinue();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(find.byType(EnrollResultScreen), findsOneWidget);
      // Exactly one result above capture: one back lands on capture with
      // Continue still offered (not a second result).
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.byType(EnrollCaptureScreen), findsOneWidget);
      expect(find.widgetWithText(ProxPrimaryButton, 'Continue'),
          findsOneWidget);
      expect(find.byType(EnrollResultScreen), findsNothing);
      // Drain via cancel (disposes the session camera).
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('EnrollFlow.openResult double-call pushes one result',
        (t) async {
      // Static single-flight: the second synchronous call is dropped.
      // Named-route table required: openResult goes via ProxNav.pushNamed.
      final ctl = await _keyReady();
      late BuildContext ctx;
      await t.pumpWidget(ProviderScope(
        overrides: [enrollmentControllerProvider.overrideWith((ref) => ctl)],
        child: MaterialApp(
          theme: proxLightTheme(),
          routes: buildProxRoutes(),
          onGenerateRoute: proxOnGenerateRoute,
          onUnknownRoute: proxOnUnknownRoute,
          home: Builder(builder: (c) {
            ctx = c;
            return const Text('home');
          }),
        ),
      ));
      await t.pump();
      EnrollFlow.openResult(ctx);
      EnrollFlow.openResult(ctx);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(find.byType(EnrollResultScreen), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(find.byType(EnrollResultScreen), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('EnrollFlow.openCapture double-call pushes one capture',
        (t) async {
      // Static single-flight: the second synchronous call is dropped.
      // Named-route table required: openCapture goes via ProxNav.pushNamed.
      final ctl = await _keyReady();
      late BuildContext ctx;
      await t.pumpWidget(ProviderScope(
        overrides: [
          enrollmentControllerProvider.overrideWith((ref) => ctl),
          enrollSessionCameraProvider
              .overrideWithValue(FakeEnrollSessionCamera()),
          poseGateProvider.overrideWithValue(FakePoseGate()),
        ],
        child: MaterialApp(
          theme: proxLightTheme(),
          routes: buildProxRoutes(),
          onGenerateRoute: proxOnGenerateRoute,
          onUnknownRoute: proxOnUnknownRoute,
          home: Builder(builder: (c) {
            ctx = c;
            return const Text('home');
          }),
        ),
      ));
      await t.pump();
      EnrollFlow.openCapture(ctx);
      EnrollFlow.openCapture(ctx);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(EnrollCaptureScreen), findsOneWidget);
      // Drain via cancel before the loop can complete (bounded pumps only —
      // the sweep timer is periodic, never pumpAndSettle while mounted).
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(find.text('home'), findsOneWidget);
      expect(find.byType(EnrollCaptureScreen), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('alternating classifications keep one guided prompt',
        (t) async {
      // Stills arrive left/right while the walk asks bottom first: the
      // off-target stills are quiet retries — the prompt names the
      // current target only, and no checker narration ever appears.
      const left = PoseReading(yaw: -20, pitch: 0, roll: 0);
      const right = PoseReading(yaw: 20, pitch: 0, roll: 0);
      final gate = FakePoseGate(readings: [left, right]);
      final camera = FakeEnrollSessionCamera();
      final verifier = FakeFaceVerifier();
      final ctl = await _keyReady(verifier: verifier);
      await t.pumpWidget(_captureHarness(
          ctl: ctl, gate: gate, camera: camera));
      await _openSession(t);
      // Off-target stills fill nothing — prompt still names the bottom
      // target, gallery untouched until the terminal write. Fixed pump
      // past the first beats (any partial state proves the mid-flow
      // point).
      await t.pump(const Duration(milliseconds: 1500));
      expect(find.text(enrollTargetPrompt('down')), findsOneWidget);
      expect(find.textContaining('Checking'), findsNothing);
      expect(find.textContaining('Analyzing'), findsNothing);
      expect(verifier.calls.where((c) => c.startsWith('enroll:')), isEmpty);
      // The session still completes once the walk's angles arrive (the
      // default gate cycles the canonical views after the script).
      await _pumpUntil(t, find.text('Save enrollment'));
      await t.pumpAndSettle();
      expect(camera.captures, 15);
      expect(t.takeException(), isNull);
    });

    testWidgets('blank capture stays silent, slot fills next still',
        (t) async {
      final camera = FakeEnrollSessionCamera([StateError('blank')]);
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl, camera: camera));
      await _openSession(t);
      // First fill arrives with no error text ever shown (silent retry).
      // Fixed pump past the first beat (progress rides the oval arc now).
      await t.pump(const Duration(milliseconds: 800));
      expect(find.textContaining('blank'), findsNothing);
      expect(find.byType(EnrollNotice), findsNothing);
      // One wasted still, then the session completes on its own (the
      // guided walk takes 13 reads against the cycling default gate:
      // down needs the 5th view, then centre, up, left, right land).
      await _pumpUntil(t, find.text('Save enrollment'));
      await t.pumpAndSettle();
      expect(camera.captures, 14);
      expect(t.takeException(), isNull);
    });

    testWidgets('controller error offers Try again, save stays blocked',
        (t) async {
      final ctl = await _keyReady(verifier: _EnrollBoom());
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      await _pumpUntil(t, find.widgetWithText(ProxPrimaryButton, 'Try again').hitTestable());
      expect(find.textContaining('No face detected'), findsOneWidget);
      // Still on capture (no auto-advance), all 5 accepted stills kept.
      expect(find.text('Save enrollment'), findsNothing);
      // Retrying a poisoned gallery fails closed again — never a save.
      await t.tap(find.widgetWithText(ProxPrimaryButton, 'Try again').hitTestable());
      await _pumpUntil(t, find.widgetWithText(ProxPrimaryButton, 'Try again').hitTestable());
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
      // Let the first beat fill, then cancel (progress rides the oval arc).
      await t.pump(const Duration(milliseconds: 1000));
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
      // Direct mount (no router): the screen's own L1 blocked card.
      // Router mounts (MaterialApp.routes / in-tab) render
      // MobileOnlyGuidanceScreen instead — see the next two tests.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      await t.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      expect(find.textContaining('needs the mobile app'), findsOneWidget);
      expect(find.textContaining('Capture'), findsNothing);
      expect(find.byType(MobileOnlyGuidanceScreen), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('router serves guidance for enroll/capture (MaterialApp.routes)',
        (t) async {
      // Guarded web/desktop entry via the exact table: renders guidance,
      // never the flow screen (table wrapper runs guards BEFORE builder).
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        routes: buildProxRoutes(),
        onGenerateRoute: proxOnGenerateRoute,
        onUnknownRoute: proxOnUnknownRoute,
        initialRoute: 'enroll/capture',
      ));
      await t.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      expect(find.byType(MobileOnlyGuidanceScreen), findsOneWidget);
      expect(find.text('Mobile only'), findsOneWidget);
      expect(find.text('Open my records'), findsOneWidget);
      expect(find.byType(EnrollCaptureScreen), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('router serves guidance via in-tab router too', (t) async {
      // Same table + guards + unknown shape as shells._tabRoute.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: Navigator(
          initialRoute: 'enroll/capture',
          onGenerateRoute: (s) {
            if (s.name == null || s.name == '/') {
              return MaterialPageRoute(
                settings: const RouteSettings(name: '/'),
                builder: (_) => const Scaffold(body: Text('tab-root')),
              );
            }
            final exact = buildProxRoutes()[s.name];
            if (exact != null) {
              return MaterialPageRoute(settings: s, builder: exact);
            }
            return proxOnGenerateRoute(s);
          },
          onUnknownRoute: proxOnUnknownRoute,
        ),
      ));
      await t.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      expect(find.byType(MobileOnlyGuidanceScreen), findsOneWidget);
      expect(find.byType(EnrollCaptureScreen), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('recapture key-gate (complete → back → recapture)', () {
    Future<EnrollmentController> keyless() async {
      final ctl = EnrollmentController(
        auth: FakeAuthService(const SignedAccount(
            email: 's@x.in', displayName: 'S', uid: 'u1')),
        store: InMemoryDeviceStore(),
        verifier: FakeFaceVerifier(),
        deviceKey: FakeDeviceKey(),
        presenceGate: FakePresenceGate(),
        // enrollFace measures liveness: scripted pass (liveness itself is
        // pinned in enroll_liveness_gate_test.dart).
        livenessGate: FakeLivenessGate(),
      );
      await ctl.signIn();
      return ctl;
    }

    testWidgets('recapture after faceDone proceeds, no key prompt',
        (t) async {
      // Complete once at the controller level (first capture session).
      final ctl = await _keyReady();
      await ctl.enrollFace(const ['c.jpg', 'l.jpg', 'r.jpg', 'u.jpg', 'd.jpg']);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      // Recapture: a fresh capture session reuses the completed key.
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      // No key gate on the way in (the key is genuinely present).
      expect(
          find.textContaining(
              'Generate the device key on the previous screen'),
          findsNothing);
      // The session runs to completion again (no key error at save).
      await _pumpUntil(t, find.text('Save enrollment'));
      await t.pumpAndSettle();
      expect(
          find.textContaining('Generate the device key'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('truly keyless capture stays blocked, captures nothing',
        (t) async {
      final ctl = await keyless();
      expect(ctl.state.pkHex, isEmpty);
      final camera = FakeEnrollSessionCamera();
      await t.pumpWidget(_captureHarness(ctl: ctl, camera: camera));
      await _openSession(t);
      await t.pumpAndSettle();
      // Fail-closed key prompt, loop never captures.
      expect(
          find.textContaining(
              'Generate the device key on the previous screen'),
          findsOneWidget);
      expect(camera.captures, 0);
      expect(t.takeException(), isNull);
    });
  });
}
