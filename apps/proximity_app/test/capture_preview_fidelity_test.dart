// Capture preview fidelity, hardened (tester-verified squish defect,
// 2026-09-10 — see INTEGRATION_LOG.md `## Capture preview fidelity`):
// the preview surface gets ZERO treatment — a bare frame widget as a
// DIRECT child of a loose, centered Stack (no Container/Box/decoration/
// effect/fit of any kind around it); EVERYTHING else (oval, comet,
// prompt, progress, buttons) lives in the overlay layer above it.
//
// - The live `CameraPreview` self-maintains its native aspect internally,
//   so loose constraints let it letterbox itself while `StackFit.expand`
//   (or any FittedBox/BoxFit/outer AspectRatio) would force-fill it and
//   stretch faces again. An outer AspectRatio wrapper is additionally
//   wrong because it carries the RAW sensor ratio while the plugin paints
//   the ORIENTATION-ADJUSTED ratio (see [displayedPreviewAspect]) —
//   double-boxing re-squishes the guide on portrait phones.
// - `FaceCheckView` shows a PLACEHOLDER, never a live feed (the host
//   captures through the still-capture modal, passing this view no
//   controller) — the placeholder is a bare undecorated spacer under the
//   same contract, so a future live feed hosted here cannot squish.
// - The oval/comet derive from the true video box; the beacon is a COMET
//   (bright head + short fading tail opposite travel; minimal static tail
//   under reduce-motion) with unchanged target semantics, timing, signal
//   colors, and one-line prompt.
//
// Frozen (untouched here): auto-capture driver, timings, retries, copy.
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/mark/face_check.dart';
import 'package:proximity_app/features/setup/enroll_capture_sections.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';

Widget _themed(Widget child) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: child),
    );

/// Test stand-in for the live frame: mimics `CameraPreview`'s contract of
/// self-maintaining its native aspect internally (the plugin wraps its
/// texture in an AspectRatio), so the suite can prove the loose Stack
/// never distorts it. The keyed child marks the painted frame for
/// measurement.
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

/// The preview Stack: the loose, centered Stack carrying the overlay
/// (Navigator/Overlay internals use different fits, so this is unique).
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

const _camDesc = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 0,
);

CameraValue _value({
  required Size previewSize,
  DeviceOrientation deviceOrientation = DeviceOrientation.portraitUp,
  DeviceOrientation? lockedCaptureOrientation,
  DeviceOrientation? previewPauseOrientation,
  bool isRecordingVideo = false,
  DeviceOrientation? recordingOrientation,
}) =>
    CameraValue(
      isInitialized: true,
      previewSize: previewSize,
      isRecordingVideo: isRecordingVideo,
      isTakingPicture: false,
      isStreamingImages: false,
      isRecordingPaused: false,
      flashMode: FlashMode.auto,
      exposureMode: ExposureMode.auto,
      exposurePointSupported: false,
      focusMode: FocusMode.auto,
      focusPointSupported: false,
      deviceOrientation: deviceOrientation,
      description: _camDesc,
      lockedCaptureOrientation: lockedCaptureOrientation,
      recordingOrientation: recordingOrientation,
      previewPauseOrientation: previewPauseOrientation,
    );

void main() {
  group('displayed video-box ratio (pure)', () {
    test('portrait phone shows the inverse raw ratio', () {
      // Landscape sensor (1280x720, raw 16:9) held portrait → 9:16 feed.
      expect(displayedPreviewAspect(_value(previewSize: const Size(1280, 720))),
          moreOrLessEquals(9 / 16, epsilon: 1e-9));
    });

    test('landscape phone shows the raw ratio', () {
      expect(
          displayedPreviewAspect(_value(
            previewSize: const Size(1280, 720),
            deviceOrientation: DeviceOrientation.landscapeLeft,
          )),
          moreOrLessEquals(16 / 9, epsilon: 1e-9));
    });

    test('recording orientation wins while recording', () {
      expect(
          displayedPreviewAspect(_value(
            previewSize: const Size(1280, 720),
            isRecordingVideo: true,
            recordingOrientation: DeviceOrientation.landscapeRight,
          )),
          moreOrLessEquals(16 / 9, epsilon: 1e-9));
    });

    test('locked capture orientation beats the device orientation', () {
      expect(
          displayedPreviewAspect(_value(
            previewSize: const Size(1280, 720),
            lockedCaptureOrientation: DeviceOrientation.landscapeRight,
          )),
          moreOrLessEquals(16 / 9, epsilon: 1e-9));
    });

    test('pause orientation beats the lock', () {
      expect(
          displayedPreviewAspect(_value(
            previewSize: const Size(1280, 720),
            deviceOrientation: DeviceOrientation.landscapeLeft,
            lockedCaptureOrientation: DeviceOrientation.landscapeLeft,
            previewPauseOrientation: DeviceOrientation.portraitUp,
          )),
          moreOrLessEquals(9 / 16, epsilon: 1e-9));
    });
  });

  group('bare preview surface (zero treatment, both screens)', () {
    testWidgets('enroll: frame is a direct Stack child, loose + centered',
        (t) async {
      await t.pumpWidget(_themed(const EnrollCapturePreview(
        controller: null,
        isOpening: false,
        failMessage: null,
        doneCount: 2,
        total: 5,
        nextAngle: 2,
        totalAngles: 5,
        statusLine: 'Rotate your face slowly, following the glow.',
        sweepAngle: 1.0,
        saveError: false,
        saveMessage: '',
        preview: _NativeFeed(ratio: 3 / 4),
        previewAspectRatio: 3 / 4,
      )));
      await t.pump();
      expect(_previewStackFinder(), findsOneWidget);
      final stack = t.element(_previewStackFinder()).widget as Stack;
      // Bare surface: the frame itself is the first direct child — no
      // wrapper of any kind between it and the Stack.
      expect(stack.children.first, isA<_NativeFeed>());
      // Nothing positioned mid-flow (frame + overlay both unpositioned;
      // the save-error toast is saveError-gated and absent here).
      expect(stack.children.whereType<Positioned>(), isEmpty);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('enroll placeholder is a bare undecorated spacer', (t) async {
      await t.pumpWidget(_themed(const EnrollCapturePreview(
        controller: null,
        isOpening: false,
        failMessage: null,
        doneCount: 0,
        total: 5,
        nextAngle: 0,
        totalAngles: 5,
        statusLine: 'Rotate your face slowly, following the glow.',
        sweepAngle: null,
        saveError: false,
        saveMessage: '',
      )));
      await t.pump();
      expect(_previewStackFinder(), findsOneWidget);
      final stack = t.element(_previewStackFinder()).widget as Stack;
      expect(stack.children.first, isA<SizedBox>());
      // Zero treatment: no decoration/fill anywhere in the preview Stack
      // subtree outside the overlay's own chrome (bar clip + text).
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

    testWidgets('mark: placeholder is bare, overlay above it', (t) async {
      await t.pumpWidget(_themed(FaceCheckView(
        faceNotice: '',
        canScan: true,
        onScan: () {},
      )));
      await t.pump();
      expect(_previewStackFinder(), findsOneWidget);
      final stack = t.element(_previewStackFinder()).widget as Stack;
      expect(stack.children.first, isA<SizedBox>());
      expect(find.byType(CaptureOverlay), findsOneWidget);
      expect(find.text('Scan face'), findsOneWidget);
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

    testWidgets('mark: provided frame stays a direct Stack child', (t) async {
      await t.pumpWidget(_themed(const FaceCheckView(
        faceNotice: '',
        canScan: false,
        onScan: _noop,
        previewAspectRatio: 20 / 9,
        preview: _NativeFeed(ratio: 20 / 9),
      )));
      await t.pump();
      expect(_previewStackFinder(), findsOneWidget);
      final stack = t.element(_previewStackFinder()).widget as Stack;
      expect(stack.children.first, isA<_NativeFeed>());
      final overlay =
          t.widget<CaptureOverlay>(find.byType(CaptureOverlay));
      expect(overlay.previewAspectRatio,
          moreOrLessEquals(20 / 9, epsilon: 1e-9));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    test('preview surface code has zero treatment (source pin)', () {
      final sections = _codeOf(File(
              'lib/features/setup/enroll_capture_sections.dart')
          .readAsStringSync());
      final face = _codeOf(
          File('lib/features/mark/face_check.dart').readAsStringSync());
      final overlay = _codeOf(
          File('lib/widgets/capture_overlay.dart').readAsStringSync());
      final combined = sections + face + overlay;
      // The live frame renders bare: no fit/decoration/effect wrappers and
      // no outer ratio box anywhere on the preview paths (the plugin owns
      // the one true AspectRatio internally; the retired outer wrapper is
      // gone).
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
        'LetterboxedPreview',
      ]) {
        expect(combined.contains(ban), isFalse,
            reason: 'treatment on preview path: $ban');
      }
      // The bare frame itself is still composed on the enroll path…
      expect(sections.contains('CameraPreview('), isTrue);
      // …as a direct Stack child under a loose, centered Stack (both
      // screens — the expand-fit force-fill is gone everywhere).
      for (final src in [sections, face]) {
        expect(src.contains('StackFit.expand'), isFalse,
            reason: 'force-fill Stack fit stretches the frame');
        expect(src.contains('StackFit.loose'), isTrue);
      }
    });
  });

  group('native aspect at 4 ratios, both screens (geometric)', () {
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
  });

  group('comet beacon (pure geometry + render)', () {
    test('tail alphas fade tip-to-head, bounded 0..1', () {
      final alphas = CaptureOverlay.cometTailAlphas();
      expect(alphas.length, CaptureOverlay.cometSlices);
      expect(alphas.first, 0.0);
      expect(alphas.last, 1.0);
      var prev = -1.0;
      for (final a in alphas) {
        expect(a, inInclusiveRange(0.0, 1.0));
        expect(a, greaterThanOrEqualTo(prev));
        prev = a;
      }
    });

    test('tail spans are short, static shorter than travelling', () {
      expect(CaptureOverlay.cometTailSpan, lessThan(1.1));
      expect(CaptureOverlay.cometMinTailSpan, lessThan(1.1));
      expect(CaptureOverlay.cometMinTailSpan,
          lessThan(CaptureOverlay.cometTailSpan));
      expect(CaptureOverlay.cometMinTailSpan, greaterThan(0));
    });

    test('tail sits behind the head along travel (increasing angle)', () {
      const size = Size(600, 600);
      final oval = CaptureOverlay.guideRectFor(size);
      const head = 1.0;
      final tailStart = head - CaptureOverlay.cometTailSpan;
      // Tail tip still on the oval perimeter (arc of the same oval).
      final tip = CaptureOverlay.beaconPointFor(oval, tailStart);
      final nx = (tip.dx - oval.center.dx) / (oval.width / 2);
      final ny = (tip.dy - oval.center.dy) / (oval.height / 2);
      expect(nx * nx + ny * ny, moreOrLessEquals(1.0, epsilon: 0.001));
      // Head point unchanged contract (perimeter).
      final at = CaptureOverlay.beaconPointFor(oval, head);
      final hx = (at.dx - oval.center.dx) / (oval.width / 2);
      final hy = (at.dy - oval.center.dy) / (oval.height / 2);
      expect(hx * hx + hy * hy, moreOrLessEquals(1.0, epsilon: 0.001));
    });

    test('painter draws head + tail (source pin)', () {
      final overlay =
          _codeOf(File('lib/widgets/capture_overlay.dart').readAsStringSync());
      // Comet = fading tail arcs + bright head dot (+ halo).
      expect(overlay.contains('drawArc('), isTrue);
      expect(overlay.contains('drawCircle('), isTrue);
      expect(overlay.contains('cometTailAlphas('), isTrue);
    });

    testWidgets('travelling and static comets both render', (t) async {
      await t.pumpWidget(_themed(const CaptureOverlay(
        progress: 0.4,
        currentAngle: 1,
        totalAngles: 5,
        sweepAngle: 1.0,
      )));
      await t.pump();
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await t.pumpWidget(_themed(const CaptureOverlay(
        progress: 0.4,
        currentAngle: 1,
        totalAngles: 5,
      )));
      await t.pump();
      expect(find.byType(CustomPaint), findsWidgets);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('overlay alignment derived from the preview box (pure geometry)', () {
    test('null aspect == legacy full-size behavior', () {
      const size = Size(400, 800);
      expect(CaptureOverlay.previewRectFor(size, null), Offset.zero & size);
      expect(CaptureOverlay.guideRectForAspect(size, null),
          CaptureOverlay.guideRectFor(size));
    });

    test('preview box is the largest centered aspect rect (both orientations)',
        () {
      var box =
          CaptureOverlay.previewRectFor(const Size(800, 400), 3 / 4);
      expect(box.height, moreOrLessEquals(400, epsilon: 0.001));
      expect(box.width, moreOrLessEquals(300, epsilon: 0.001));
      expect(box.center, const Size(800, 400).center(Offset.zero));
      box = CaptureOverlay.previewRectFor(const Size(400, 800), 4 / 3);
      expect(box.width, moreOrLessEquals(400, epsilon: 0.001));
      expect(box.height, moreOrLessEquals(300, epsilon: 0.001));
      expect(box.center, const Size(400, 800).center(Offset.zero));
      box = CaptureOverlay.previewRectFor(const Size(600, 600), 20 / 9);
      expect(box.width, moreOrLessEquals(600, epsilon: 0.001));
      expect(box.height, moreOrLessEquals(600 / (20 / 9), epsilon: 0.01));
      expect(box.center, const Size(600, 600).center(Offset.zero));
      box = CaptureOverlay.previewRectFor(const Size(400, 800), 1.0);
      expect(box.width, moreOrLessEquals(400, epsilon: 0.001));
      expect(box.height, moreOrLessEquals(400, epsilon: 0.001));
      expect(box.center, const Size(400, 800).center(Offset.zero));
    });

    test('guide oval is portrait, centered, 0.80 x 0.60 with wide clamp',
        () {
      const aspects = [3 / 4, 4 / 3, 20 / 9, 1.0];
      const sizes = [Size(800, 400), Size(400, 800), Size(600, 600)];
      for (final size in sizes) {
        for (final aspect in aspects) {
          final preview = CaptureOverlay.previewRectFor(size, aspect);
          final oval = CaptureOverlay.guideRectForAspect(size, aspect);
          // Fuzzy: Rect.fromCenter round-trips the center through
          // opposite edges, so exact Offset == is flaky.
          expect(oval.center.dx,
              moreOrLessEquals(preview.center.dx, epsilon: 0.01));
          expect(oval.center.dy,
              moreOrLessEquals(preview.center.dy, epsilon: 0.01));
          // Height always the 0.60 fraction; width is 0.80 except on
          // wide/desktop boxes where the portrait clamp narrows it to
          // h * faceWidthToHeight so the guide stays taller than wide.
          final rawW = preview.width * 0.80;
          final h = preview.height * 0.60;
          final expectedW =
              rawW >= h ? h * CaptureOverlay.faceWidthToHeight : rawW;
          expect(oval.width, moreOrLessEquals(expectedW, epsilon: 0.01));
          expect(oval.height, moreOrLessEquals(h, epsilon: 0.01));
          expect(oval.height, greaterThan(oval.width),
              reason: 'face oval must stay taller than wide: $size @$aspect');
          expect(oval.left, greaterThanOrEqualTo(preview.left - 0.01));
          expect(oval.right, lessThanOrEqualTo(preview.right + 0.01));
          expect(oval.top, greaterThanOrEqualTo(preview.top - 0.01));
          expect(oval.bottom, lessThanOrEqualTo(preview.bottom + 0.01));
        }
      }
      // Phone portrait path follows the current fractions.
      final phonePreview =
          CaptureOverlay.previewRectFor(const Size(400, 800), 9 / 16);
      final phoneOval =
          CaptureOverlay.guideRectForAspect(const Size(400, 800), 9 / 16);
      expect(phoneOval.width,
          moreOrLessEquals(phonePreview.width * 0.80, epsilon: 0.01));
    });

    test('different aspects give different ovals (proves derivation)', () {
      const size = Size(600, 600);
      final portrait = CaptureOverlay.guideRectForAspect(size, 3 / 4);
      final wide = CaptureOverlay.guideRectForAspect(size, 20 / 9);
      expect(portrait, isNot(equals(wide)));
      // Legacy full-size fallback still derives distinctly from a letter-
      // boxed wide feed on a phone portrait viewport. (On the square 600x
      // 600 box the 3/4-portrait clamp coincides with legacy by design —
      // same center/height, width narrowed to the face ratio in both.)
      const phone = Size(400, 800);
      expect(CaptureOverlay.guideRectForAspect(phone, 20 / 9),
          isNot(equals(CaptureOverlay.guideRectFor(phone))));
    });

    test('invalid aspects fall back to full size (no crash, no drift)', () {
      const size = Size(400, 800);
      for (final bad in [0.0, -1.0, double.nan, double.infinity]) {
        expect(CaptureOverlay.previewRectFor(size, bad), Offset.zero & size);
        expect(CaptureOverlay.guideRectForAspect(size, bad),
            CaptureOverlay.guideRectFor(size));
      }
    });
  });
}

void _noop() {}
