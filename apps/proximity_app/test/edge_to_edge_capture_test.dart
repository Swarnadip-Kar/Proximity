// Edge-to-edge capture contracts (tester-verified residual squish,
// 2026-09-10 — see INTEGRATION_LOG.md `## Edge-to-edge capture`): the
// scaffold chrome (app bar + Column/Expanded boxing) no longer constrains
// the preview — the direct camera preview is the FULLSCREEN background
// with the app bar as a transparent overlay, and every chrome element
// floats above it as a SafeArea-seated positioned overlay (chrome avoids
// the notch; the VIDEO goes under it). Zero treatment on the video path
// (no effects/filters/fits/boxes/decoration), native aspect intact.
//
// - Mark/face: view fills edge-to-edge within its body (no Column/
//   Expanded/Padding boxing); Scan fallback is a bottom-positioned
//   SafeArea overlay; single-shot semantics unchanged (static oval,
//   look-at-camera line, no beacon/progress).
// - Enroll/capture: Scaffold extends behind the status bar + transparent
//   overlay app bar (Cancel still wired to the existing nav); overlay top
//   bar clears the app bar via the additive top inset + SafeArea; toast +
//   bottom bar are SafeArea-seated; beacon/progress + prompt unchanged.
// - Reduced-motion behavior is preserved (covered by the overlay/fidelity
//   suites — sweep/beacon contracts untouched here).
//
// Frozen (untouched here): auto-scan timing/retries, FaceGate semantics,
// prompts, thresholds (FEATURE_INVENTORY.md §3.5 + Appendix A).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/features/mark/face_check.dart';
import 'package:proximity_app/features/setup/enroll_capture.dart';
import 'package:proximity_app/features/setup/enroll_capture_sections.dart';
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

Future<void> _drain(WidgetTester t) async {
  for (var i = 0; i < 15; i++) {
    await t.pump(const Duration(milliseconds: 200));
  }
}

void _noop() {}

void main() {
  group('edge-to-edge scaffold flags (enroll composer)', () {
    testWidgets('body extends behind status bar + transparent app bar',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      // Exactly one fullscreen-extending Scaffold (the capture screen;
      // the harness home keeps defaults).
      expect(
          find.byWidgetPredicate((w) =>
              w is Scaffold &&
              w.extendBodyBehindAppBar &&
              w.extendBody),
          findsOneWidget);
      // Transparent overlay app bar (Cancel action retained).
      final appBar = t.widget<AppBar>(find.byWidgetPredicate((w) =>
          w is AppBar && w.backgroundColor == Colors.transparent));
      expect(appBar.elevation, 0);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      expect(find.text('Face capture'), findsOneWidget);
      // Overlay top bar clears the app bar via the additive inset.
      final overlay =
          t.widget<CaptureOverlay>(find.byType(CaptureOverlay));
      expect(overlay.topInset, moreOrLessEquals(kToolbarHeight));
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(find.text('open-capture'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    test('composer source pins the fullscreen chrome (source pin)', () {
      final screen = _codeOf(
          File('lib/features/setup/enroll_capture.dart').readAsStringSync());
      expect(screen.contains('extendBodyBehindAppBar: true'), isTrue);
      expect(screen.contains('extendBody: true'), isTrue);
      expect(screen.contains('Colors.transparent'), isTrue);
      expect(screen.contains('overlayTopInset'), isTrue);
      expect(screen.contains('kToolbarHeight'), isTrue);
    });
  });

  group('mark fills edge-to-edge within its body (no boxing)', () {
    testWidgets('preview Stack fullscreen, button floats as overlay',
        (t) async {
      await t.pumpWidget(_themed(FaceCheckView(
        faceNotice: '',
        canScan: true,
        onScan: () {},
      )));
      await t.pump();
      // THE preview Stack (loose + centered, frame + overlay).
      expect(_previewStackFinder(), findsOneWidget);
      final stack = t.element(_previewStackFinder()).widget as Stack;
      expect(stack.children.first, isA<SizedBox>());
      // No chrome inside the video path: the button floats beside the
      // preview Stack in the outer fullscreen Stack, never inside it.
      expect(stack.children.whereType<Positioned>(), isEmpty);
      expect(find.byType(CaptureOverlay), findsOneWidget);
      // Scan fallback floats above as a bottom-positioned SafeArea overlay.
      expect(find.text('Scan face'), findsOneWidget);
      expect(
          find.ancestor(
              of: find.text('Scan face'),
              matching: find.byWidgetPredicate((w) => w is Positioned)),
          findsWidgets);
      expect(
          find.ancestor(
              of: find.text('Scan face'),
              matching: find.byType(SafeArea)),
          findsWidgets);
      // The outer fullscreen Stack carries the positioned fallback.
      final outer = find.byWidgetPredicate((w) =>
          w is Stack && w.children.whereType<Positioned>().isNotEmpty);
      expect(outer, findsWidgets);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    test('mark source has overlay chrome, zero boxing (source pin)', () {
      final face = _codeOf(
          File('lib/features/mark/face_check.dart').readAsStringSync());
      // Fullscreen overlay structure.
      expect(face.contains('StackFit.loose'), isTrue);
      expect(face.contains('Positioned('), isTrue);
      expect(face.contains('SafeArea('), isTrue);
      // Residual boxing is gone from the portrait layout path.
      expect(face.contains('StackFit.expand'), isFalse);
      expect(face.contains('Column('), isFalse);
      expect(face.contains('Padding('), isFalse);
      // Landscape exception (short-height landscape re-seat): the preview
      // Stack sits beside a side panel via Row+Expanded so the Scan button
      // never covers the prompt. The preview Stack itself keeps the bare
      // loose-centered contract; exactly one Expanded exists, in that
      // branch only.
      expect(face.contains('shortLandscape'), isTrue);
      expect('Expanded('.allMatches(face).length, 1);
      // Single-shot contract intact.
      expect(face.contains('showProgress: false'), isTrue);
      expect(face.contains('showBeacon: false'), isTrue);
      expect(face.contains('faceCheckPrompt'), isTrue);
    });
  });

  group('zero treatment on the video path (both screens)', () {
    testWidgets('mark placeholder: bare direct child, no decoration',
        (t) async {
      await t.pumpWidget(_themed(FaceCheckView(
        faceNotice: '',
        canScan: true,
        onScan: () {},
      )));
      await t.pump();
      expect(_previewStackFinder(), findsOneWidget);
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

    testWidgets('enroll placeholder: bare direct child, no decoration',
        (t) async {
      await t.pumpWidget(_themed(const EnrollCapturePreview(
        controller: null,
        isOpening: false,
        failMessage: null,
        doneCount: 1,
        total: 5,
        nextAngle: 1,
        totalAngles: 5,
        statusLine: 'Rotate your face slowly, following the glow.',
        sweepAngle: 0.5,
        saveError: false,
        saveMessage: '',
      )));
      await t.pump();
      expect(_previewStackFinder(), findsOneWidget);
      final stack = t.element(_previewStackFinder()).widget as Stack;
      expect(stack.children.first, isA<SizedBox>());
      expect(stack.children.whereType<Positioned>(), isEmpty);
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

    test('video-path source has zero treatment (source pin)', () {
      final sections = _codeOf(File(
              'lib/features/setup/enroll_capture_sections.dart')
          .readAsStringSync());
      final face = _codeOf(
          File('lib/features/mark/face_check.dart').readAsStringSync());
      final overlay = _codeOf(
          File('lib/widgets/capture_overlay.dart').readAsStringSync());
      final combined = sections + face + overlay;
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
        'AspectRatio(',
        'BoxDecoration(',
        'LetterboxedPreview',
      ]) {
        expect(combined.contains(ban), isFalse,
            reason: 'treatment on video path: $ban');
      }
      expect(sections.contains('CameraPreview('), isTrue);
      for (final src in [sections, face]) {
        expect(src.contains('StackFit.expand'), isFalse,
            reason: 'force-fill Stack fit stretches the frame');
        expect(src.contains('StackFit.loose'), isTrue);
      }
    });
  });

  group('chrome avoids the notch (SafeArea overlays)', () {
    testWidgets('overlay top bar rides in a SafeArea', (t) async {
      await t.pumpWidget(_themed(const CaptureOverlay(
        progress: 0.4,
        currentAngle: 1,
        totalAngles: 5,
      )));
      await t.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
          find.ancestor(
              of: find.byType(LinearProgressIndicator),
              matching: find.byType(SafeArea)),
          findsWidgets);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('enroll toast rides in a SafeArea', (t) async {
      await t.pumpWidget(_themed(const EnrollCapturePreview(
        controller: null,
        isOpening: false,
        failMessage: null,
        doneCount: 5,
        total: 5,
        nextAngle: 0,
        totalAngles: 5,
        statusLine: 'Rotate your face slowly, following the glow.',
        sweepAngle: null,
        saveError: true,
        saveMessage: 'Could not save — try again.',
      )));
      await t.pump();
      expect(find.text('Could not save — try again.'), findsOneWidget);
      expect(
          find.ancestor(
              of: find.byType(EnrollNotice),
              matching: find.byType(SafeArea)),
          findsWidgets);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('bottom bar is SafeArea-seated (terminal chrome)',
        (t) async {
      Future<void> retry() async {}
      await t.pumpWidget(_themed(EnrollCaptureBottomBar(
        validated: true,
        saveError: false,
        saving: false,
        onContinue: () {},
        onRetry: retry,
      )));
      await t.pump();
      expect(find.text('Continue'), findsOneWidget);
      expect(find.byType(SafeArea), findsWidgets);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    test('overlay chrome is SafeArea-aware (source pin)', () {
      final overlay = _codeOf(
          File('lib/widgets/capture_overlay.dart').readAsStringSync());
      final sections = _codeOf(File(
              'lib/features/setup/enroll_capture_sections.dart')
          .readAsStringSync());
      final face = _codeOf(
          File('lib/features/mark/face_check.dart').readAsStringSync());
      for (final src in [overlay, sections, face]) {
        expect(src.contains('SafeArea('), isTrue);
      }
      // Additive inset exists with a byte-identical default.
      expect(overlay.contains('topInset = 0.0'), isTrue);
      expect(sections.contains('overlayTopInset = 0.0'), isTrue);
      expect(sections.contains('topInset: overlayTopInset'), isTrue);
    });
  });

  group('native aspect intact at 4 ratios, both screens (geometric)', () {
    Future<Rect> pumpMark(
      WidgetTester t, {
      required double boxW,
      required double boxH,
      required double ratio,
    }) async {
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

    Future<Rect> pumpEnroll(
      WidgetTester t, {
      required double boxW,
      required double boxH,
      required double ratio,
    }) async {
      await t.pumpWidget(_themed(SizedBox(
        width: boxW,
        height: boxH,
        child: EnrollCapturePreview(
          controller: null,
          isOpening: false,
          failMessage: null,
          doneCount: 1,
          total: 5,
          nextAngle: 1,
          totalAngles: 5,
          statusLine: 'Rotate your face slowly, following the glow.',
          sweepAngle: 0.5,
          saveError: false,
          saveMessage: '',
          preview: _NativeFeed(ratio: ratio),
          previewAspectRatio: ratio,
        ),
      )));
      await t.pump();
      final rect = t.getRect(find.byKey(const Key('feed')));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      return rect;
    }

    testWidgets('mark keeps 3:4 / 4:3 / 20:9 / 1:1', (t) async {
      for (final c in [
        (800.0, 600.0, 3 / 4),
        (400.0, 800.0, 4 / 3),
        (600.0, 600.0, 20 / 9),
        (400.0, 800.0, 1.0),
      ]) {
        final feed = await pumpMark(t, boxW: c.$1, boxH: c.$2, ratio: c.$3);
        expect(feed.width / feed.height,
            moreOrLessEquals(c.$3, epsilon: 0.02));
      }
    });

    testWidgets('enroll keeps 3:4 / 4:3 / 20:9 / 1:1', (t) async {
      for (final c in [
        (800.0, 400.0, 3 / 4),
        (400.0, 800.0, 4 / 3),
        (600.0, 600.0, 20 / 9),
        (400.0, 800.0, 1.0),
      ]) {
        final feed =
            await pumpEnroll(t, boxW: c.$1, boxH: c.$2, ratio: c.$3);
        expect(feed.width / feed.height,
            moreOrLessEquals(c.$3, epsilon: 0.02));
      }
    });
  });

  group('single-shot vs beacon behaviors unchanged', () {
    testWidgets('mark: static oval + one line, no bar/beacon', (t) async {
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
      expect(overlay.topInset, 0.0);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text(faceCheckPrompt), findsOneWidget);
      expect(find.text(captureGuidePrompt), findsNothing);
      expect(find.text('Scan face'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    test('mark signal mapping unchanged', () {
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

    test('overlay top-inset default keeps standalone rendering identical',
        () {
      const overlay = CaptureOverlay(
        progress: 0.4,
        currentAngle: 1,
        totalAngles: 5,
      );
      expect(overlay.topInset, 0.0);
      expect(overlay.showProgress, isTrue);
      expect(overlay.showBeacon, isTrue);
    });

    testWidgets('enroll full-screen keeps bar + beacon + enroll prompt',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      final overlay =
          t.widget<CaptureOverlay>(find.byType(CaptureOverlay));
      expect(overlay.showProgress, isTrue);
      expect(overlay.showBeacon, isTrue);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text(enrollCapturePrompt), findsOneWidget);
      expect(find.text(faceCheckPrompt), findsNothing);
      expect(find.text(captureGuidePrompt), findsNothing);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(find.text('open-capture'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
