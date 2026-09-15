// Setup pagination proofs (## Setup pagination + ## About-page removal):
// the flow is six one-purpose pages (device → account&key; the
// About-to-enroll explainer page is removed from the flow);
// welcome/capture/result stay one page each. Start-index semantics,
// listeners, lazy camera mount, back behavior, and scope branches are
// behavior-identical (capture/result are 4/5; progress counts 6 pages).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/security/integrity.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/features/setup/device_identity_screen.dart';
import 'package:proximity_app/features/setup/device_intro_step.dart';
import 'package:proximity_app/features/setup/device_sections.dart';
import 'package:proximity_app/features/setup/enroll_capture.dart';
import 'package:proximity_app/features/setup/enroll_result.dart';
import 'package:proximity_app/features/setup/intro_sections.dart';
import 'package:proximity_app/features/setup/result_sections.dart';
import 'package:proximity_app/features/setup/role_hub_screen.dart';
import 'package:proximity_app/features/setup/role_sections.dart';
import 'package:proximity_app/features/setup/setup_progress.dart';
import 'package:proximity_app/features/setup/setup_step_scope.dart';
import 'package:proximity_app/features/setup/welcome_screen.dart';
import 'package:proximity_app/features/setup/welcome_sections.dart';
import 'package:proximity_app/screens/setup_flow_screen.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';
import 'package:proximity_app/widgets/prox_buttons.dart';

const _acct = SignedAccount(
    email: 'student@example.com', displayName: 'Test User', uid: 'test-uid');
const _stills = ['c.jpg', 'l.jpg', 'r.jpg', 'u.jpg', 'd.jpg'];

Future<void> _settleStepped(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

Widget _app(Widget home, List<Override> overrides) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(theme: proxLightTheme(), home: home),
  );
}

List<Override> _base({SignedAccount? acct = _acct}) {
  return [
    authServiceProvider.overrideWithValue(FakeAuthService(acct)),
    cloudSyncProvider.overrideWithValue(FakeCloudSync()),
    deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
  ];
}

Map<String, String> _studentRole() => {
      'roles': 'student',
      'lastMode': 'student',
      'email': _acct.email.toLowerCase(),
      'uid': 'test-uid',
      'displayName': 'Test User',
      'org': 'example.com',
    };

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
  group('page map (7 → 6 after About-page removal)', () {
    test('order + count', () {
      expect(SetupStep.welcome, 0);
      expect(SetupStep.role, 1);
      expect(SetupStep.device, 2);
      expect(SetupStep.accountKey, 3);
      expect(SetupStep.capture, 4);
      expect(SetupStep.result, 5);
      expect(SetupStep.count, 6);
    });
  });

  group('setupStartIndex semantics (first incomplete page wins)', () {
    test('signed out → welcome', () {
      expect(
          setupStartIndex(
              signedIn: false,
              hasStudentRole: false,
              hasKey: false,
              phase: EnrollPhase.signedOut),
          SetupStep.welcome);
    });

    test('signed in without student role → role', () {
      expect(
          setupStartIndex(
              signedIn: true,
              hasStudentRole: false,
              hasKey: false,
              phase: EnrollPhase.signedIn),
          SetupStep.role);
    });

    test('student role without key → device (first of the split group)',
        () {
      expect(
          setupStartIndex(
              signedIn: true,
              hasStudentRole: true,
              hasKey: false,
              phase: EnrollPhase.signedIn),
          SetupStep.device);
    });

    test('key without face → capture (skips device/accountKey)', () {
      expect(
          setupStartIndex(
              signedIn: true,
              hasStudentRole: true,
              hasKey: true,
              phase: EnrollPhase.keyReady),
          SetupStep.capture);
    });

    test('validated face → result', () {
      expect(
          setupStartIndex(
              signedIn: true,
              hasStudentRole: true,
              hasKey: true,
              phase: EnrollPhase.faceDone),
          SetupStep.result);
    });

    test('uploaded claim → result', () {
      expect(
          setupStartIndex(
              signedIn: true,
              hasStudentRole: true,
              hasKey: true,
              phase: EnrollPhase.uploaded),
          SetupStep.result);
    });
  });

  group('each page renders its single purpose', () {
    testWidgets('device page: device facts + Continue, no intro inputs',
        (t) async {
      await t.pumpWidget(_app(const DeviceConfirmStep(), _base()));
      await _settleStepped(t);
      expect(find.byType(DeviceIdentityContent), findsOneWidget);
      expect(find.byType(DeviceAccountSection), findsOneWidget);
      expect(find.byType(DeviceKeySection), findsOneWidget);
      expect(find.byType(DeviceMoveSection), findsOneWidget);
      // UI overhaul: CTA is a gradient ProxPrimaryButton, not FilledButton.
      // Assert the user-visible label, not the button implementation.
      expect(find.widgetWithText(ProxPrimaryButton, 'Continue'), findsOneWidget);
      // Intro purposes live on later pages, never here.
      expect(find.byType(IntroAccountSection), findsNothing);
      expect(find.byType(IntroKeySection), findsNothing);
      expect(find.text('Continue to face scan'), findsNothing);
      await _settleStepped(t);
    });

    testWidgets('account&key page: inputs + gated Continue, no explainer',
        (t) async {
      final auth = FakeAuthService(_acct);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      final box = <EnrollmentController>[];
      await t.pumpWidget(_app(
        const AccountKeyStep(),
        [
          authServiceProvider.overrideWithValue(auth),
          cloudSyncProvider.overrideWithValue(cloud),
          deviceStoreProvider.overrideWithValue(store),
          enrollmentControllerProvider.overrideWith((ref) {
            final ctl = EnrollmentController(
                auth: auth,
                store: store,
                verifier: FakeFaceVerifier(),
                deviceKey: FakeDeviceKey(),
                cloud: cloud,
                // enrollFace measures liveness: scripted pass (liveness
                // itself is pinned in enroll_liveness_gate_test.dart).
                livenessGate: FakeLivenessGate());
            box.add(ctl);
            return ctl;
          }),
        ],
      ));
      final ctl = box.single;
      await ctl.signIn();
      await t.pumpAndSettle();
      expect(find.byType(IntroAccountSection), findsOneWidget);
      expect(find.byType(IntroKeySection), findsOneWidget);
      expect(find.text('Continue to face scan'), findsOneWidget);
      // Device purposes live on earlier pages, never here.
      expect(find.byType(DeviceIdentityContent), findsNothing);
    });

    testWidgets('welcome stays one page (hero + sign-in)', (t) async {
      await t.pumpWidget(_app(
        const WelcomeScreen(),
        [
          authServiceProvider.overrideWithValue(FakeAuthService()),
          cloudSyncProvider.overrideWithValue(FakeCloudSync()),
          deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
        ],
      ));
      await _settleStepped(t);
      expect(find.byType(WelcomeHeroSection), findsOneWidget);
      expect(find.byType(WelcomeSignInSection), findsOneWidget);
      expect(find.text('Sign in with Google'), findsOneWidget);
      await _settleStepped(t);
    });

    testWidgets('role stays one page (register + footer)', (t) async {
      await t.pumpWidget(_app(const RoleHubScreen(account: _acct), _base()));
      await t.pumpAndSettle();
      expect(find.byType(RoleRegisterSection), findsOneWidget);
      expect(find.byType(RoleFooterSection), findsOneWidget);
      expect(find.text('Register as Student'), findsOneWidget);
    });

    testWidgets('capture stays one page (overlay, no device/intro)', (t) async {
      final auth = FakeAuthService(_acct);
      final store = InMemoryDeviceStore();
      final ctl = EnrollmentController(
          auth: auth,
          store: store,
          verifier: FakeFaceVerifier(),
          deviceKey: FakeDeviceKey());
      await ctl.signIn();
      ctl.setRoll('R-123');
      await ctl.generateKey();
      // Pushed-route harness (production shape): Cancel pops + disposes
      // the session so no loop/sweep timer is pending at test end.
      await t.pumpWidget(ProviderScope(
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
      ));
      await t.tap(find.text('open-capture'));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(CaptureOverlay), findsOneWidget);
      expect(find.byType(DeviceIdentityContent), findsNothing);
      expect(find.byType(IntroAccountSection), findsNothing);
      // Drain: cancel the live loop (pops back to the launcher), then
      // let beats and sweep ticks fire post-dispose (same _drain pattern
      // as enroll_guided_test — stepped, never one big pump).
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      for (var i = 0; i < 15; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('open-capture'), findsOneWidget);
      expect(find.byType(EnrollCaptureScreen), findsNothing);
    });

    testWidgets('result stays one page (status, no device/intro)', (t) async {
      final auth = FakeAuthService(_acct);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      final box = <EnrollmentController>[];
      await t.pumpWidget(_app(
        const EnrollResultScreen(),
        [
          authServiceProvider.overrideWithValue(auth),
          cloudSyncProvider.overrideWithValue(cloud),
          deviceStoreProvider.overrideWithValue(store),
          enrollmentControllerProvider.overrideWith((ref) {
            final ctl = EnrollmentController(
                auth: auth,
                store: store,
                verifier: FakeFaceVerifier(),
                deviceKey: FakeDeviceKey(),
                cloud: cloud,
                // enrollFace measures liveness: scripted pass (liveness
                // itself is pinned in enroll_liveness_gate_test.dart).
                livenessGate: FakeLivenessGate());
            box.add(ctl);
            return ctl;
          }),
        ],
      ));
      final ctl = box.single;
      await ctl.signIn();
      ctl.setRoll('R1001');
      await ctl.generateKey();
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      await t.pumpAndSettle();
      expect(find.byType(ResultStatusSection), findsOneWidget);
      expect(find.byType(DeviceIdentityContent), findsNothing);
    });
  });

  group('flow navigation (one page at a time)', () {
    testWidgets('device Continue advances exactly one page to account&key',
        (t) async {
      final store = InMemoryDeviceStore();
      await store.writeRole(_studentRole());
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(FakeAuthService(_acct)),
          cloudSyncProvider.overrideWithValue(FakeCloudSync()),
          deviceStoreProvider.overrideWithValue(store),
          faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
          deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
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
      // Start lands on the first incomplete page (device).
      expect(find.text('Confirm device'), findsOneWidget);
      await t.tap(find.widgetWithText(ProxPrimaryButton, 'Continue'));
      await _settleStepped(t);
      // Exactly one page forward — account&key, not capture (the about
      // page is removed from the flow).
      expect(find.text('Account & key'), findsOneWidget);
      expect(find.text('About to enroll'), findsNothing);
      await _settleStepped(t);
    });

    testWidgets('system back moves exactly one page (account&key → device)',
        (t) async {
      final store = InMemoryDeviceStore();
      await store.writeRole(_studentRole());
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(FakeAuthService(_acct)),
          cloudSyncProvider.overrideWithValue(FakeCloudSync()),
          deviceStoreProvider.overrideWithValue(store),
          faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
          deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
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
      expect(find.text('Confirm device'), findsOneWidget);
      await t.tap(find.widgetWithText(ProxPrimaryButton, 'Continue'));
      await _settleStepped(t);
      expect(find.text('Account & key'), findsOneWidget);
      // System back: one page back to device (never welcome/role).
      await t.binding.handlePopRoute();
      await _settleStepped(t);
      expect(find.text('Confirm device'), findsOneWidget);
      expect(find.text('Account & key'), findsNothing);
      await _settleStepped(t);
    });

    testWidgets('double Continue advances exactly one page (single-flight)',
        (t) async {
      final store = InMemoryDeviceStore();
      await store.writeRole(_studentRole());
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(FakeAuthService(_acct)),
          cloudSyncProvider.overrideWithValue(FakeCloudSync()),
          deviceStoreProvider.overrideWithValue(store),
          faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
          deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
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
      expect(find.text('Confirm device'), findsOneWidget);
      // Double-tap without settling between taps: the second is dropped.
      await t.tap(find.widgetWithText(ProxPrimaryButton, 'Continue'));
      await t.tap(find.widgetWithText(ProxPrimaryButton, 'Continue'));
      await _settleStepped(t);
      expect(find.text('Account & key'), findsOneWidget);
      expect(find.text('Face capture'), findsNothing);
      await _settleStepped(t);
    });

    testWidgets('overlapping first-step backs fire onFirstBack once',
        (t) async {
      var firstBacks = 0;
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
            // Slow parent: holds the single-flight busy so the overlap is
            // deterministic (fake-clock time only advances on pump).
            onFirstBack: () async {
              firstBacks++;
              await Future.delayed(const Duration(milliseconds: 500));
            },
            onComplete: () async {},
          ),
        ),
      ));
      await _settleStepped(t);
      expect(find.text('Sign in with Google'), findsOneWidget);
      // Two system backs issued before either settles: one fires.
      final pop1 = t.binding.handlePopRoute();
      final pop2 = t.binding.handlePopRoute();
      await pop1;
      await pop2;
      await _settleStepped(t);
      expect(firstBacks, 1);
      await _settleStepped(t);
    });

    testWidgets(
        'back from role while signed in leaves via onFirstBack (never strands on welcome)',
        (t) async {
      // Field bug: system back from the role step landed signed-in users
      // on the welcome step, which has no forward path (re-sign-in is a
      // same-email no-op) — Continue/registration/professor all unreachable
      // behind. While signed in, role is the first step.
      var firstBacks = 0;
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(FakeAuthService(_acct)),
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
            onFirstBack: () async {
              firstBacks++;
            },
            onComplete: () async {},
          ),
        ),
      ));
      await _settleStepped(t);
      // Signed in, no roles yet: start lands on role.
      expect(find.text('Register as Student'), findsOneWidget);
      // System back: first-step back while signed in.
      await t.binding.handlePopRoute();
      await _settleStepped(t);
      expect(firstBacks, 1);
      // Still on the role actions — never stranded on welcome.
      expect(find.text('Register as Student'), findsOneWidget);
      expect(find.text('Sign in with Google'), findsNothing);
      await _settleStepped(t);
    });
  });

  group('progress reflects pages (same overlay, count 6)', () {
    testWidgets('signed out starts 1/6 on welcome', (t) async {
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
      expect(find.text('Sign in with Google'), findsOneWidget);
      final overlay =
          t.widget<SetupProgressOverlay>(find.byType(SetupProgressOverlay));
      expect(overlay.count, SetupStep.count);
      expect(overlay.index, SetupStep.welcome);
      final bar =
          t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(1 / SetupStep.count, 0.001));
      await _settleStepped(t);
    });

    testWidgets('student role without key starts 3/6 on device', (t) async {
      final store = InMemoryDeviceStore();
      await store.writeRole(_studentRole());
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(FakeAuthService(_acct)),
          cloudSyncProvider.overrideWithValue(FakeCloudSync()),
          deviceStoreProvider.overrideWithValue(store),
          faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
          deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
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
      expect(find.text('Confirm device'), findsOneWidget);
      final overlay =
          t.widget<SetupProgressOverlay>(find.byType(SetupProgressOverlay));
      expect(overlay.count, SetupStep.count);
      expect(overlay.index, SetupStep.device);
      final bar =
          t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(
          bar.value,
          closeTo(
              (SetupStep.device + 1) / SetupStep.count, 0.001));
      await _settleStepped(t);
    });
  });
}
