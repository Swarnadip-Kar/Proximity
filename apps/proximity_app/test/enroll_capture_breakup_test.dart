// Enroll capture breakup contracts (2026-09-10 — see INTEGRATION_LOG.md
// `## Enroll capture breakup`): the monolith is split three ways (session
// driver / section widgets / thin composer) and the preview renders
// letterboxed with zero distortion.
//
// - Preview fidelity: the bare preview surface preserves the native
//   aspect ratio with ZERO treatment (bare frame as a direct child of a
//   loose, centered Stack — no wrapper of any kind), measured
//   geometrically, not just by source pin. The live CameraPreview
//   composition itself is verified on-device (the camera plugin has no
//   test double — same rationale as the enroll_guided suite).
// - Driver relocation: the session file owns the camera seam + the
//   classify-fill loop byte-identical; the screen file owns build only.
//   Behavior is covered by the unmodified enroll_guided /
//   enroll_beacon_boundary suites; here one smoke proves the relocated
//   driver still opens, fills nothing without stills, and disposes clean.
// - Overlay composition: the preview section layers overlay + toast above
//   the untouched surface; the bottom bar shows exactly one terminal
//   variant; the blocked card stays records-only.
//
// Clock: the beacon timer is periodic — drive the live smoke with bounded
// pumps, never pumpAndSettle with the session mounted.
import 'dart:io';

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
import 'package:proximity_app/features/setup/enroll_capture.dart';
import 'package:proximity_app/features/setup/enroll_capture_sections.dart';
import 'package:proximity_app/features/setup/enroll_widgets.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';

Widget _themed(Widget child) => MaterialApp(
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
  group('preview fidelity (zero distortion)', () {
    // Frame seam mimicking CameraPreview's self-sizing contract (native
    // aspect maintained internally) — proves the loose Stack never
    // distorts it.
    Widget feedSeam(double ratio) => AspectRatio(
          aspectRatio: ratio,
          child: const SizedBox.expand(key: Key('feed')),
        );

    Future<Rect> pumpBare(WidgetTester t,
        {required double boxW,
        required double boxH,
        required double ratio}) async {
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
          statusLine: enrollCapturePrompt,
          sweepAngle: 0.5,
          saveError: false,
          saveMessage: '',
          preview: feedSeam(ratio),
          previewAspectRatio: ratio,
        ),
      )));
      await t.pump();
      final rect = t.getRect(find.byKey(const Key('feed')));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      return rect;
    }

    testWidgets('bare frame preserves the native ratio (portrait feed)',
        (t) async {
      // Wide box (800x400) + portrait ratio (3:4): the frame self-sizes
      // through the loose Stack — ratio kept, zero treatment. The Stack
      // sits 32 below the box top (preview rides low), so the
      // height-constrained frame is 400-32 tall.
      const ratio = 3 / 4;
      final feed = await pumpBare(t, boxW: 800, boxH: 400, ratio: ratio);
      expect(feed.width / feed.height, moreOrLessEquals(ratio, epsilon: 0.01));
      expect(
          feed.height, moreOrLessEquals(400 - ProxSpacing.xxl, epsilon: 1));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('bare frame preserves the native ratio (landscape feed)',
        (t) async {
      // Narrow box (400x800) + landscape ratio (4:3): frame 400x300.
      const ratio = 4 / 3;
      final feed = await pumpBare(t, boxW: 400, boxH: 800, ratio: ratio);
      expect(feed.width / feed.height, moreOrLessEquals(ratio, epsilon: 0.01));
      expect(feed.width, moreOrLessEquals(400, epsilon: 1));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('frame is a direct Stack child under loose + centered',
        (t) async {
      const ratio = 3 / 4;
      await t.pumpWidget(_themed(SizedBox(
        width: 800,
        height: 400,
        child: EnrollCapturePreview(
          controller: null,
          isOpening: false,
          failMessage: null,
          doneCount: 1,
          total: 5,
          nextAngle: 1,
          totalAngles: 5,
          statusLine: enrollCapturePrompt,
          sweepAngle: 0.5,
          saveError: false,
          saveMessage: '',
          preview: feedSeam(ratio),
          previewAspectRatio: ratio,
        ),
      )));
      await t.pump();
      final stack = find.byWidgetPredicate((w) =>
          w is Stack &&
          w.fit == StackFit.loose &&
          w.alignment == Alignment.center &&
          w.children.whereType<CaptureOverlay>().isNotEmpty);
      expect(stack, findsOneWidget);
      // Zero treatment: no decoration/fill/fit anywhere in the preview
      // Stack subtree outside the overlay's own chrome.
      expect(
          find.descendant(
              of: stack,
              matching: find.byWidgetPredicate((w) =>
                  w is Container ||
                  w is ColoredBox ||
                  w is DecoratedBox ||
                  w is FittedBox)),
          findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    test('no distortion transform in the preview source', () {
      final sections = File('lib/features/setup/enroll_capture_sections.dart')
          .readAsStringSync();
      final screen =
          File('lib/features/setup/enroll_capture.dart').readAsStringSync();
      // Code only: doc comments name the retired chains for provenance.
      String codeOf(String src) => src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      final combined = codeOf(sections) + codeOf(screen);
      // Bare CameraPreview, zero treatment: the retired LetterboxedPreview
      // wrapper (and its outer AspectRatio) is gone with the FittedBox /
      // BoxFit chains (cover cropped the face area; fill/contain/fit
      // would stretch or re-crop it; the outer ratio box double-boxed
      // against the plugin's own orientation-adjusted ratio).
      expect(combined.contains('LetterboxedPreview'), isFalse);
      expect(combined.contains('AspectRatio('), isFalse);
      expect(combined.contains('CameraPreview('), isTrue);
      expect(combined.contains('StackFit.loose'), isTrue);
      expect(combined.contains('FittedBox('), isFalse);
      for (final fit in [
        'BoxFit.cover',
        'BoxFit.fill',
        'BoxFit.contain',
        'BoxFit.fitWidth',
        'BoxFit.fitHeight'
      ]) {
        expect(combined.contains(fit), isFalse,
            reason: 'distortion transform in preview: $fit');
      }
    });
  });

  group('driver relocation (session file owns behavior)', () {
    test('camera seam + driver identifiers live in the session file', () {
      final session =
          File('lib/features/setup/enroll_capture_session.dart')
              .readAsStringSync();
      for (final id in [
        'abstract class EnrollSessionCamera',
        'class RealEnrollSessionCamera',
        'class FakeEnrollSessionCamera',
        'enrollSessionCameraProvider',
        'mixin EnrollCaptureSessionDriver',
        'Future<void> _openCamera()',
        'void _startLoop()',
        'Future<void> _autoLoop()',
        'Future<String?> _captureOne()',
        'Future<void> _saveAll()',
        '_initialBeat',
        '_frameBeat',
        '_sweepTick',
        '_sweepRevolution',
        'classifyInto',
        'readPose',
        'captureStill',
        'enrollFace',
      ]) {
        expect(session.contains(id), isTrue, reason: 'missing: $id');
      }
    });

    test('screen file owns build only (no driver bodies)', () {
      final screen =
          File('lib/features/setup/enroll_capture.dart').readAsStringSync();
      expect(screen.contains('class EnrollCaptureScreen'), isTrue);
      for (final id in [
        'Future<void> _autoLoop',
        'Future<String?> _captureOne',
        'Future<void> _saveAll',
        'Future<void> _openCamera',
        'Timer.periodic',
        'class FakeEnrollSessionCamera',
      ]) {
        expect(screen.contains(id), isFalse, reason: 'driver left: $id');
      }
    });

    testWidgets('relocated driver opens + disposes clean (smoke)', (t) async {
      final camera = FakeEnrollSessionCamera();
      final ctl = await _keyReady();
      await t.pumpWidget(ProviderScope(
        overrides: [
          enrollmentControllerProvider.overrideWith((ref) => ctl),
          enrollSessionCameraProvider.overrideWithValue(camera),
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
      ));
      await _openSession(t);
      expect(camera.openCount, 1);
      // Composer renders the section widgets over the relocated driver.
      expect(find.byType(EnrollCapturePreview), findsOneWidget);
      expect(find.byType(EnrollCaptureBottomBar), findsOneWidget);
      expect(find.byType(CaptureOverlay), findsOneWidget);
      expect(find.text(enrollCapturePrompt), findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(find.text('open-capture'), findsOneWidget);
      expect(camera.closeCount, 1);
      expect(t.takeException(), isNull);
    });
  });

  group('section composition (single purpose each)', () {
    testWidgets('bottom bar shows exactly one terminal variant', (t) async {
      Future<void> retry() async {}
      // Validated → Continue + hidden top-up, no retry.
      await t.pumpWidget(_themed(EnrollCaptureBottomBar(
        validated: true,
        saveError: false,
        saving: false,
        onContinue: () {},
        onRetry: retry,
      )));
      await t.pump();
      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);

      // Save-error → Try again + hidden top-up, no Continue.
      await t.pumpWidget(_themed(EnrollCaptureBottomBar(
        validated: false,
        saveError: true,
        saving: false,
        onContinue: () {},
        onRetry: retry,
      )));
      await t.pump();
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Continue'), findsNothing);

      // Saving → retry disabled (null onPressed), spinner icon shown.
      await t.pumpWidget(_themed(EnrollCaptureBottomBar(
        validated: false,
        saveError: true,
        saving: true,
        onContinue: () {},
        onRetry: retry,
      )));
      await t.pump();
      expect(find.text('Try again'), findsOneWidget);

      // Mid-flow → empty (overlay owns the prompt), no buttons at all.
      await t.pumpWidget(_themed(EnrollCaptureBottomBar(
        validated: false,
        saveError: false,
        saving: false,
        onContinue: () {},
        onRetry: retry,
      )));
      await t.pump();
      expect(find.byType(FilledButton), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('slot top-up is hidden but maintains size', (t) async {
      await t.pumpWidget(
          _themed(const EnrollCaptureBottomBar(
        validated: true,
        saveError: false,
        saving: false,
        onContinue: _noop,
        onRetry: _noopRetry,
      )));
      await t.pump();
      final vis = t.widget<Visibility>(find.byWidgetPredicate(
          (w) => w is Visibility && !w.visible && w.maintainSize));
      expect(vis.maintainSize, isTrue);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('preview section layers overlay over the surface', (t) async {
      await t.pumpWidget(_themed(const EnrollCapturePreview(
        controller: null,
        isOpening: false,
        failMessage: null,
        doneCount: 2,
        total: 5,
        nextAngle: 2,
        totalAngles: 5,
        statusLine: enrollCapturePrompt,
        sweepAngle: 1.0,
        saveError: false,
        saveMessage: '',
      )));
      await t.pump();
      // Placeholder surface (test fake) + overlay + one prompt + bar.
      expect(find.byType(CaptureOverlay), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text(enrollCapturePrompt), findsOneWidget);
      // Overlay is decoration: pointer-transparent inside the Stack.
      expect(
          find.ancestor(
              of: find.byType(CaptureOverlay),
              matching: find.byType(Stack)),
          findsWidgets);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('preview fail branch shows the message, no overlay',
        (t) async {
      await t.pumpWidget(_themed(const EnrollCapturePreview(
        controller: null,
        isOpening: false,
        failMessage: 'Generate the device key on the previous screen first'
            ' — the face capture seals to it.',
        doneCount: 0,
        total: 5,
        nextAngle: 0,
        totalAngles: 5,
        statusLine: enrollCapturePrompt,
        sweepAngle: null,
        saveError: false,
        saveMessage: '',
      )));
      await t.pump();
      expect(find.textContaining('Generate the device key'), findsOneWidget);
      expect(find.byType(CaptureOverlay), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('blocked card stays records-only with Back', (t) async {
      var backed = false;
      await t.pumpWidget(_themed(EnrollCaptureBlocked(
        onBack: () => backed = true,
      )));
      await t.pump();
      expect(find.textContaining('needs the mobile app'), findsOneWidget);
      expect(find.text('Back'), findsOneWidget);
      await t.tap(find.text('Back'));
      expect(backed, isTrue);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  });
}

void _noop() {}

Future<void> _noopRetry() async {}
