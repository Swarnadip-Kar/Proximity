// Enrollment boundary + beacon + two-oval contracts.
// (UI-boundary overflow fix, area stability, overlay layering verdict.)
//
// Elongation root cause was bottom-slot sizing (single prompt vs original
// prompt+status+button enlarged the preview area; Stack tight +
// CameraPreview AspectRatio-ignore stretches the feed to the area), so these
// pin the device-boundary path: Scaffold defaults, no SafeArea double-apply,
// no constraining wrappers/fixed boxes in the preview path, AppBar height,
// identical preview area in EVERY lifecycle variant (mid-flow, validated,
// save-error, after back-navigation), and the researched layering decision
// (chrome stays overlay — the two-oval overlay paints inside the preview
// Stack, prompt/buttons sit in the bottom bar, never inline above the feed,
// never copy inside the Stack). Two-oval tests pin green-outer/blue-inner distinctness
// (colors, radii, jobs) and reduced-motion steady glows. Clock: the beacon
// timer is periodic — drive live sessions with bounded pumps, never
// pumpAndSettle with the session mounted (settle only once the loop and
// sweep are stopped: result screen, validated-after-back, save-error).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/setup/enroll_capture.dart';
import 'package:proximity_app/features/setup/enroll_widgets.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/screens/face_capture.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';

/// Fail-closed gallery write that always throws (save-error variant).
class _EnrollBoom extends FakeFaceVerifier {
  _EnrollBoom() : super(match: true, score: 0.9);
  @override
  Future<void> enroll(String faceId, List<String> imagePaths) async {
    throw StateError('No face detected');
  }
}

Future<EnrollmentController> _keyReady({FaceVerifier? verifier}) async {
  final ctl = EnrollmentController(
    auth: FakeAuthService(const SignedAccount(
        email: 's@x.in', displayName: 'S', uid: 'u1')),
    store: InMemoryDeviceStore(),
    verifier: verifier ?? FakeFaceVerifier(),
    deviceKey: FakeDeviceKey(),
  );
  await ctl.signIn();
  await ctl.generateKey();
  return ctl;
}

Widget _captureHarness({required EnrollmentController ctl}) =>
    ProviderScope(
      overrides: [
        enrollmentControllerProvider.overrideWith((ref) => ctl),
        enrollSessionCameraProvider
            .overrideWithValue(FakeEnrollSessionCamera()),
        poseGateProvider.overrideWithValue(FakePoseGate()),
      ],
      child: MaterialApp(
        // App theme: the shared two-oval overlay reads ProximityColors.
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

/// Bounded clock driver for the auto-capture loop (never pumpAndSettle
/// mid-loop — the loop always has its next beat scheduled while running).
Future<void> _pumpUntil(WidgetTester t, Finder f, {int ticks = 60}) async {
  for (var i = 0; i < ticks; i++) {
    if (f.evaluate().isNotEmpty) return;
    await t.pump(const Duration(milliseconds: 200));
  }
  fail('auto-capture loop never settled: $f');
}

/// The preview Stack: the only StackFit.expand Stack carrying the two-oval
/// overlay (Navigator/Overlay internals use loose fits, so this is unique).
Finder _previewStackFinder() => find.byWidgetPredicate((w) =>
    w is Stack &&
    w.fit == StackFit.expand &&
    w.children.whereType<CaptureOverlay>().isNotEmpty);

void main() {
  group('device-boundary parity (elongation fix)', () {
    testWidgets('Scaffold defaults match original (no overflow flags)',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      final scaffold =
          t.element(find.byType(Scaffold).last).widget as Scaffold;
      // Defaults: keyboard-aware, body below AppBar, never behind system UI.
      expect(scaffold.resizeToAvoidBottomInset ?? true, isTrue);
      expect(scaffold.extendBody, isFalse);
      expect(scaffold.extendBodyBehindAppBar, isFalse);
      // Same AppBar height (default toolbar, no custom preferredSize).
      final appBar =
          t.element(find.byType(AppBar).last).widget as AppBar;
      expect(appBar.toolbarHeight, isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('preview path has no SafeArea/constraining/fixed boxes',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      final chain = <Widget>[];
      t.element(find.byType(CaptureOverlay)).visitAncestorElements((a) {
        chain.add(a.widget);
        return true;
      });
      final upToScaffold =
          chain.sublist(0, chain.indexWhere((w) => w is Scaffold) + 1);
      // No SafeArea in the camera path (neither screen has one — no double-apply).
      expect(upToScaffold.whereType<SafeArea>(), isEmpty);
      // No constraining wrappers (would re-elongate the feed).
      for (final ban in [AspectRatio, FittedBox, ConstrainedBox]) {
        expect(upToScaffold.where((w) => w.runtimeType == ban), isEmpty,
            reason: 'constraining wrapper in preview path: $ban');
      }
      // No fixed-size boxes sizing the preview (Expanded+Center only).
      expect(
          upToScaffold.where((w) =>
              w is SizedBox && (w.height != null || w.width != null)),
          isEmpty,
          reason: 'fixed-size box in preview path');
      expect(upToScaffold.whereType<Container>(), isEmpty,
          reason: 'constrained container in preview path');
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('mid-flow keeps single prompt + overlay, reserves original height',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      // Single static prompt + the two-oval overlay exactly (no dots, no
      // per-angle labels — §6.2).
      expect(find.text(enrollCapturePrompt), findsOneWidget);
      expect(find.byType(CaptureOverlay), findsOneWidget);
      // Invisible original-height reservation (boundary parity, no semantics).
      final reservations = find.byWidgetPredicate(
          (w) => w is Visibility && !w.visible && w.maintainSize);
      expect(reservations, findsOneWidget);
      // Reservation carries the original status+button shape (hidden).
      expect(
          find.descendant(
              of: reservations, matching: find.byType(FilledButton)),
          findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });
  });

  group('rotating beacon painter', () {
    test('trail fully fades: tail transparent, head bright, tail short', () {
      // Tail tip fully transparent (no remnant survives to the next pass).
      expect(FaceCaptureOvalOverlay.beaconAlpha(0), 0.0);
      // Head brightest.
      expect(
          FaceCaptureOvalOverlay.beaconAlpha(
              FaceCaptureOvalOverlay.beaconSlices - 1),
          1.0);
      // Monotonic fade head-ward, bounded 0..1.
      var prev = -1.0;
      for (var i = 0; i < FaceCaptureOvalOverlay.beaconSlices; i++) {
        final a = FaceCaptureOvalOverlay.beaconAlpha(i);
        expect(a, inInclusiveRange(0.0, 1.0));
        expect(a, greaterThanOrEqualTo(prev));
        prev = a;
      }
      // SHORT tail: default span well before a full revolution.
      const defaultSpan = 1.047;
      expect(defaultSpan, lessThan(3.141592653589793));
      expect(FaceCaptureOvalOverlay.isSteadyGlow(defaultSpan), isFalse);
    });

    test('reduced motion is a steady soft full-rim glow (no animation)', () {
      const full = 2 * 3.141592653589793;
      expect(FaceCaptureOvalOverlay.isSteadyGlow(full), isTrue);
      // Soft: visible but not harsh full opacity.
      expect(FaceCaptureOvalOverlay.steadyGlowAlpha, greaterThan(0.0));
      expect(FaceCaptureOvalOverlay.steadyGlowAlpha, lessThan(1.0));
    });

    testWidgets('beacon + steady + marking states all render', (t) async {
      // Beacon head mid-travel.
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: FaceCaptureOvalOverlay(
                progress: 0.4, sweepAngle: 1.0, sweepSpan: 1.047)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      // Steady soft full-rim (reduced motion).
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FaceCaptureOvalOverlay(
                progress: 1.0,
                sweepAngle: 0.0,
                sweepSpan: 2 * 3.141592653589793)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      // Marking (null sweep) unchanged.
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: FaceCaptureOvalOverlay(progress: 1.0)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('two role-separated ovals (green progress, blue beacon)', () {
    test('progress green is the token completion green, never beacon blue',
        () {
      expect(FaceCaptureOvalOverlay.progressGreen,
          ProxStateColors.markedDark);
      expect(FaceCaptureOvalOverlay.progressGreen, const Color(0xFF4ADE80));
      // Distinct hues from the beacon blue in both brightnesses.
      expect(FaceCaptureOvalOverlay.progressGreen,
          isNot(ProxPalette.primaryLight));
      expect(FaceCaptureOvalOverlay.progressGreen,
          isNot(ProxPalette.primaryDark));
    });

    test('progress radius larger than beacon radius on both axes', () {
      expect(FaceCaptureOvalOverlay.progressWidthFraction,
          greaterThan(FaceCaptureOvalOverlay.beaconWidthFraction));
      expect(FaceCaptureOvalOverlay.progressHeightFraction,
          greaterThan(FaceCaptureOvalOverlay.beaconHeightFraction));
      const size = Size(400, 600);
      final beacon = FaceCaptureOvalOverlay.beaconRectFor(size);
      final outer = FaceCaptureOvalOverlay.progressRectFor(size,
          enrollment: true);
      expect(outer.width, greaterThan(beacon.width));
      expect(outer.height, greaterThan(beacon.height));
      expect(outer.center, beacon.center);
      // Marking path keeps the legacy rect (identical pixels).
      expect(
          FaceCaptureOvalOverlay.progressRectFor(size, enrollment: false),
          beacon);
    });

    test('progress paint green in enrollment, legacy color at marking', () {
      const fallback = Color(0xFF4340D6);
      expect(
          FaceCaptureOvalOverlay.progressColorFor(
              enrollment: true, fallback: fallback),
          FaceCaptureOvalOverlay.progressGreen);
      expect(
          FaceCaptureOvalOverlay.progressColorFor(
              enrollment: false, fallback: fallback),
          fallback);
    });

    testWidgets('enrollment green arc + beacon render together', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: FaceCaptureOvalOverlay(
                progress: 0.6, sweepAngle: 1.0, sweepSpan: 1.047)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('preview area identical across lifecycle variants', () {
    testWidgets('forward then back: validated area equals capturing area',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      expect(_previewStackFinder(), findsOneWidget);
      final capturingSize = t.getSize(_previewStackFinder());
      // All 5 buckets validate → auto-advance to the result step.
      await _pumpUntil(t, find.text('Save enrollment'));
      // Result screen is static: settle its entrance before going back.
      await t.pumpAndSettle();
      // System back pops only the result: capture returns validated
      // (loop stopped, sweep stopped — settle-safe) with Continue chrome.
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.byType(EnrollCaptureScreen), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
      // Single-prompt rule: no instructional text in the terminal state.
      expect(find.text(enrollCapturePrompt), findsNothing);
      // The feed area never moved (no mid-flow expansion on return).
      expect(_previewStackFinder(), findsOneWidget);
      expect(t.getSize(_previewStackFinder()), capturingSize);
      expect(t.takeException(), isNull);
      // Drain via cancel (disposes the session camera).
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(find.text('open-capture'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('save-error area equals capturing area (short message)',
        (t) async {
      final ctl = await _keyReady(verifier: _EnrollBoom());
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      expect(_previewStackFinder(), findsOneWidget);
      final capturingSize = t.getSize(_previewStackFinder());
      // All 5 stills accepted, gallery write throws → fail-closed error bar
      // (loop + sweep stopped — settle-safe), progress kept.
      await _pumpUntil(t, find.widgetWithText(FilledButton, 'Try again'));
      await t.pumpAndSettle();
      // Fail-closed chrome kept: error shown, retry offered, no advance.
      expect(find.textContaining('No face detected'), findsOneWidget);
      expect(find.text('Save enrollment'), findsNothing);
      // Notice rides as a toast overlay (zero layout — message length never
      // moves the feed); retry lives in the bottom bar.
      expect(
          find.ancestor(
              of: find.byType(EnrollNotice),
              matching: find.byType(Positioned)),
          findsOneWidget);
      // Same feed area (no resize on the error transition).
      expect(_previewStackFinder(), findsOneWidget);
      expect(t.getSize(_previewStackFinder()), capturingSize);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(find.text('open-capture'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('layering decision (overlay refinement, never inline)', () {
    testWidgets('overlay rides paint-only in the preview Stack; prompt in bar',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      // The two-oval overlay is the paint-only child; mid-flow carries no
      // Positioned chrome at all (the save-error toast is saveError-gated).
      // Touch-transparency comes from the overlay root itself.
      expect(find.byType(CaptureOverlay), findsOneWidget);
      expect(
          find.ancestor(
              of: find.byType(CaptureOverlay),
              matching: find.byType(Positioned)),
          findsNothing);
      final stack = t.element(_previewStackFinder()).widget as Stack;
      expect(stack.fit, StackFit.expand);
      expect(stack.children.whereType<Positioned>(), isEmpty);
      // Prompt is bottom-bar chrome, never preview chrome: no Stack between
      // the prompt text and the page Scaffold, and it sits in Padding(16).
      final promptEl = find.text(enrollCapturePrompt).evaluate().single;
      var stackBetween = false;
      promptEl.visitAncestorElements((a) {
        final w = a.widget;
        if (w is Scaffold) return false;
        if (w is Stack) stackBetween = true;
        return true;
      });
      expect(stackBetween, isFalse);
      expect(
          find.ancestor(
              of: find.text(enrollCapturePrompt),
              matching: find.byWidgetPredicate((w) =>
                  w is Padding && w.padding == const EdgeInsets.all(16))),
          findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('preview Stack carries no copy (overlay is paint-only)',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      expect(_previewStackFinder(), findsOneWidget);
      // Progress rides the large oval arc, the placeholder carries no copy,
      // and the overlay status line stays null mid-flow (rejects are silent)
      // — no readable text is laid out over the feed.
      for (final e in find
          .descendant(
              of: _previewStackFinder(), matching: find.byType(Text))
          .evaluate()) {
        final w = e.widget as Text;
        final s = w.data ?? w.textSpan?.toPlainText() ?? '';
        expect(s, isEmpty,
            reason: 'copy inside preview Stack (overlay must be paint-only)');
      }
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });
  });
}
