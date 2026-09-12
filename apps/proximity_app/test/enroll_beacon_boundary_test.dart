// Enrollment boundary + beacon + single-oval contracts (override
// 2026-09-10 — see INTEGRATION_LOG.md `## Overlay redesign`).
// (UI-boundary overflow fix, area stability, overlay layering verdict.)
//
// Squish fix is the bare surface (zero-treatment frame as a direct child
// of a loose, centered Stack — see `## Capture preview fidelity`), so
// these pin the device-boundary path: edge-to-edge Scaffold (body behind
// the transparent app bar — see `## Edge-to-edge capture`), no SafeArea
// double-apply, no wrapper of any kind, overlay + toast layering, and the
// researched layering decision (chrome stays overlay — the single-oval
// overlay paints inside the preview Stack, the prompt rides the overlay
// below the oval, buttons sit in the bottom bar, never inline above the
// feed, never extra copy inside the Stack). Single-oval tests pin the
// guide rect + comet geometry and the reduce-motion minimal tail.
// Clock: the beacon timer is periodic — drive live sessions with bounded
// pumps, never pumpAndSettle with the session mounted (settle only once
// the loop and sweep are stopped: result screen, validated-after-back,
// save-error).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/setup/enroll_capture.dart';
import 'package:proximity_app/features/setup/enroll_flow.dart';
import 'package:proximity_app/features/setup/enroll_widgets.dart';
import 'package:proximity_app/routes.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/screens/face_capture.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';
import 'package:proximity_app/widgets/prox_buttons.dart';

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
    // enrollFace measures liveness: scripted pass (liveness itself is
    // pinned in enroll_liveness_gate_test.dart).
    livenessGate: FakeLivenessGate(),
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
        // Named-route table: EnrollFlow.openResult goes via
        // ProxNav.pushNamed, so the harness must resolve enroll/* names.
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

/// The preview Stack: the only loose, centered Stack carrying the
/// single-oval overlay (Navigator/Overlay internals use different fits, so
/// this is unique). Loose + centered is the bare-surface contract: the
/// frame self-sizes to its native aspect and is never force-filled.
Finder _previewStackFinder() => find.byWidgetPredicate((w) =>
    w is Stack &&
    w.fit == StackFit.loose &&
    w.alignment == Alignment.center &&
    w.children.whereType<CaptureOverlay>().isNotEmpty);

void main() {
  // EnrollFlow single-flight flags are static: reset between tests.
  setUp(EnrollFlow.debugReset);
  tearDown(EnrollFlow.debugReset);
  group('device-boundary parity (elongation fix)', () {
    testWidgets('Scaffold defaults match original (no overflow flags)',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      final scaffold =
          t.element(find.byType(Scaffold).last).widget as Scaffold;
      // Edge-to-edge (2026-09-10 `## Edge-to-edge capture`, supersedes the
      // old body-below-AppBar pin): keyboard-aware, body fullscreen behind
      // the status bar + transparent overlay app bar; chrome avoids the
      // notch via SafeArea overlays while the video paints under it.
      expect(scaffold.resizeToAvoidBottomInset ?? true, isTrue);
      expect(scaffold.extendBody, isTrue);
      expect(scaffold.extendBodyBehindAppBar, isTrue);
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

    testWidgets('mid-flow keeps single prompt + overlay, no reservation',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      // Single static prompt (overlay-owned) + the single-oval overlay
      // exactly (no dots, no per-angle labels — override 2026-09-10).
      expect(find.text(enrollCapturePrompt), findsOneWidget);
      expect(find.byType(CaptureOverlay), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // Cover-fit removed the parity reservation: no hidden placeholder
      // and no button (visible or hidden) mid-flow.
      expect(
          find.byWidgetPredicate(
              (w) => w is Visibility && !w.visible && w.maintainSize),
          findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });
  });

  group('marking still-capture oval (beacon branches removed)', () {
    testWidgets('marking states render (progress arc only, no beacon)',
        (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: FaceCaptureOvalOverlay(progress: 0.4)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: FaceCaptureOvalOverlay(progress: 1.0)),
      ));
      await t.pump();
      expect(find.byType(FaceCaptureOvalOverlay), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('preview chrome across lifecycle variants', () {
    testWidgets('forward then back: overlay survives, Continue appears',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      expect(_previewStackFinder(), findsOneWidget);
      // All 5 buckets validate → auto-advance to the result step.
      await _pumpUntil(t, find.text('Save enrollment'));
      // Result screen is static: settle its entrance before going back.
      await t.pumpAndSettle();
      // System back pops only the result: capture returns validated
      // (loop stopped, sweep stopped — settle-safe) with Continue chrome.
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.byType(EnrollCaptureScreen), findsOneWidget);
      expect(find.widgetWithText(ProxPrimaryButton, 'Continue'), findsOneWidget);
      // Overlay-owned prompt persists in the terminal state (the overlay
      // is always mounted over the preview); the bare frame self-sizes
      // through the bottom-bar change, so no size pin here.
      expect(find.text(enrollCapturePrompt), findsOneWidget);
      expect(_previewStackFinder(), findsOneWidget);
      expect(t.takeException(), isNull);
      // Drain via cancel (disposes the session camera).
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(find.text('open-capture'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('save-error keeps overlay + toast, retry offered',
        (t) async {
      final ctl = await _keyReady(verifier: _EnrollBoom());
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      expect(_previewStackFinder(), findsOneWidget);
      // All 5 stills accepted, gallery write throws → fail-closed error bar
      // (loop + sweep stopped — settle-safe), progress kept.
      await _pumpUntil(t, find.widgetWithText(ProxPrimaryButton, 'Try again'));
      await t.pumpAndSettle();
      // Fail-closed chrome kept: error shown, retry offered, no advance.
      expect(find.textContaining('No face detected'), findsOneWidget);
      expect(find.text('Save enrollment'), findsNothing);
      // Notice rides as a toast overlay (zero layout — message length never
      // moves the feed); retry lives in the bottom bar; the overlay-owned
      // prompt stays mounted underneath.
      expect(
          find.ancestor(
              of: find.byType(EnrollNotice),
              matching: find.byType(Positioned)),
          findsOneWidget);
      expect(_previewStackFinder(), findsOneWidget);
      expect(find.text(enrollCapturePrompt), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(find.text('open-capture'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('layering decision (overlay refinement, never inline)', () {
    testWidgets('overlay rides in the preview Stack; prompt overlay-owned',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      // The single-oval overlay is a direct (non-Positioned) Stack child;
      // the bare frame is the other direct child — NOTHING is Positioned
      // mid-flow (the save-error toast is saveError-gated).
      // Touch-transparency comes from the overlay root itself.
      expect(find.byType(CaptureOverlay), findsOneWidget);
      expect(
          find.ancestor(
              of: find.byType(CaptureOverlay),
              matching: find.byType(Positioned)),
          findsNothing);
      final stack = t.element(_previewStackFinder()).widget as Stack;
      expect(stack.fit, StackFit.loose);
      expect(stack.alignment, Alignment.center);
      expect(stack.children.whereType<Positioned>(), isEmpty);
      // Prompt is overlay chrome, never bottom-bar chrome mid-flow: a
      // Stack sits between the prompt text and the page Scaffold, and no
      // prompt copy lives in the Padding(16) bottom bar.
      final promptEl = find.text(enrollCapturePrompt).evaluate().single;
      var stackBetween = false;
      promptEl.visitAncestorElements((a) {
        final w = a.widget;
        if (w is Scaffold) return false;
        if (w is Stack) stackBetween = true;
        return true;
      });
      expect(stackBetween, isTrue);
      expect(
          find.descendant(
              of: find.byWidgetPredicate((w) =>
                  w is Padding && w.padding == const EdgeInsets.all(16)),
              matching: find.text(enrollCapturePrompt)),
          findsNothing);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('preview Stack carries exactly the one prompt line',
        (t) async {
      final ctl = await _keyReady();
      await t.pumpWidget(_captureHarness(ctl: ctl));
      await _openSession(t);
      expect(_previewStackFinder(), findsOneWidget);
      // Progress rides the slim top bar; the placeholder carries no copy;
      // the overlay contributes exactly ONE line (the prompt — rejects stay
      // silent in-UI, BleLog only).
      final texts = <String>[];
      for (final e in find
          .descendant(
              of: _previewStackFinder(), matching: find.byType(Text))
          .evaluate()) {
        final w = e.widget as Text;
        texts.add(w.data ?? w.textSpan?.toPlainText() ?? '');
      }
      expect(texts, [enrollCapturePrompt]);
      expect(t.takeException(), isNull);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });
  });
}
