// Setup-bundle rebuild proofs (items 2–4): progress placement, step
// modularity, and trimmed-copy contracts. Item-1 (claim-denial
// verdict-by-evidence) lives in setup_claim_denial_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/setup/device_identity_screen.dart';
import 'package:proximity_app/features/setup/device_sections.dart';
import 'package:proximity_app/features/setup/enroll_intro.dart';
import 'package:proximity_app/features/setup/enroll_result.dart';
import 'package:proximity_app/features/setup/intro_sections.dart';
import 'package:proximity_app/features/setup/result_sections.dart';
import 'package:proximity_app/features/setup/role_hub_screen.dart';
import 'package:proximity_app/features/setup/role_sections.dart';
import 'package:proximity_app/features/setup/setup_progress.dart';
import 'package:proximity_app/features/setup/welcome_screen.dart';
import 'package:proximity_app/features/setup/welcome_sections.dart';
import 'package:proximity_app/widgets/details_expander.dart';
import 'package:proximity_app/screens/setup_flow_screen.dart';

const _b = SignedAccount(email: 'b@univ.edu', displayName: 'B', uid: 'ub');
const _stills = ['c.jpg', 'l.jpg', 'r.jpg', 'u.jpg', 'd.jpg'];

Future<void> _settleStepped(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

List<Override> _baseOverrides(
    FakeAuthService auth, InMemoryDeviceStore store, FakeCloudSync cloud) {
  return [
    authServiceProvider.overrideWithValue(auth),
    cloudSyncProvider.overrideWithValue(cloud),
    deviceStoreProvider.overrideWithValue(store),
  ];
}

Widget _app(Widget home, List<Override> overrides) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(theme: proxLightTheme(), home: home),
  );
}

/// Enrollment-scoped overrides: creates the controller inside the
/// provider (the repo's working override pattern) and hands it out via
/// [onCtl] for pre-pump driving.
List<Override> _enrollOverrides({
  required FakeAuthService auth,
  required InMemoryDeviceStore store,
  required FakeCloudSync cloud,
  required void Function(EnrollmentController) onCtl,
}) {
  return [
    ..._baseOverrides(auth, store, cloud),
    enrollmentControllerProvider.overrideWith((ref) {
      final ctl = EnrollmentController(
          auth: auth,
          store: store,
          verifier: FakeFaceVerifier(),
          deviceKey: FakeDeviceKey(),
          cloud: cloud);
      onCtl(ctl);
      return ctl;
    }),
  ];
}

void main() {
  group('progress placement (below the app bar, in the safe area)', () {
    testWidgets('one persistent line on the app-bar/body seam', (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(FakeAuthService()),
          cloudSyncProvider.overrideWithValue(FakeCloudSync()),
          deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
          enrollmentControllerProvider.overrideWith(
            (ref) => EnrollmentController(
              auth: ref.watch(authServiceProvider),
              store: ref.watch(deviceStoreProvider),
              verifier: FakeFaceVerifier(),
              deviceKey: FakeDeviceKey(),
            ),
          ),
        ],
        child: MaterialApp(
          theme: proxLightTheme(),
          home: SetupFlowScreen(
            onFirstBack: () async {},
            onComplete: () async {},
          ),
        ),
      ));
      await _settleStepped(t);

      // Sign-in step content still renders under the stepper chrome.
      expect(find.text('Sign in with Google'), findsOneWidget);
      // Exactly one line in the whole tree (the old per-page Column built
      // one per page — five total, four offstage).
      expect(find.byType(SetupProgressLine, skipOffstage: false),
          findsOneWidget);
      expect(find.byType(SetupProgressOverlay, skipOffstage: false),
          findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // The line sits on the app-bar/body seam — at or below the AppBar
      // bottom (3px occupies the bar's own bottom edge), never above the
      // top bar, and inside the top safe area.
      final barBottom = t.getBottomRight(find.byType(AppBar)).dy;
      final progTop =
          t.getTopLeft(find.byType(LinearProgressIndicator)).dy;
      expect(progTop, greaterThanOrEqualTo(barBottom - 3.5));
      expect(progTop, greaterThanOrEqualTo(0.0));
      await _settleStepped(t);
    });
  });

  group('step modularity (thin composers over sections)', () {
    testWidgets('intro renders its five sections', (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      final box = <EnrollmentController>[];
      await t.pumpWidget(_app(
        Scaffold(
          body: SingleChildScrollView(child: EnrollIntroContent()),
        ),
        _enrollOverrides(auth: auth, store: store, cloud: cloud, onCtl: box.add),
      ));
      final ctl = box.single;
      await ctl.signIn();
      ctl.setRoll('B-ROLL');
      await ctl.generateKey();
      await t.pumpAndSettle();
      expect(find.byType(IntroOverviewSection), findsOneWidget);
      expect(find.byType(IntroOnlineSection), findsOneWidget);
      expect(find.byType(IntroOneDeviceSection), findsOneWidget);
      expect(find.byType(IntroAccountSection), findsOneWidget);
      expect(find.byType(IntroKeySection), findsOneWidget);
      // Test-relevant actions stay visible at the composition level.
      expect(find.text('Continue to face scan'), findsOneWidget);
      expect(find.textContaining('Key: '), findsOneWidget);
      expect(find.textContaining('Signed in as B'), findsOneWidget);
    });

    testWidgets('result renders status section when face-done', (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      final box = <EnrollmentController>[];
      await t.pumpWidget(_app(
        const EnrollResultScreen(),
        _enrollOverrides(auth: auth, store: store, cloud: cloud, onCtl: box.add),
      ));
      final ctl = box.single;
      await ctl.signIn();
      ctl.setRoll('B-ROLL');
      await ctl.generateKey();
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      await t.pumpAndSettle();
      expect(find.byType(ResultStatusSection), findsOneWidget);
      expect(find.byType(ResultRefusalSection), findsNothing);
      expect(find.text('Save enrollment'), findsWidgets);
    });

    testWidgets('result renders refusal section on roll-empty error',
        (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      final box = <EnrollmentController>[];
      await t.pumpWidget(_app(
        const EnrollResultScreen(),
        _enrollOverrides(auth: auth, store: store, cloud: cloud, onCtl: box.add),
      ));
      final ctl = box.single;
      await ctl.signIn();
      await ctl.generateKey();
      await ctl.enrollFace(_stills);
      await ctl.upload();
      expect(ctl.state.phase, EnrollPhase.error);
      await t.pumpAndSettle();
      expect(find.byType(ResultStatusSection), findsOneWidget);
      expect(find.byType(ResultRefusalSection), findsOneWidget);
      // Refusal copy is visible with no expansion step.
      expect(find.textContaining('ID number'), findsWidgets);
    });

    testWidgets('device identity renders its three sections', (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      await t.pumpWidget(_app(
        const Scaffold(body: DeviceIdentityContent()),
        _baseOverrides(auth, store, cloud),
      ));
      await t.pumpAndSettle();
      expect(find.byType(DeviceAccountSection), findsOneWidget);
      expect(find.byType(DeviceKeySection), findsOneWidget);
      expect(find.byType(DeviceMoveSection), findsOneWidget);
      expect(find.textContaining('Signed in as B'), findsOneWidget);
    });

    testWidgets('role hub renders register + footer sections', (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      await t.pumpWidget(_app(
        const RoleHubScreen(account: _b),
        _baseOverrides(auth, store, cloud),
      ));
      await t.pumpAndSettle();
      expect(find.byType(RoleRegisterSection), findsOneWidget);
      expect(find.byType(RoleFooterSection), findsOneWidget);
      expect(find.text('Register as Student'), findsOneWidget);
    });

    testWidgets('welcome renders hero + sign-in sections', (t) async {
      final auth = FakeAuthService();
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      await t.pumpWidget(_app(
        const WelcomeScreen(),
        _baseOverrides(auth, store, cloud),
      ));
      await _settleStepped(t);
      expect(find.byType(WelcomeHeroSection), findsOneWidget);
      expect(find.byType(WelcomeSignInSection), findsOneWidget);
      // Hero headline uses a display line-break ("Be there.\nBe marked.")
      // — same words, premium two-line typography.
      expect(find.textContaining('Be there.'), findsOneWidget);
      expect(find.textContaining('Be marked.'), findsOneWidget);
      expect(find.text('Sign in with Google'), findsOneWidget);
    });
  });

  group('trimmed copy (essentials visible, secondary collapsed)', () {
    /// Collapsed-by-default proof: AnimatedCrossFade keeps both children
    /// in the tree, so collapsed text is findable but parked in
    /// showFirst. Assert the state (not findability) before the tap.
    void expectCollapsed(WidgetTester t, String title) {
      final expander = find.ancestor(
          of: find.text(title), matching: find.byType(DetailsExpander));
      expect(expander, findsOneWidget);
      final fade = find.descendant(
          of: expander, matching: find.byType(AnimatedCrossFade));
      expect(t.widget<AnimatedCrossFade>(fade).crossFadeState,
          CrossFadeState.showFirst);
    }

    void expectExpanded(WidgetTester t, String title) {
      final expander = find.ancestor(
          of: find.text(title), matching: find.byType(DetailsExpander));
      final fade = find.descendant(
          of: expander, matching: find.byType(AnimatedCrossFade));
      expect(t.widget<AnimatedCrossFade>(fade).crossFadeState,
          CrossFadeState.showSecond);
    }

    testWidgets('welcome professor prose collapses', (t) async {
      final auth = FakeAuthService();
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      await t.pumpWidget(_app(
        const WelcomeScreen(),
        _baseOverrides(auth, store, cloud),
      ));
      await _settleStepped(t);
      expect(find.textContaining('Be there.'), findsOneWidget);
      expect(find.textContaining('Be marked.'), findsOneWidget);
      expect(find.text('Sign in with Google'), findsOneWidget);
      expectCollapsed(t, 'For professors');
      // Taller radar hero may push the expander below the fold —
      // scroll into view before tapping (screen is scrollable by design).
      await t.scrollUntilVisible(find.text('For professors'), 200);
      await t.tap(find.text('For professors'));
      await _settleStepped(t);
      expectExpanded(t, 'For professors');
      expect(find.textContaining('Professors may skip'), findsOneWidget);
    });

    testWidgets('role-hub prose collapses per section', (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      await t.pumpWidget(_app(
        const RoleHubScreen(account: _b),
        _baseOverrides(auth, store, cloud),
      ));
      await t.pumpAndSettle();
      expect(find.text('Register as Student'), findsOneWidget);
      expectCollapsed(t, 'About holding both roles');
      await t.tap(find.text('About holding both roles'));
      await t.pumpAndSettle();
      expectExpanded(t, 'About holding both roles');
      expect(find.textContaining('Same Gmail can hold both roles'),
          findsOneWidget);
    });

    testWidgets('intro angle + wifi detail collapse', (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      final box = <EnrollmentController>[];
      await t.pumpWidget(_app(
        Scaffold(
          body: SingleChildScrollView(child: EnrollIntroContent()),
        ),
        _enrollOverrides(auth: auth, store: store, cloud: cloud, onCtl: box.add),
      ));
      final ctl = box.single;
      await ctl.signIn();
      ctl.setRoll('B-ROLL');
      await ctl.generateKey();
      await t.pumpAndSettle();
      // Essentials visible…
      expect(find.text('Enroll this device'), findsWidgets);
      expect(find.textContaining('Later attendance works fully offline'),
          findsOneWidget);
      expect(find.textContaining('One Gmail lives on one enrolled device'),
          findsOneWidget);
      // …secondary prose collapsed.
      expectCollapsed(t, 'What the five angles involve');
      expectCollapsed(t, 'What goes over WiFi');
      await t.tap(find.text('What the five angles involve'));
      await t.pumpAndSettle();
      expectExpanded(t, 'What the five angles involve');
      expect(find.textContaining('each angle really angle-checked'),
          findsOneWidget);
      await t.tap(find.text('What goes over WiFi'));
      await t.pumpAndSettle();
      expectExpanded(t, 'What goes over WiFi');
      expect(find.textContaining('numbers only, no photo'), findsOneWidget);
    });

    testWidgets('device offline note collapses', (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      await t.pumpWidget(_app(
        const Scaffold(body: DeviceIdentityContent()),
        _baseOverrides(auth, store, cloud),
      ));
      await t.pumpAndSettle();
      expect(find.text('Which account, which device.'), findsOneWidget);
      expectCollapsed(t, 'Offline professors');
      await t.tap(find.text('Offline professors'));
      await t.pumpAndSettle();
      expectExpanded(t, 'Offline professors');
      expect(
          find.textContaining('Offline professors keep'), findsOneWidget);
    });
  });
}
