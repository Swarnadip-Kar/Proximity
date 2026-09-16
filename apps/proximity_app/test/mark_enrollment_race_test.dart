// Accounts-first shell race regressions.
//
// Contract: the shell mounts on Accounts (index 2). Mark/Courses stay
// locked (dimmed, taps/swipes park on Accounts) until the CURRENT
// account's enrollment resolves; the lock lifting on Accounts advances to
// Mark. Whenever a resolve concludes UNENROLLED the shell auto-pushes ONE
// SetupFlowScreen on the root navigator (single-flight +
// generation-guarded); locked taps/swipes re-trigger it via a re-resolve
// (no dead ends); enrolled never pushes (the original bug stays fixed).
//
// Root cause pinned here: enrollment used to be triggered from the Mark
// tab, which read `linkedIdentityProvider` synchronously while the new
// account's enrollment repopulates asynchronously (`relinkLinkedIdentity`
// reads the store after sign-in). Switching accounts then immediately
// opening Mark therefore restarted enrollment even though the stored
// enrollment already belonged to the new account.
//
// The shell now resolves the CURRENT account (live linked, else one
// stored read for this Gmail) before unlocking, with a generation guard
// for rapid switches. Join gates re-resolve after every async gap and
// never force-unwrap nullable session/identity state. Onstage assertions
// below use `.hitTestable()` (PageView keeps all three tab roots mounted;
// only the selected tab hit-tests; the auto-pushed flow covers all tabs
// while open).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/ble_radio.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/features/account/account_enrollment_page.dart';
import 'package:proximity_app/features/account/account_screen.dart';
import 'package:proximity_app/features/setup/setup_step_scope.dart';
import 'package:proximity_app/main.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/screens/setup_flow_screen.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_app/screens/student_home.dart';
import 'package:proximity_ble/ble.dart';

const _aEmail = 'a@example.com';
const _bEmail = 'b@example.com';
const _cEmail = 'c@example.com';

const _acctA = SignedAccount(
    email: _aEmail, displayName: 'User A', uid: 'uid-a', org: 'example.com');
const _acctB = SignedAccount(
    email: _bEmail, displayName: 'User B', uid: 'uid-b', org: 'example.com');
const _acctC = SignedAccount(
    email: _cEmail, displayName: 'User C', uid: 'uid-c', org: 'example.com');

const _linkedA = LinkedIdentity(
    name: 'User A', gmail: _aEmail, roll: 'R-A', org: 'example.com');
const _linkedB = LinkedIdentity(
    name: 'User B', gmail: _bEmail, roll: 'R-B', org: 'example.com');

/// Switchable auth: `accountProvider` (a StreamProvider) must actually emit
/// account switches mid-test. `FakeAuthService.watchAccount` returns a
/// single `Stream.value`, so it cannot model the switch ordering at all.
class _SwitchableAuth implements AuthService {
  SignedAccount? _current;
  final _ctrl = StreamController<SignedAccount?>.broadcast();
  _SwitchableAuth(this._current);

  void switchTo(SignedAccount? a) {
    _current = a;
    _ctrl.add(a);
  }

  @override
  Stream<SignedAccount?> watchAccount() async* {
    yield _current;
    yield* _ctrl.stream;
  }

  @override
  SignedAccount? get current => _current;

  @override
  Future<SignedAccount?> signInWithGoogle() async => _current;

  @override
  Future<String?> getIdToken() async =>
      _current == null ? null : 'fake-id-token';

  @override
  Future<void> signOut() async {
    _current = null;
    _ctrl.add(null);
  }
}

Future<InMemoryDeviceStore> _storeEnrolledAs(String email) async {
  final store = InMemoryDeviceStore();
  await store.writeInstallId('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  await store.writeEnrollment(StoredEnrollment(
    email: email,
    name: 'User ${email[0].toUpperCase()}',
    roll: 'R-${email[0].toUpperCase()}',
    pkHex: 'cd' * 32,
    faceId: 'face-$email',
    enrolledAt: DateTime.utc(2026, 9, 1),
    verifierVer: kFaceVerifierVer,
    org: 'example.com',
    pkDHex: 'ef' * 32,
    attestationLevel: 'NONE',
    attestedAt: DateTime.utc(2026, 9, 1),
    attestedUntil: DateTime.utc(2026, 11, 30),
  ));
  return store;
}

Widget _shellHarness({
  required _SwitchableAuth auth,
  required InMemoryDeviceStore store,
  LinkedIdentity? linked,
}) {
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(auth),
      cloudSyncProvider.overrideWithValue(FakeCloudSync()),
      deviceStoreProvider.overrideWithValue(store),
      faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
      deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
      poseGateProvider.overrideWithValue(FakePoseGate()),
      hostDriverProvider.overrideWithValue(FakeHostDriver()),
      studentDriverProvider
          .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
      bleEngineProvider.overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
      blePermissionProvider.overrideWithValue(() async => true),
      btPowerProvider.overrideWithValue(() async => BtState.on),
      if (linked != null)
        linkedIdentityProvider.overrideWith((ref) => linked),
      appModeProvider.overrideWith((ref) => AppMode.student),
      enrollmentControllerProvider.overrideWith(
        (ref) => EnrollmentController(
          auth: ref.watch(authServiceProvider),
          store: ref.watch(deviceStoreProvider),
          verifier: FakeFaceVerifier(),
          deviceKey: FakeDeviceKey(),
        ),
      ),
    ],
    child: MaterialApp(theme: proxLightTheme(), home: const StudentShell()),
  );
}

Future<void> _settle(WidgetTester t, [int steps = 10]) async {
  await t.pump();
  for (var i = 0; i < steps; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
}

/// Backs out of the auto-pushed flow (one system back per flow step, then
/// the first-step pop) until it is gone. Bounded by the step count + 1.
Future<void> _dismissFlow(WidgetTester t) async {
  for (var i = 0;
      i < SetupStep.count + 1 &&
          find.byType(SetupFlowScreen).evaluate().isNotEmpty;
      i++) {
    await t.binding.handlePopRoute();
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  Finder onstageOf(Type type) =>
      find.byType(type).hitTestable();

  group('accounts-first shell race', () {
    testWidgets(
        'relink gap: stored enrollment for current account lands on Mark, no flow',
        (t) async {
      // The exact race window: signed in as B, B enrolled on disk, but
      // linked not yet repopulated (null). The shell mounts on Accounts,
      // resolves, unlocks, and advances to Mark — no flow ever pushes
      // (enrolled → never: the reported original bug stays fixed).
      final auth = _SwitchableAuth(_acctB);
      final store = await _storeEnrolledAs(_bEmail);
      await t.pumpWidget(
          _shellHarness(auth: auth, store: store, linked: null));
      await _settle(t);

      expect(onstageOf(StudentHomeScreen), findsOneWidget);
      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('genuinely unenrolled auto-pushes one flow; back-out parks',
        (t) async {
      final auth = _SwitchableAuth(_acctC);
      final store = InMemoryDeviceStore();
      await t.pumpWidget(
          _shellHarness(auth: auth, store: store, linked: null));
      await _settle(t);

      // Returning-login unenrolled → flow immediately (exactly one);
      // Mark never shows bare underneath. (The covered shell is offstage,
      // so the locked tap below runs after the back-out, onstage.)
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      expect(onstageOf(StudentHomeScreen), findsNothing);
      // Back out: lands on locked Accounts (never bare Mark) with a live
      // way forward — the next locked tap re-pushes the flow.
      await _dismissFlow(t);
      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(onstageOf(StudentAccountScreen), findsOneWidget);
      expect(onstageOf(StudentHomeScreen), findsNothing);
      // Locked Mark tap re-triggers (single-flight: exactly one flow).
      await t.tap(find.descendant(
        of: find.byKey(const ValueKey('shell-bar')),
        matching: find.text('Mark'),
      ));
      await _settle(t);
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      expect(onstageOf(StudentHomeScreen), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('stale linked from previous account does not open Mark',
        (t) async {
      // Signed in as C (unenrolled, empty store) but linked still holds B.
      // The account-scoped resolve rejects the stale identity: locked
      // Accounts underneath plus the auto-pushed flow (C is genuinely
      // unenrolled) — never bare Mark, never B's identity.
      final auth = _SwitchableAuth(_acctC);
      final store = InMemoryDeviceStore();
      await t.pumpWidget(
          _shellHarness(auth: auth, store: store, linked: _linkedB));
      await _settle(t);

      expect(find.byType(SetupFlowScreen), findsOneWidget);
      expect(onstageOf(StudentHomeScreen), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets(
        'switch A(unenrolled) -> B(enrolled) advances to Mark, no flow',
        (t) async {
      final auth = _SwitchableAuth(_acctA);
      final store = await _storeEnrolledAs(_bEmail);
      final container = ProviderContainer(overrides: [
        authServiceProvider.overrideWithValue(auth),
        cloudSyncProvider.overrideWithValue(FakeCloudSync()),
        deviceStoreProvider.overrideWithValue(store),
        faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
        deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
        poseGateProvider.overrideWithValue(FakePoseGate()),
        hostDriverProvider.overrideWithValue(FakeHostDriver()),
        studentDriverProvider
            .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
        bleEngineProvider
            .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        btPowerProvider.overrideWithValue(() async => BtState.on),
        appModeProvider.overrideWith((ref) => AppMode.student),
        enrollmentControllerProvider.overrideWith(
          (ref) => EnrollmentController(
            auth: ref.watch(authServiceProvider),
            store: ref.watch(deviceStoreProvider),
            verifier: FakeFaceVerifier(),
            deviceKey: FakeDeviceKey(),
          ),
        ),
      ]);
      addTearDown(container.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentShell()),
      ));
      await _settle(t);
      // A unenrolled (stored holds B): auto-pushed flow over Accounts.
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      expect(onstageOf(StudentHomeScreen), findsNothing);

      // Account switch to enrolled B with linked still in the gap (null).
      auth.switchTo(_acctB);
      await _settle(t, 14);

      // Resolve unlocks and advances underneath with no second push
      // (single-flight across the switch storm): back out of the one flow
      // to reveal Mark browse for B.
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      await _dismissFlow(t);
      // Drain the freshly revealed Mark entrance timers before teardown.
      await _settle(t, 4);
      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(onstageOf(StudentHomeScreen), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('rapid switches + tab taps never crash', (t) async {
      final auth = _SwitchableAuth(_acctB);
      final store = await _storeEnrolledAs(_bEmail);
      final container = ProviderContainer(overrides: [
        authServiceProvider.overrideWithValue(auth),
        cloudSyncProvider.overrideWithValue(FakeCloudSync()),
        deviceStoreProvider.overrideWithValue(store),
        faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
        deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
        poseGateProvider.overrideWithValue(FakePoseGate()),
        hostDriverProvider.overrideWithValue(FakeHostDriver()),
        studentDriverProvider
            .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
        bleEngineProvider
            .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        btPowerProvider.overrideWithValue(() async => BtState.on),
        linkedIdentityProvider.overrideWith((ref) => _linkedB),
        appModeProvider.overrideWith((ref) => AppMode.student),
        enrollmentControllerProvider.overrideWith(
          (ref) => EnrollmentController(
            auth: ref.watch(authServiceProvider),
            store: ref.watch(deviceStoreProvider),
            verifier: FakeFaceVerifier(),
            deviceKey: FakeDeviceKey(),
          ),
        ),
      ]);
      addTearDown(container.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentShell()),
      ));
      await _settle(t);

    // Storm taps: the auto-pushed flow may cover (offstage) the bar
    // mid-storm, so search offstage too and never throw on a covered tap
    // (a real user tapping covered chrome just hits the flow — harmless).
    Future<void> tapTab(String label) async {
      final tab = find.descendant(
        of: find.byKey(const ValueKey('shell-bar'), skipOffstage: false),
        matching: find.text(label, skipOffstage: false),
        skipOffstage: false,
      );
      if (tab.evaluate().isNotEmpty) {
        await t.tap(tab, warnIfMissed: false);
      }
      await t.pump(const Duration(milliseconds: 100));
    }

      // Enrolled Mark baseline (shell mounts Accounts, advances to Mark).
      await _settle(t);
      expect(onstageOf(StudentHomeScreen), findsOneWidget);
      expect(find.byType(SetupFlowScreen), findsNothing);

      // Rapid: clear identity (sign-out gap) -> switch account -> flip tabs.
      // Unenrolled conclusions auto-push (single-flight: at most one flow
      // no matter the storm); locked taps re-trigger instead of hinting.
      container.read(linkedIdentityProvider.notifier).state = null;
      auth.switchTo(_acctC);
      await tapTab('Account');
      await tapTab('Mark');
      container.read(linkedIdentityProvider.notifier).state = _linkedA;
      auth.switchTo(_acctA);
      await tapTab('Courses');
      await tapTab('Mark');
      auth.switchTo(_acctB);
      container.read(linkedIdentityProvider.notifier).state = _linkedB;
      await tapTab('Account');
      await tapTab('Mark');
      await _settle(t);

      expect(t.takeException(), isNull);
      // At most one flow survived the storm; dismiss it to reveal the
      // final state — enrolled B on Mark.
      expect(find.byType(SetupFlowScreen).evaluate().length,
          lessThanOrEqualTo(1));
      await _dismissFlow(t);
      // Drain the freshly revealed Mark entrance timers before teardown.
      await _settle(t, 4);
      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(onstageOf(StudentHomeScreen), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('sign-out while on Mark parks on Accounts without crashing',
        (t) async {
      final auth = _SwitchableAuth(_acctB);
      final store = await _storeEnrolledAs(_bEmail);
      final container = ProviderContainer(overrides: [
        authServiceProvider.overrideWithValue(auth),
        cloudSyncProvider.overrideWithValue(FakeCloudSync()),
        deviceStoreProvider.overrideWithValue(store),
        faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
        deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
        poseGateProvider.overrideWithValue(FakePoseGate()),
        hostDriverProvider.overrideWithValue(FakeHostDriver()),
        studentDriverProvider
            .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
        bleEngineProvider
            .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        btPowerProvider.overrideWithValue(() async => BtState.on),
        linkedIdentityProvider.overrideWith((ref) => _linkedB),
        appModeProvider.overrideWith((ref) => AppMode.student),
        enrollmentControllerProvider.overrideWith(
          (ref) => EnrollmentController(
            auth: ref.watch(authServiceProvider),
            store: ref.watch(deviceStoreProvider),
            verifier: FakeFaceVerifier(),
            deviceKey: FakeDeviceKey(),
          ),
        ),
      ]);
      addTearDown(container.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentShell()),
      ));
      await _settle(t);
      expect(onstageOf(StudentHomeScreen), findsOneWidget);

      // Sign-out (linked cleared by entrySignOut ordering): the shell
      // parks on Accounts and auto-pushes one flow — no crash, never
      // bare Mark.
      container.read(linkedIdentityProvider.notifier).state = null;
      auth.switchTo(null);
      await _settle(t, 12);

      expect(find.byType(SetupFlowScreen), findsOneWidget);
      expect(onstageOf(StudentHomeScreen), findsNothing);
      await _dismissFlow(t);
      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(onstageOf(StudentAccountScreen), findsOneWidget);
      expect(onstageOf(StudentHomeScreen), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('account switch shell reset (stale-stack F06)', () {
    testWidgets(
        'switch drops pushed account screens via app-home keying, then locks',
        (t) async {
      // Full-app pump (ProximityApp home, not the bare shell): the home
      // keys each shell per Gmail, so an account switch remounts the shell
      // and drops every per-tab Navigator stack holding the previous
      // identity's pushed screens. The lock transition then parks on
      // Accounts with exactly one auto-pushed flow.
      final auth = _SwitchableAuth(_acctB);
      final store = await _storeEnrolledAs(_bEmail);
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(auth),
          cloudSyncProvider.overrideWithValue(FakeCloudSync()),
          deviceStoreProvider.overrideWithValue(store),
          faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
          deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
          poseGateProvider.overrideWithValue(FakePoseGate()),
          hostDriverProvider.overrideWithValue(FakeHostDriver()),
          studentDriverProvider
              .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
          bleEngineProvider
              .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
          blePermissionProvider.overrideWithValue(() async => true),
          btPowerProvider.overrideWithValue(() async => BtState.on),
          linkedIdentityProvider.overrideWith((ref) => _linkedB),
          appModeProvider.overrideWith((ref) => AppMode.student),
          enrollmentControllerProvider.overrideWith(
            (ref) => EnrollmentController(
              auth: ref.watch(authServiceProvider),
              store: ref.watch(deviceStoreProvider),
              verifier: FakeFaceVerifier(),
              deviceKey: FakeDeviceKey(),
            ),
          ),
        ],
        child: const ProximityApp(),
      ));
      await _settle(t);
      // Enrolled B lands on Mark.
      expect(onstageOf(StudentHomeScreen), findsOneWidget);

      // Open the Account tab and push B's enrollment sub-page.
      await t.tap(find.descendant(
        of: find.byKey(const ValueKey('shell-bar')),
        matching: find.text('Account'),
      ));
      await _settle(t);
      expect(onstageOf(StudentAccountScreen), findsOneWidget);
      await t.tap(find.byKey(const Key('account-row-enrollment')));
      await _settle(t);
      expect(find.byType(AccountEnrollmentPage), findsOneWidget);

      // Switch to unenrolled C: the pushed page for B must not survive.
      auth.switchTo(_acctC);
      await _settle(t, 14);

      expect(find.byType(AccountEnrollmentPage), findsNothing);
      // Lock transition: parked Accounts + exactly one auto-pushed flow.
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      expect(onstageOf(StudentHomeScreen), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('mark join gates resolve current account', () {
    testWidgets('join in relink gap uses stored enrollment, no crash',
        (t) async {
      // Account B enrolled on disk, linked null (race window). Join must
      // relink and enter waiting instead of refusing.
      final auth = FakeAuthService(_acctB);
      final store = await _storeEnrolledAs(_bEmail);
      final container = ProviderContainer(overrides: [
        authServiceProvider.overrideWithValue(auth),
        cloudSyncProvider.overrideWithValue(FakeCloudSync()),
        deviceStoreProvider.overrideWithValue(store),
        faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
        deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
        poseGateProvider.overrideWithValue(FakePoseGate()),
        hostDriverProvider.overrideWithValue(FakeHostDriver()),
        studentDriverProvider
            .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
        bleEngineProvider
            .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        btPowerProvider.overrideWithValue(() async => BtState.on),
        appModeProvider.overrideWith((ref) => AppMode.student),
        enrollmentControllerProvider.overrideWith(
          (ref) => EnrollmentController(
            auth: ref.watch(authServiceProvider),
            store: ref.watch(deviceStoreProvider),
            verifier: FakeFaceVerifier(),
            deviceKey: FakeDeviceKey(),
          ),
        ),
      ]);
      addTearDown(container.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentHomeScreen()),
      ));
      await _settle(t);
      // Typed-IP join affordance lives in the manual sheet.
      final fallback = find.text('Enter IP manually');
      expect(fallback, findsOneWidget);
      await t.tap(fallback);
      await _settle(t);
      await t.enterText(
          find.byKey(const ValueKey('ipfield')), '192.168.43.1');
      await t.pump();
      await t.tap(find.text('Join'));
      await t.pump();
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 300));
      }
      // Waiting room (not the enroll refusal), no crash on the relink gap.
      expect(
          find.text('Enroll this device first — identity is required.'),
          findsNothing);
      expect(find.textContaining('not yet started'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('stale linked identity cannot join as another account',
        (t) async {
      // Signed in as C, linked stale B: join must refuse, never prove as B.
      final auth = _SwitchableAuth(_acctC);
      final store = InMemoryDeviceStore();
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(auth),
          cloudSyncProvider.overrideWithValue(FakeCloudSync()),
          deviceStoreProvider.overrideWithValue(store),
          faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
          deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
          poseGateProvider.overrideWithValue(FakePoseGate()),
          hostDriverProvider.overrideWithValue(FakeHostDriver()),
          studentDriverProvider
              .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
          bleEngineProvider
              .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
          blePermissionProvider.overrideWithValue(() async => true),
          btPowerProvider.overrideWithValue(() async => BtState.on),
          linkedIdentityProvider.overrideWith((ref) => _linkedB),
          appModeProvider.overrideWith((ref) => AppMode.student),
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
            theme: proxLightTheme(), home: const StudentHomeScreen()),
      ));
      await _settle(t);
      await t.tap(find.text('Enter IP manually'));
      await _settle(t);
      await t.enterText(
          find.byKey(const ValueKey('ipfield')), '192.168.43.1');
      await t.pump();
      await t.tap(find.text('Join'));
      await _settle(t);
      expect(find.text('Enroll this device first — identity is required.'),
          findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
