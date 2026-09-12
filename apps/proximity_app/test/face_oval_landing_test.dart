// Face-oval + landing arrangement pins (UI/UX section).
//
// - Guide is a TRUE portrait oval (taller than wide) via drawOval on every
//   viewport — phone + desktop, portrait + landscape sensor boxes. Paint,
//   preview sizing, and thresholds below are untouched (static shape only).
// - Beacon rides the oval rim; the slim progress bar stays above and the
//   one prompt line stays below the oval (clear of the face zone, incl.
//   small screens) — asserted geometrically + on-widget, never by pixels.
// - Landing: "Be there / Be marked" gone; "PROXIMITY" in brand purple moved
//   top -> center with the same treatment; "Campus Attendance System"
//   header sits at the top in contentSecondary. Colors asserted via design
//   tokens, not pixels.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/setup/welcome_sections.dart';
import 'package:proximity_app/screens/face_capture.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';

/// Strips `//` doc/provenance comments so source pins only see code.
String _codeOf(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

Future<void> _settleHero(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  group('face-guide oval geometry (pure)', () {
    test('CaptureOverlay guide stays taller than wide: phone + desktop',
        () {
      const viewports = [
        Size(390, 844), // phone portrait
        Size(360, 640), // small phone
        Size(1280, 800), // desktop
        Size(800, 400), // wide short
      ];
      const aspects = [9 / 16, 3 / 4, 4 / 3, 20 / 9, 1.0, null];
      for (final size in viewports) {
        for (final aspect in aspects) {
          final oval = CaptureOverlay.guideRectForAspect(size, aspect);
          expect(oval.height, greaterThan(oval.width),
              reason: 'portrait oval required: $size aspect=$aspect -> $oval');
          expect(oval.width, greaterThan(0));
          expect(oval.height, greaterThan(0));
        }
      }
    });

    test('still-capture oval stays taller than wide: phone + desktop', () {
      const viewports = [
        Size(390, 844),
        Size(360, 640),
        Size(1280, 800),
        Size(800, 400),
      ];
      for (final size in viewports) {
        final beacon = FaceCaptureOvalOverlay.beaconRectFor(size);
        expect(beacon.height, greaterThan(beacon.width),
            reason: 'portrait oval required: $size -> $beacon');
        expect(beacon.width, greaterThan(0));
        expect(beacon.height, greaterThan(0));
        // Phone portrait follows the shared enrollment-guide fractions
        // (0.80w x 0.60h, no clamp) — one face size on both flows.
        if (size == const Size(390, 844)) {
          expect(beacon.width,
              moreOrLessEquals(size.width * 0.80, epsilon: 0.01));
          expect(beacon.height,
              moreOrLessEquals(size.height * 0.60, epsilon: 0.01));
        }
      }
    });

    test('beacon head stays on the (possibly clamped) oval rim', () {
      const size = Size(1280, 800);
      final oval = CaptureOverlay.guideRectForAspect(size, 20 / 9);
      for (final a in [0.0, 1.0, -1.2, 3.14159]) {
        final p = CaptureOverlay.beaconPointFor(oval, a);
        final nx = (p.dx - oval.center.dx) / (oval.width / 2);
        final ny = (p.dy - oval.center.dy) / (oval.height / 2);
        expect(nx * nx + ny * ny, moreOrLessEquals(1.0, epsilon: 0.001));
      }
    });

    test('prompt top stays clear below the oval on phone + desktop', () {
      const cases = [
        (Size(390, 844), 9 / 16),
        (Size(360, 640), 9 / 16),
        (Size(1280, 800), 9 / 16),
        (Size(1280, 800), 20 / 9),
        (Size(800, 400), 4 / 3),
      ];
      for (final c in cases) {
        final oval = CaptureOverlay.guideRectForAspect(c.$1, c.$2);
        final top = CaptureOverlay.promptTopFor(c.$1, oval);
        expect(top, greaterThanOrEqualTo(oval.bottom + ProxSpacing.md - 0.01),
            reason: 'prompt must clear the face zone: ${c.$1} @${c.$2}');
        expect(top, lessThanOrEqualTo(c.$1.height - ProxSpacing.xxl));
      }
    });

    test('painter draws a true oval, never a rounded rect (source pin)', () {
      final overlay = _codeOf(
          File('lib/widgets/capture_overlay.dart').readAsStringSync());
      expect(overlay.contains('drawOval('), isTrue);
      expect(overlay.contains('drawRRect('), isFalse);
      expect(overlay.contains('RRect.'), isFalse);
      final still = _codeOf(
          File('lib/screens/face_capture.dart').readAsStringSync());
      expect(still.contains('drawOval('), isTrue);
      expect(still.contains('drawRRect('), isFalse);
    });
  });

  group('overlay chrome non-overlap on widgets (phone + desktop)', () {
    // Sizes the test surface itself: a SizedBox larger than the default
    // 800x600 surface is clamped by the Scaffold's tight body constraints,
    // so the overlay would measure the screen instead of (w,h).
    Future<void> checkChrome(
      WidgetTester t, {
      required double w,
      required double h,
      required double aspect,
    }) async {
      t.view.physicalSize = Size(w, h);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: Scaffold(
          body: CaptureOverlay(
            progress: 0.4,
            currentAngle: 1,
            totalAngles: 5,
            previewAspectRatio: aspect,
          ),
        ),
      ));
      await t.pump();
      expect(find.byType(CaptureOverlay), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.text(captureGuidePrompt), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      final size = t.getSize(find.byType(CaptureOverlay).first);
      expect(size.width, moreOrLessEquals(w, epsilon: 1.0));
      expect(size.height, moreOrLessEquals(h, epsilon: 1.0));
      final oval = CaptureOverlay.guideRectForAspect(size, aspect);
      final overlayBox =
          t.getRect(find.byType(CaptureOverlay).first);
      final promptRect = t.getRect(find.text(captureGuidePrompt));
      final barRect = t.getRect(find.byType(LinearProgressIndicator));
      final ovalShifted = oval.shift(overlayBox.topLeft);
      expect(promptRect.top,
          greaterThanOrEqualTo(ovalShifted.bottom + ProxSpacing.md - 2.0),
          reason: 'prompt $promptRect overlaps oval $ovalShifted @${w}x$h');
      expect(barRect.bottom, lessThanOrEqualTo(ovalShifted.top),
          reason: 'bar $barRect overlaps oval $ovalShifted @${w}x$h');
      expect(promptRect.overlaps(barRect), isFalse);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    }

    testWidgets('phone 390x844 portrait sensor: bar above, prompt below',
        (t) async {
      await checkChrome(t, w: 390, h: 844, aspect: 9 / 16);
    });

    testWidgets('small phone 360x640: prompt clears the face zone',
        (t) async {
      await checkChrome(t, w: 360, h: 640, aspect: 9 / 16);
    });

    testWidgets('desktop 1280x800 portrait sensor: chrome clears oval',
        (t) async {
      await checkChrome(t, w: 1280, h: 800, aspect: 9 / 16);
    });

    testWidgets('still-capture overlay renders on phone + desktop',
        (t) async {
      for (final size in [const Size(390, 844), const Size(1280, 800)]) {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1.0;
        await t.pumpWidget(MaterialApp(
          theme: proxLightTheme(),
          home: const Scaffold(
            body: FaceCaptureOvalOverlay(progress: 0.5),
          ),
        ));
        await t.pump();
        expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
        expect(find.byType(CustomPaint), findsWidgets);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      }
    });
  });

  group('landing arrangement (token-asserted, not pixels)', () {
    testWidgets('header top, brand center, Be-marked gone, order kept',
        (t) async {
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: const Scaffold(body: WelcomeHeroSection()),
      ));
      await _settleHero(t);
      expect(find.text('Campus Attendance System'), findsOneWidget);
      expect(find.text('PROXIMITY'), findsOneWidget);
      expect(find.textContaining('Be there.'), findsNothing);
      expect(find.textContaining('Be marked.'), findsNothing);
      // Vertical order: header above brand above the value subline.
      // Nothing else moved: radar hero + subline + sign-in copy intact.
      final headerY =
          t.getCenter(find.text('Campus Attendance System')).dy;
      final brandY = t.getCenter(find.text('PROXIMITY')).dy;
      final subY = t
          .getCenter(find.textContaining('Room presence over Bluetooth.'))
          .dy;
      expect(headerY, lessThan(brandY));
      expect(brandY, lessThan(subY));
      expect(find.textContaining('Offline in class.'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('brand keeps its purple; header uses secondary (tokens)',
        (t) async {
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: const Scaffold(body: WelcomeHeroSection()),
      ));
      await _settleHero(t);
      final c = ProximityColors.light();
      final brand =
          t.widget<Text>(find.text('PROXIMITY'));
      final header =
          t.widget<Text>(find.text('Campus Attendance System'));
      // Same typeface/weight/purple/tracking, scaled to display size.
      expect(brand.style?.color, c.accentBrand);
      expect(brand.style?.letterSpacing, 4.0);
      expect(brand.style?.fontSize, ProxType.displaySize);
      expect(brand.style?.fontWeight, FontWeight.w700);
      // Header: same typeface/weight, present-green, readable secondary
      // size (not the main text, but legible).
      expect(header.style?.color, c.statusMarked);
      expect(header.style?.letterSpacing, 2.0);
      expect(header.style?.fontSize, 15);
      expect(header.style?.fontWeight, FontWeight.w700);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  });
}
