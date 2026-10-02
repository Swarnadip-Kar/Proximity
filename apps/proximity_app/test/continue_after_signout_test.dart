// Continue-after-sign-out regression: the hub's Continue as
// Student/Professor must navigate on EVERY cycle, not just the first.
//
// Covers the reported stuck hub ("signed in as …" with both Continues
// dead after re-sign-in) at two levels:
// - widget: landing hub student-Continue across sign-out → sign-in →
//   Continue (offline cloud; hub wiring + mode flip, incl. no lingering
//   busy narration);
// - direct: online student-Continue after a role-cache wipe (same-device
//   binding) and professor-Continue across a sign-out, with stubs for the
//   platform-bound seams the widget harness cannot answer (version
//   lookup, integrity probe, hardware id).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/app_config/force_update.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/ble_radio.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/security/user_presence.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/core/sync/device_hardware_id.dart';
import 'package:proximity_app/core/security/integrity.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/entry/entry_flow.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/screens/landing.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_ble/ble.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _email = 'student@example.com';
const _installId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _pkHex =
    'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';
const _acct = SignedAccount(
    email: _email, displayName: 'Test User', uid: 'test-uid', org: 'example.com');

class _SwitchAuth implements AuthService {
  SignedAccount? _current;
  final _ctrl = StreamController<SignedAccount?>.broadcast();
  _SwitchAuth(this._current);
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
  Future<String?> getIdToken() async => _current == null ? null : 'tok';
  @override
  Future<void> signOut() async {
    _current = null;
    _ctrl.add(null);
  }
}

Future<InMemoryDeviceStore> _enrolledStore() async {
  final store = InMemoryDeviceStore();
  await store.writeInstallId(_installId);
  await store.writeEnrollment(StoredEnrollment(
    email: _email,
    name: 'Test User',
    roll: 'R1001',
    pkHex: _pkHex,
    faceId: 'face-test-id',
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

FakeCloudSync _cloudBothRoles() {
  final cloud = FakeCloudSync(available: false, online: false);
  cloud.roles['test-uid'] = RoleDoc(
    uid: 'test-uid',
    email: _email,
    name: 'Test User',
    roles: const ['prof', 'student'],
    displayName: 'Test User',
    lastMode: 'student',
    org: 'example.com',
    updatedAtMillis: DateTime.now().toUtc().millisecondsSinceEpoch,
  );
  return cloud;
}

Map<String, String> _bothRolesLocal() => {
      'roles': 'prof,student',
      'lastMode': 'student',
      'email': _email,
      'uid': 'test-uid',
      'displayName': 'Test User',
      'org': 'example.com',
    };

Future<void> _drain(WidgetTester t, [int steps = 8]) async {
  await t.pump();
  for (var i = 0; i < steps; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

class _CleanProbe implements IntegrityProbe {
  const _CleanProbe();
  @override
  Future<IntegritySignals> check() async => const IntegritySignals();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HardwareDeviceIds.source = () async => '';
    IntegrityGate.probe = const _CleanProbe();
  });
  tearDown(() {
    HardwareDeviceIds.source = getStableHardwareDeviceId;
  });

  testWidgets('sign-out/in cycle: both Continues navigate both times',
      (t) async {
    final auth = _SwitchAuth(_acct);
    final store = await _enrolledStore();
    // Local role cache present (as after a cloud seed): with an offline
    // cloud the hub renders Continue from cache — this exercises the hub
    // wiring across sign-out/in cycles. The online gate path is covered by
    // the direct entry test below.
    await store.writeRole(_bothRolesLocal());
    final cloud = _cloudBothRoles();
    final container = ProviderContainer(overrides: [
      authServiceProvider.overrideWithValue(auth),
      cloudSyncProvider.overrideWithValue(cloud),
      deviceStoreProvider.overrideWithValue(store),
      faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
      deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
      enrollmentControllerProvider.overrideWith(
        (ref) => EnrollmentController(
          auth: ref.watch(authServiceProvider),
          store: ref.watch(deviceStoreProvider),
          verifier: FakeFaceVerifier(),
          deviceKey: FakeDeviceKey(),
          presenceGate: FakePresenceGate(),
        ),
      ),
    ]);
    addTearDown(container.dispose);
    late WidgetRef ref;
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: proxLightTheme(),
          home: Consumer(builder: (context, r, _) {
            ref = r;
            return const LandingScreen();
          })),
    ));
    await _drain(t);

    // Cycle 1: hub offers both Continues; student lands.
    expect(find.text('Continue as Student'), findsOneWidget);
    expect(find.text('Continue as Professor'), findsOneWidget);
    await t.tap(find.text('Continue as Student'));
    await _drain(t);
    expect(container.read(appModeProvider), AppMode.student,
        reason: 'cycle 1 student Continue must land');

    // Real sign-out path (clears role cache + linked + draft, unsets mode).
    await entrySignOut(ref, () => true);
    auth.switchTo(null);
    await _drain(t);
    expect(find.text('Sign in with Google'), findsOneWidget);

    // Cycle 2 (the reported stuck step): sign back in, Continue again.
    // Re-seed the local role cache the way the post-sign-in cloud seed
    // would (offline cloud cannot seed in-harness).
    await store.writeRole(_bothRolesLocal());
    auth.switchTo(_acct);
    await _drain(t);
    expect(find.text('Continue as Student'), findsOneWidget);
    await t.tap(find.text('Continue as Student'));
    await _drain(t);
    expect(container.read(appModeProvider), AppMode.student,
        reason: 'cycle 2 student Continue must land (reported stuck)');
    expect(find.text('Contacting server…'), findsNothing);
  });

  testWidgets('professor Continue works after sign-out/in (direct path)',
      (t) async {
    // The hub cannot inject the version-floor stub, and the live lookup
    // hangs on unmocked widget-harness channels — so the professor path
    // (which always consults the floor, unlike the offline-skipped
    // student path) is proven here directly, twice across a sign-out.
    Future<ForceUpdateResult> freshFloor() async => const ForceUpdateResult(
          checked: true,
          updateRequired: false,
          currentVersion: '9.9.9',
          config: ForceUpdateConfig(minVersion: '0.0.1', force: true),
        );
    final store = await _enrolledStore();
    await store.clearRole();
    final cloud = FakeCloudSync(available: true, online: true);
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    cloud.roles['test-uid'] = RoleDoc(
      uid: 'test-uid',
      email: _email,
      name: 'Test User',
      roles: const ['prof', 'student'],
      displayName: 'Test User',
      lastMode: 'prof',
      org: 'example.com',
      updatedAtMillis: now,
    );
    final container = ProviderContainer(overrides: [
      authServiceProvider.overrideWithValue(FakeAuthService(_acct)),
      cloudSyncProvider.overrideWithValue(cloud),
      deviceStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);
    late WidgetRef ref;
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: Consumer(builder: (context, r, _) {
        ref = r;
        return const SizedBox();
      }),
    ));
    await t.pump();

    final role = await entryRoleFor(ref, _acct);
    expect(roleSet(role ?? {}), containsAll(['prof', 'student']));
    await entryContinueWithRole(ref, () => true, _acct, role!, 'prof',
        checkNow: freshFloor);
    expect(container.read(appModeProvider), AppMode.prof);

    await entrySignOut(ref, () => true);
    expect(container.read(appModeProvider), AppMode.unset);
    final role2 = await entryRoleFor(ref, _acct);
    expect(roleSet(role2 ?? {}), containsAll(['prof', 'student']));
    await entryContinueWithRole(ref, () => true, _acct, role2!, 'prof',
        checkNow: freshFloor);
    expect(container.read(appModeProvider), AppMode.prof,
        reason: 'second professor Continue must land');
  });

  testWidgets('online student continue works after role-cache wipe',
      (t) async {
    // Direct entry-path check with stubs for the platform-bound seams the
    // widget harness cannot answer (version lookup + hardware id).
    final store = await _enrolledStore();
    await store.clearRole(); // post-sign-out state: cloud still holds roles
    final cloud = FakeCloudSync(available: true, online: true);
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    cloud.roles['test-uid'] = RoleDoc(
      uid: 'test-uid',
      email: _email,
      name: 'Test User',
      roles: const ['prof', 'student'],
      displayName: 'Test User',
      lastMode: 'student',
      org: 'example.com',
      updatedAtMillis: now,
    );
    cloud.devices[_email] = StudentDeviceDoc(
      email: _email,
      uid: 'test-uid',
      pkHex: _pkHex,
      name: 'Test User',
      roll: 'R1001',
      modelVer: kFaceVerifierVer,
      installId: _installId,
      platform: 'android',
      org: 'example.com',
      createdAtMillis: now,
      lastMoveAtMillis: 0,
      lastSeenAtMillis: now,
      updatedAtMillis: now,
      pkDHex: 'ef' * 32,
      attestationLevel: 'NONE',
    );
    cloud.installs[_installId] = _email;
    final container = ProviderContainer(overrides: [
      authServiceProvider.overrideWithValue(FakeAuthService(_acct)),
      cloudSyncProvider.overrideWithValue(cloud),
      deviceStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);
    late WidgetRef ref;
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: Consumer(builder: (context, r, _) {
        ref = r;
        return const SizedBox();
      }),
    ));
    await t.pump();

    // Role re-seeds from cloud despite the wiped cache (hub shows Continue).
    final role = await entryRoleFor(ref, _acct);
    expect(roleSet(role ?? {}), containsAll(['prof', 'student']));

    Future<ForceUpdateResult> freshFloor() async => const ForceUpdateResult(
          checked: true,
          updateRequired: false,
          currentVersion: '9.9.9',
          config: ForceUpdateConfig(minVersion: '0.0.1', force: true),
        );
    await entryContinueWithRole(ref, () => true, _acct, role!, 'student',
        checkNow: freshFloor);
    expect(container.read(appModeProvider), AppMode.student);
    await entrySignOut(ref, () => true);
    expect(container.read(appModeProvider), AppMode.unset);

    // Second cycle after sign-out (reported stuck): re-seed + continue.
    final role2 = await entryRoleFor(ref, _acct);
    expect(roleSet(role2 ?? {}), containsAll(['prof', 'student']));
    await entryContinueWithRole(ref, () => true, _acct, role2!, 'student',
        checkNow: freshFloor);
    expect(container.read(appModeProvider), AppMode.student,
        reason: 'second online student Continue must land');
  });

  testWidgets('stale shell-pushed flow still exits after a bare mode switch',
      (t) async {
    // Exact stuck-hub sequence: shell auto-pushes the setup flow while
    // unenrolled → a bare mode switch (mark-screen Switch mode path:
    // setMode(unset) with no flow dismissal) disposes the pushing shell
    // while the flow stays open → mode back to student (fresh shell mounts
    // behind) → Continue as Student must dismiss the flow. The old
    // onComplete guarded on the dead shell's mounted flag and silently
    // no-op'd, stranding the same role page forever.
    const pkgChannel =
        MethodChannel('dev.fluttercommunity.plus/package_info');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pkgChannel, (call) async => {
              'appName': 'Proximity',
              'packageName': 'proximity.test',
              'version': '9.9.9',
              'buildNumber': '1',
            });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pkgChannel, null);
    });

    final auth = _SwitchAuth(_acct);
    final store = InMemoryDeviceStore();
    await store.writeInstallId(_installId);
    final cloud = FakeCloudSync(available: true, online: true);
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    cloud.roles['test-uid'] = RoleDoc(
      uid: 'test-uid',
      email: _email,
      name: 'Test User',
      roles: const ['prof', 'student'],
      displayName: 'Test User',
      lastMode: 'student',
      org: 'example.com',
      updatedAtMillis: now,
    );
    // Same-device binding (this install holds the enrollment) but no
    // local enrollment yet → the shell concludes unenrolled and pushes.
    cloud.devices[_email] = StudentDeviceDoc(
      email: _email,
      uid: 'test-uid',
      pkHex: _pkHex,
      name: 'Test User',
      roll: 'R1001',
      modelVer: kFaceVerifierVer,
      installId: _installId,
      platform: 'android',
      org: 'example.com',
      createdAtMillis: now,
      lastMoveAtMillis: 0,
      lastSeenAtMillis: now,
      updatedAtMillis: now,
      pkDHex: 'ef' * 32,
      attestationLevel: 'NONE',
    );
    cloud.installs[_installId] = _email;

    List<Override> shellOverrides() => [
          authServiceProvider.overrideWithValue(auth),
          cloudSyncProvider.overrideWithValue(cloud),
          deviceStoreProvider.overrideWithValue(store),
          faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
          deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
          enrollmentControllerProvider.overrideWith(
            (ref) => EnrollmentController(
              auth: ref.watch(authServiceProvider),
              store: ref.watch(deviceStoreProvider),
              verifier: FakeFaceVerifier(),
              deviceKey: FakeDeviceKey(),
              presenceGate: FakePresenceGate(),
            ),
          ),
          hostDriverProvider.overrideWithValue(FakeHostDriver()),
          studentDriverProvider
              .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
          bleEngineProvider
              .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
          blePermissionProvider.overrideWithValue(() async => true),
          btPowerProvider.overrideWithValue(() async => BtState.on),
        ];
    final container = ProviderContainer(overrides: shellOverrides());
    addTearDown(container.dispose);
    container.read(appModeProvider.notifier).state = AppMode.student;
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: proxLightTheme(),
        home: Consumer(builder: (context, ref, _) {
          final mode = ref.watch(appModeProvider);
          return mode == AppMode.student
              ? const StudentShell()
              : const LandingScreen();
        }),
      ),
    ));
    await _drain(t, 12);

    // Shell pushed the flow (role step: no local role cache at resolve
    // time, the hub seeds Continue from cloud).
    expect(find.text('Continue as Student'), findsOneWidget);

    // Bare mode switch with no flow dismissal: pushing shell is disposed,
    // the pushed flow route stays open on the root navigator.
    container.read(appModeProvider.notifier).state = AppMode.unset;
    await _drain(t);
    expect(find.text('Continue as Student'), findsOneWidget,
        reason: 'stale flow survives the bare switch');

    // Late-arriving local credential (restore completing after the push),
    // then mode back to student: fresh shell mounts behind the stale flow.
    await store.writeEnrollment(StoredEnrollment(
      email: _email,
      name: 'Test User',
      roll: 'R1001',
      pkHex: _pkHex,
      faceId: 'face-test-id',
      enrolledAt: DateTime.utc(2026, 9, 1),
      verifierVer: kFaceVerifierVer,
      org: 'example.com',
      pkDHex: 'ef' * 32,
      attestationLevel: 'NONE',
      attestedAt: DateTime.utc(2026, 9, 1),
      attestedUntil: DateTime.utc(2026, 11, 30),
    ));
    container.read(appModeProvider.notifier).state = AppMode.student;
    await _drain(t, 12);
    expect(find.text('Continue as Student'), findsOneWidget);

    // The tap relinks (sameDevice gate ok) and completes: the stale flow
    // must actually dismiss instead of stranding the same page.
    await t.tap(find.text('Continue as Student'));
    await _drain(t, 12);
    expect(find.text('Continue as Student'), findsNothing,
        reason: 'stale flow must dismiss on complete (was stuck)');
    expect(container.read(appModeProvider), AppMode.student);
    expect(t.takeException(), isNull);
  });
}
