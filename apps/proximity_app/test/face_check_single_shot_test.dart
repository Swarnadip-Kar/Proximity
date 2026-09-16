// Face-check single-shot correction (tester-directed, 2026-09-10 — see
// INTEGRATION_LOG.md `## Face-check single-shot`): mark/face is an INSTANT
// single-shot check, so it shows NO enrollment multi-angle guidance — no
// rotation instruction, no orbiting beacon/comet, no progress bar, no angle
// counts. Exactly two overlay elements: ONE static framing oval + ONE
// prompt line (host notice when present, else `faceCheckPrompt`). The
// preview surface keeps the same bare native-aspect undistorted treatment
// as enrollment (direct Stack child, zero treatment).
//
// Frozen (untouched here): auto-scan timing, retry/burn rules, verdict
// strings, FaceGate semantics (FEATURE_INVENTORY.md §3.5 + Appendix A).
// Enroll rendering byte-identical (defaults showProgress/showBeacon true).
import 'dart:io';

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
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/features/mark/face_check.dart';
import 'package:proximity_app/features/setup/enroll_capture.dart';
import 'package:proximity_app/features/setup/enroll_widgets.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';

Widget _themed(Widget child) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: child),
    );

/// Test stand-in for a live frame: self-maintains its native aspect
/// internally (like `CameraPreview`), so the suite can prove the loose
/// Stack never distorts it.
class _NativeFeed extends StatelessWidget {
  final double ratio;
  const _NativeFeed({required this.ratio});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: ratio,
      child: const SizedBox.expand(key: Key('feed')),
    );
  }
}

/// The preview Stack: the loose, centered Stack carrying the overlay.
Finder _previewStackFinder() => find.byWidgetPredicate((w) =>
    w is Stack &&
    w.fit == StackFit.loose &&
    w.alignment == Alignment.center &&
    w.children.whereType<CaptureOverlay>().isNotEmpty);

/// Strips `//` doc/provenance comments so negative pins only see code.
String _codeOf(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

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

void _noop() {}

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
  // Clean integrity verdict for generateKey; restored afterwards so
  // probe-sensitive suites keep the real probe.
  setUp(() => IntegrityGate.probe = const _CleanProbe());
  tearDown(() => IntegrityGate.probe = const PlatformIntegrityProbe());
  group('single-shot prompt', () {
    test('faceCheckPrompt is one look-at-the-camera line', () {
      expect(faceCheckPrompt.toLowerCase(), contains('look at the camera'));
      expect(faceCheckPrompt, isNot(contains('Rotate')));
      expect(faceCheckPrompt, isNot(contains('beacon')));
      expect(faceCheckPrompt, isNot(contains('glow')));
    });

    testWidgets('mark/face at rest shows the single-shot line, never rotation',
        (t) async {
      await t.pumpWidget(_themed(FaceCheckView(
        faceNotice: '',
        canScan: true,
        onScan: () {},
      )));
      await t.pump();
      expect(find.text(faceCheckPrompt), findsOneWidget);
      expect(find.text(captureGuidePrompt), findsNothing);
      expect(find.textContaining('Rotate'), findsNothing);
      expect(find.textContaining('beacon'), findsNothing);
      expect(find.textContaining('glow'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('host notice replaces the single-shot line when present',
        (t) async {
      const notice = 'Scan unclear — retrying automatically… (1 of 2)';
      await t.pumpWidget(_themed(FaceCheckView(
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

    test('signal mapping unchanged (mismatch never renders here)', () {
      expect(FaceCheckView.signalForNotice(''), CaptureSignal.neutral);
      expect(
          FaceCheckView.signalForNotice(
              'Scan unclear — retrying automatically… (1 of 2)'),
          CaptureSignal.inconclusive);
      expect(
          FaceCheckView.signalForNotice(
              'Could not read that scan — adjust light and try again.'),
          CaptureSignal.inconclusive);
    });
  });

  group('no beacon/rotation/progress-angle elements on mark/face', () {
    testWidgets('no progress bar on mark/face', (t) async {
      await t.pumpWidget(_themed(FaceCheckView(
        faceNotice: '',
        canScan: true,
        onScan: () {},
      )));
      await t.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('overlay flags hide progress + beacon on mark/face',
        (t) async {
      await t.pumpWidget(_themed(FaceCheckView(
        faceNotice: '',
        canScan: true,
        onScan: () {},
      )));
      await t.pump();
      final overlay =
          t.widget<CaptureOverlay>(find.byType(CaptureOverlay));
      expect(overlay.showProgress, isFalse);
      expect(overlay.showBeacon, isFalse);
      // The static framing oval still paints (CustomPaint present).
      expect(find.byType(CustomPaint), findsWidgets);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('Scan fallback retained', (t) async {
      await t.pumpWidget(_themed(FaceCheckView(
        faceNotice: '',
        canScan: true,
        onScan: () {},
      )));
      await t.pump();
      expect(find.text('Scan face'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    test('mark/face source has no rotation/beacon copy (source pin)', () {
      final face = _codeOf(
          File('lib/features/mark/face_check.dart').readAsStringSync());
      expect(face.contains('captureGuidePrompt'), isFalse,
          reason: 'rotation copy must never render on mark/face');
      expect(face.contains('Rotate your face'), isFalse);
      expect(face.contains('green beacon'), isFalse);
      // Single-shot line is the explicit status line.
      expect(face.contains('faceCheckPrompt'), isTrue);
      expect(face.contains('showProgress: false'), isTrue);
      expect(face.contains('showBeacon: false'), isTrue);
    });
  });

  group('bare undistorted preview pin (same as enrollment)', () {
    testWidgets('mark placeholder is a bare direct Stack child', (t) async {
      await t.pumpWidget(_themed(FaceCheckView(
        faceNotice: '',
        canScan: true,
        onScan: () {},
      )));
      await t.pump();
      expect(_previewStackFinder(), findsOneWidget);
      final stack = t.element(_previewStackFinder()).widget as Stack;
      expect(stack.children.first, isA<SizedBox>());
      expect(stack.fit, StackFit.loose);
      expect(stack.alignment, Alignment.center);
      expect(find.byType(CaptureOverlay), findsOneWidget);
      // Zero treatment outside the overlay's own chrome.
      expect(
          find.descendant(
              of: _previewStackFinder(),
              matching: find.byWidgetPredicate((w) =>
                  w is Container ||
                  w is ColoredBox ||
                  w is DecoratedBox ||
                  w is FittedBox)),
          findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('mark provided frame stays a direct Stack child', (t) async {
      await t.pumpWidget(_themed(const FaceCheckView(
        faceNotice: '',
        canScan: false,
        onScan: _noop,
        previewAspectRatio: 3 / 4,
        preview: _NativeFeed(ratio: 3 / 4),
      )));
      await t.pump();
      expect(_previewStackFinder(), findsOneWidget);
      final stack = t.element(_previewStackFinder()).widget as Stack;
      expect(stack.children.first, isA<_NativeFeed>());
      final overlay =
          t.widget<CaptureOverlay>(find.byType(CaptureOverlay));
      expect(overlay.previewAspectRatio,
          moreOrLessEquals(3 / 4, epsilon: 1e-9));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('mark keeps native aspect at 3:4 / 4:3 / 20:9 / 1:1',
        (t) async {
      Future<Rect> pumpMark(double boxW, double boxH, double ratio) async {
        await t.pumpWidget(_themed(SizedBox(
          width: boxW,
          height: boxH,
          child: const FaceCheckView(
            faceNotice: '',
            canScan: false,
            onScan: _noop,
            previewAspectRatio: 3 / 4,
            preview: _NativeFeed(ratio: 3 / 4),
          ),
        )));
        // Per-ratio override (const above is 3:4; rebuild for others).
        await t.pumpWidget(_themed(SizedBox(
          width: boxW,
          height: boxH,
          child: FaceCheckView(
            faceNotice: '',
            canScan: false,
            onScan: _noop,
            previewAspectRatio: ratio,
            preview: _NativeFeed(ratio: ratio),
          ),
        )));
        await t.pump();
        final rect = t.getRect(find.byKey(const Key('feed')));
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        return rect;
      }

      for (final c in [
        (800.0, 600.0, 3 / 4),
        (400.0, 800.0, 4 / 3),
        (600.0, 600.0, 20 / 9),
        (400.0, 800.0, 1.0),
      ]) {
        final feed = await pumpMark(c.$1, c.$2, c.$3);
        expect(feed.width / feed.height,
            moreOrLessEquals(c.$3, epsilon: 0.02));
      }
    });

    test('preview surface code has zero treatment (source pin)', () {
      final face = _codeOf(
          File('lib/features/mark/face_check.dart').readAsStringSync());
      for (final ban in [
        'FittedBox(',
        'BoxFit.cover',
        'BoxFit.fill',
        'BoxFit.contain',
        'BoxFit.fitWidth',
        'BoxFit.fitHeight',
        'BoxFit.scaleDown',
        'Transform.scale',
        'ColorFiltered(',
        'ImageFiltered(',
        'BackdropFilter(',
        'ShaderMask(',
        'ColorFilter.',
        'BoxDecoration(',
        'LetterboxedPreview',
      ]) {
        expect(face.contains(ban), isFalse,
            reason: 'treatment on mark preview path: $ban');
      }
      expect(face.contains('StackFit.loose'), isTrue);
      expect(face.contains('StackFit.expand'), isFalse,
          reason: 'force-fill Stack fit stretches the frame');
    });
  });

  group('enroll overlay unchanged (incl. beacon)', () {
    test('overlay defaults keep multi-angle guidance', () {
      const overlay = CaptureOverlay(
        progress: 0.4,
        currentAngle: 1,
        totalAngles: 5,
      );
      expect(overlay.showProgress, isTrue);
      expect(overlay.showBeacon, isTrue);
    });

    testWidgets('default overlay still shows bar + rotation prompt',
        (t) async {
      await t.pumpWidget(_themed(const CaptureOverlay(
        progress: 0.4,
        currentAngle: 1,
        totalAngles: 5,
      )));
      await t.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text(captureGuidePrompt), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('hidden-beacon painter still draws the oval (source pin)',
        (t) async {
      final overlaySrc = _codeOf(
          File('lib/widgets/capture_overlay.dart').readAsStringSync());
      // Additive flags exist with true defaults (enroll byte-identical).
      expect(overlaySrc.contains('showProgress = true'), isTrue);
      expect(overlaySrc.contains('showBeacon = true'), isTrue);
      // Beacon paint is gated; the oval draw stays unconditional.
      expect(overlaySrc.contains('if (!showBeacon) return;'), isTrue);
      expect(overlaySrc.contains('if (widget.showProgress)'), isTrue);
      expect(overlaySrc.contains('drawOval('), isTrue);
      expect(overlaySrc.contains('drawArc('), isTrue);
      expect(overlaySrc.contains('drawCircle('), isTrue);
    });

    testWidgets('enroll consumer still shows bar + beacon + enroll prompt',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      expect(find.byType(CaptureOverlay), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text(enrollCapturePrompt), findsOneWidget);
      expect(find.text(faceCheckPrompt), findsNothing);
      expect(find.text(captureGuidePrompt), findsNothing);
      final overlay =
          t.widget<CaptureOverlay>(find.byType(CaptureOverlay));
      expect(overlay.showProgress, isTrue);
      expect(overlay.showBeacon, isTrue);
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
