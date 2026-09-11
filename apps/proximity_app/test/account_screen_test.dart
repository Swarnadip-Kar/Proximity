// Account-section widget contracts (overhaul: compact menu + sub-pages).
//
// Pins the menu root (header + mode tabs + rows only, no section bodies)
// plus the one-feature sub-pages: enrollment (+ editable ID), device
// (facts + truthful trust), appearance (theme), face-id (never preview),
// professor menu. Records-only hides native rows behind the records note.
import 'package:flutter/foundation.dart';
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
import 'package:proximity_app/features/account/account_device_page.dart';
import 'package:proximity_app/features/account/account_enrollment_page.dart';
import 'package:proximity_app/features/account/account_header.dart';
import 'package:proximity_app/features/account/account_screen.dart';
import 'package:proximity_app/features/account/face_id_screen.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_app/screens/student_home.dart';
import 'package:proximity_ble/ble.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _email = 'student@example.com';
const _installId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _pkHex =
    'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';

const _linked = LinkedIdentity(
    name: 'Test User', gmail: _email, roll: 'R1001', org: 'example.com');

Future<InMemoryDeviceStore> _enrolledStore() async {
  final store = InMemoryDeviceStore();
  await store.writeInstallId(_installId);
  await store.writeEnrollment(StoredEnrollment(
    email: _email,
    name: 'Test User',
    roll: 'R1001',
    seedHex: 'ab' * 32,
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

/// Server binding matching this install + key → `sameDevice` gate.
FakeCloudSync _boundCloud({
  String installId = _installId,
  String pkHex = _pkHex,
  int lastMoveAtMillis = 0,
  int lastSeenAtMillis = 0,
}) {
  final cloud = FakeCloudSync();
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  cloud.devices[_email] = StudentDeviceDoc(
    email: _email,
    uid: 'test-uid',
    pkHex: pkHex,
    name: 'Test User',
    roll: 'R1001',
    modelVer: kFaceVerifierVer,
    installId: installId,
    platform: 'android',
    org: 'example.com',
    createdAtMillis: now,
    lastMoveAtMillis: lastMoveAtMillis,
    lastSeenAtMillis:
        lastSeenAtMillis == 0 ? now : lastSeenAtMillis,
    updatedAtMillis: now,
    pkDHex: 'ef' * 32,
    attestationLevel: 'NONE',
  );
  cloud.installs[installId] = _email;
  return cloud;
}

List<Override> _accountOverrides({
  InMemoryDeviceStore? store,
  FakeCloudSync? cloud,
  LinkedIdentity? linked = _linked,
  String? email = _email,
}) {
  return [
    authServiceProvider.overrideWithValue(FakeAuthService(
        email == null
            ? null
            : SignedAccount(
                email: email,
                displayName: 'Test User',
                uid: 'test-uid',
                org: 'example.com'))),
    cloudSyncProvider.overrideWithValue(cloud ?? FakeCloudSync()),
    deviceStoreProvider.overrideWithValue(store ?? InMemoryDeviceStore()),
    faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
    deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
    if (linked != null) linkedIdentityProvider.overrideWith((ref) => linked),
    enrollmentControllerProvider.overrideWith(
      (ref) => EnrollmentController(
        auth: ref.watch(authServiceProvider),
        store: ref.watch(deviceStoreProvider),
        verifier: FakeFaceVerifier(),
        deviceKey: FakeDeviceKey(),
      ),
    ),
  ];
}

/// Stepped pumps (repo convention NAV-D6).
Future<void> _drain(WidgetTester t, [int steps = 6]) async {
  await t.pump();
  for (var i = 0; i < steps; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _pumpAccount(WidgetTester t, Widget home,
    {List<Override>? extra}) async {
  await t.pumpWidget(ProviderScope(
    overrides: [..._accountOverrides(), ...?extra],
    child: MaterialApp(theme: proxLightTheme(), home: home),
  ));
  await _drain(t);
}

const _acct = SignedAccount(
    email: _email, displayName: 'Test User', uid: 'test-uid', org: 'example.com');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('student account menu (compact root)', () {
    testWidgets('root renders header + rows only, no section bodies', (t) async {
      final store = await _enrolledStore();
      await _pumpAccount(t, const StudentAccountScreen(), extra: [
        deviceStoreProvider.overrideWithValue(store),
        cloudSyncProvider.overrideWithValue(_boundCloud()),
      ]);

      expect(find.text('Test User'), findsWidgets);
      expect(find.text(_email), findsWidgets);
      expect(find.byKey(const Key('account-row-enrollment')), findsOneWidget);
      expect(find.byKey(const Key('account-row-device')), findsOneWidget);
      expect(find.byKey(const Key('account-row-appearance')), findsNothing);
      expect(find.byKey(const Key('account-row-face-id')), findsOneWidget);
      expect(find.text('System log'), findsOneWidget);
      expect(find.text('Switch account (sign out)'), findsOneWidget);
      // Appearance lives inline at the root end (no sub-page, no row).
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.byKey(const Key('account-theme-control')), findsOneWidget);
      // Compactness: no embedded fact bodies on the root.
      expect(find.text('01-09-2026'), findsNothing);
      expect(find.text('Active'), findsNothing);
      expect(find.text('android'), findsNothing);
      expect(find.textContaining('Device NONE'), findsNothing);
      expect(find.byKey(const Key('account-id-row')), findsNothing);
      expect(find.text('Re-enroll this device'), findsNothing);
      expect(find.text('Enroll this device'), findsNothing);
      expect(find.text('Move to this device'), findsNothing);
    });

    testWidgets('enrollment sub-page holds enrolled facts + editable ID',
        (t) async {
      final store = await _enrolledStore();
      await _pumpAccount(t, AccountEnrollmentPage(acct: _acct), extra: [
        deviceStoreProvider.overrideWithValue(store),
        cloudSyncProvider.overrideWithValue(_boundCloud()),
      ]);

      expect(find.textContaining('Enrolled as $_email'), findsWidgets);
      expect(find.text('01-09-2026'), findsOneWidget);
      expect(find.text('example.com'), findsWidgets);
      expect(find.byKey(const Key('account-id-row')), findsOneWidget);
      expect(find.text('R1001'), findsWidgets);
      // Editable (overhaul business addition): Edit opens the field.
      expect(find.byKey(const Key('account-id-edit')), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await t.tap(find.byKey(const Key('account-id-edit')));
      await _drain(t);
      expect(find.byKey(const Key('account-id-field')), findsOneWidget);
      expect(find.byKey(const Key('account-id-save')), findsOneWidget);
    });

    testWidgets('device sub-page holds facts + truthful trust', (t) async {
      final store = await _enrolledStore();
      await _pumpAccount(t, AccountDevicePage(acct: _acct), extra: [
        deviceStoreProvider.overrideWithValue(store),
        cloudSyncProvider.overrideWithValue(_boundCloud()),
      ]);

      expect(find.text('Device model'), findsOneWidget);
      expect(find.byKey(const Key('account-device-id-row')), findsOneWidget);
      expect(find.byKey(const Key('account-device-id-full')), findsOneWidget);
      expect(find.byKey(const Key('account-device-key-row')), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('android'), findsOneWidget);
      expect(find.textContaining('Device NONE'), findsWidgets);
      expect(find.byKey(const Key('account-trust-note')), findsOneWidget);
    });

    testWidgets('cooldown gate shows verbatim re-enroll date', (t) async {
      final store = await _enrolledStore();
      final movedAt = DateTime.now().toUtc().millisecondsSinceEpoch -
          const Duration(days: 1).inMilliseconds;
      await _pumpAccount(t, AccountDevicePage(acct: _acct), extra: [
        deviceStoreProvider.overrideWithValue(store),
        cloudSyncProvider.overrideWithValue(_boundCloud(
          installId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          pkHex: 'aa' * 32,
          lastMoveAtMillis: movedAt,
        )),
      ]);

      expect(find.textContaining('Move cooldown until'), findsOneWidget);
      expect(
          find.textContaining('You can re-enroll this device on'),
          findsWidgets);
      expect(find.text('Move to this device'), findsNothing);
    });

    testWidgets('eligible move shows badge, no Move fallback',
        (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId(_installId);
      await store.writeEnrollment(StoredEnrollment(
        email: 'other@example.edu',
        name: 'Other User',
        roll: 'R9999',
        seedHex: 'cd' * 32,
        pkHex: 'bb' * 32,
        faceId: 'face-other-id',
        enrolledAt: DateTime.utc(2026, 9, 1),
        verifierVer: kFaceVerifierVer,
        org: 'example.edu',
        pkDHex: 'aa' * 32,
        attestationLevel: 'NONE',
        attestedAt: DateTime.utc(2026, 9, 1),
        attestedUntil: DateTime.utc(2026, 11, 30),
      ));
      await t.pumpWidget(ProviderScope(
        overrides: _accountOverrides(
          store: store,
          linked: null,
          cloud: _boundCloud(
            installId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            pkHex: 'aa' * 32,
          ),
        ),
        child: MaterialApp(
            theme: proxLightTheme(), home: AccountDevicePage(acct: _acct)),
      ));
      await _drain(t);

      expect(find.text('Eligible to move here'), findsOneWidget);
      expect(find.text('Move to this device'), findsNothing);
      expect(find.textContaining('Enrolled as other@example.edu'),
          findsNothing);
      expect(find.text('R9999'), findsNothing);
    });

    testWidgets('face-id row pushes the isolated status page', (t) async {
      final store = await _enrolledStore();
      await _pumpAccount(t, const StudentAccountScreen(), extra: [
        deviceStoreProvider.overrideWithValue(store),
        cloudSyncProvider.overrideWithValue(_boundCloud()),
      ]);

      await t.ensureVisible(find.byKey(const Key('account-row-face-id')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-row-face-id')));
      await _drain(t);

      expect(find.byType(FaceIdScreen), findsOneWidget);
      expect(find.textContaining('Enrolled ·'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('enrollment row pushes the enrollment sub-page', (t) async {
      final store = await _enrolledStore();
      await _pumpAccount(t, const StudentAccountScreen(), extra: [
        deviceStoreProvider.overrideWithValue(store),
        cloudSyncProvider.overrideWithValue(_boundCloud()),
      ]);

      await t.tap(find.byKey(const Key('account-row-enrollment')));
      await _drain(t);
      expect(find.byType(AccountEnrollmentPage), findsOneWidget);
      expect(find.byKey(const Key('account-id-row')), findsOneWidget);
    });

    testWidgets('device row pushes the device sub-page', (t) async {
      final store = await _enrolledStore();
      await _pumpAccount(t, const StudentAccountScreen(), extra: [
        deviceStoreProvider.overrideWithValue(store),
        cloudSyncProvider.overrideWithValue(_boundCloud()),
      ]);

      await t.tap(find.byKey(const Key('account-row-device')));
      await _drain(t);
      expect(find.byType(AccountDevicePage), findsOneWidget);
      expect(find.byKey(const Key('account-device-id-row')), findsOneWidget);
    });

    testWidgets('appearance renders inline at the root end, no sub-page',
        (t) async {
      await _pumpAccount(t, const StudentAccountScreen());
      expect(find.byKey(const Key('account-row-appearance')), findsNothing);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.byKey(const Key('account-theme-control')), findsOneWidget);
    });

    testWidgets('signed out renders Welcome (hub-route behavior preserved)',
        (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: _accountOverrides(email: null, linked: null),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      expect(find.text('Sign in with Google'), findsOneWidget);
    });

    testWidgets('sign-out clears auth + linked identity', (t) async {
      final container = ProviderContainer(overrides: _accountOverrides());
      addTearDown(container.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child:
            MaterialApp(theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      await t.ensureVisible(find.byKey(const Key('account-sign-out')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-sign-out')));
      await _drain(t);

      expect(container.read(linkedIdentityProvider), isNull);
    });

    testWidgets('records-only device sees the records note, no native rows',
        (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final store = await _enrolledStore();
        await _pumpAccount(t, const StudentAccountScreen(), extra: [
          deviceStoreProvider.overrideWithValue(store),
        ]);

        expect(
            find.text(
                'Records view only here — enrollment, keys, and device moves live in the mobile app (Android/iOS).'),
            findsOneWidget);
        expect(find.byKey(const Key('account-row-enrollment')), findsNothing);
        expect(find.byKey(const Key('account-row-device')), findsNothing);
        expect(find.byKey(const Key('account-row-face-id')), findsNothing);
        expect(find.byKey(const Key('account-row-appearance')), findsNothing);
        // Header, inline appearance, log, sign-out stay.
        expect(find.text('Appearance'), findsOneWidget);
        expect(find.byKey(const Key('account-theme-control')), findsOneWidget);
        expect(find.text('System log'), findsOneWidget);
        expect(find.text('Switch account (sign out)'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('face-id page', () {
    testWidgets('stale pipeline shows Needs re-face, still no preview',
        (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId(_installId);
      await store.writeEnrollment(StoredEnrollment(
        email: _email,
        name: 'Test User',
        roll: 'R1001',
        seedHex: 'ab' * 32,
        pkHex: _pkHex,
        faceId: 'face-test-id',
        enrolledAt: DateTime.utc(2026, 9, 1),
        verifierVer: 'edgeface-xs-g06-tflite-1',
      ));
      await _pumpAccount(t, const FaceIdScreen(), extra: [
        deviceStoreProvider.overrideWithValue(store),
      ]);

      expect(find.byKey(const Key('face-id-status')), findsOneWidget);
      expect(find.text('Needs re-face'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.text('Re-scan face'), findsOneWidget);
    });

    testWidgets('records-only device sees the blocked card', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await _pumpAccount(t, const FaceIdScreen());
        expect(find.text('Face ID needs the mobile app'), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('professor account menu', () {
    testWidgets('rows push device/appearance, no face content', (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId(_installId);
      await store.writeHostName('Prof Name');
      await _pumpAccount(t, const ProfAccountScreen(), extra: [
        deviceStoreProvider.overrideWithValue(store),
      ]);

      expect(find.text('Test User'), findsWidgets);
      expect(find.byKey(const Key('account-row-device')), findsOneWidget);
      expect(find.byKey(const Key('account-row-appearance')), findsNothing);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.byKey(const Key('account-theme-control')), findsOneWidget);
      expect(find.text('System log'), findsOneWidget);
      expect(find.text('Switch account (sign out)'), findsOneWidget);
      expect(find.byKey(const Key('account-row-face-id')), findsNothing);
      expect(find.byKey(const Key('account-row-enrollment')), findsNothing);
      expect(find.text('Face ID'), findsNothing);
      expect(find.text('Enrollment'), findsNothing);
      expect(find.byType(FaceIdScreen), findsNothing);
      // Facts live one level down, not on the root.
      expect(find.text('Prof Name'), findsNothing);
      await t.tap(find.byKey(const Key('account-row-device')));
      await _drain(t);
      expect(find.text('Prof Name'), findsOneWidget);
      expect(find.textContaining('aaaaaaaaaaaa'), findsWidgets);
      expect(find.byKey(const Key('account-device-id-full')), findsOneWidget);
    });
  });

  group('professor account offline (local-only)', () {
    Future<void> pumpOffline(WidgetTester t, {List<Override>? extra}) async {
      await t.pumpWidget(ProviderScope(
        overrides: [
          ..._accountOverrides(email: null, linked: null),
          ...?extra,
        ],
        child: MaterialApp(
            theme: proxLightTheme(), home: const ProfAccountScreen()),
      ));
      await _drain(t);
    }

    testWidgets('offline prof gets the local page, not a dead end',
        (t) async {
      await pumpOffline(t);

      // Local-safe rows render; the sign-in dead end does not.
      expect(find.textContaining('Offline professor mode'), findsOneWidget);
      expect(find.byKey(const Key('account-row-device')), findsOneWidget);
      expect(find.text('Exports'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('System log'), findsOneWidget);
      expect(find.text('Switch account (sign out)'), findsOneWidget);
      expect(find.text('Sign in with Google'), findsNothing);
      expect(find.byType(AccountHeaderCard), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('offline device sub-page is honest, never another identity',
        (t) async {
      await pumpOffline(t);

      await t.tap(find.byKey(const Key('account-row-device')));
      await _drain(t);
      expect(find.byType(AccountProfDevicePage), findsOneWidget);
      expect(find.text('Not signed in'), findsOneWidget);
      expect(find.text('Test User'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('previous account enrollment never leaks offline',
        (t) async {
      // Another Gmail's enrollment + linked identity linger in state
      // while signed out: the offline page must show none of it.
      final store = InMemoryDeviceStore();
      await store.writeInstallId(_installId);
      await store.writeEnrollment(StoredEnrollment(
        email: 'other@example.com',
        name: 'Other User',
        roll: 'R9',
        seedHex: 'ab' * 32,
        pkHex: 'cd' * 32,
        faceId: 'face-other',
        enrolledAt: DateTime.utc(2026, 9, 1),
        verifierVer: kFaceVerifierVer,
        org: 'example.com',
        pkDHex: 'ef' * 32,
        attestationLevel: 'NONE',
        attestedAt: DateTime.utc(2026, 9, 1),
        attestedUntil: DateTime.utc(2026, 11, 30),
      ));
      await t.pumpWidget(ProviderScope(
        overrides: [
          ..._accountOverrides(email: null, linked: null),
          deviceStoreProvider.overrideWithValue(store),
          linkedIdentityProvider.overrideWith((ref) =>
              const LinkedIdentity(name: 'Other User', gmail: 'other@example.com', roll: 'R9')),
        ],
        child: MaterialApp(
            theme: proxLightTheme(), home: const ProfAccountScreen()),
      ));
      await _drain(t);

      expect(find.textContaining('Offline professor mode'), findsOneWidget);
      expect(find.text('Other User'), findsNothing);
      expect(find.text('other@example.com'), findsNothing);
      expect(find.textContaining('Enrolled as'), findsNothing);
      expect(find.byType(AccountHeaderCard), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('offline sign-out is safe', (t) async {
      await pumpOffline(t);

      await t.ensureVisible(find.byKey(const Key('account-sign-out')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-sign-out')));
      await _drain(t);

      expect(t.takeException(), isNull);
      // Still the offline local page (no crash, no redirect into auth).
      expect(find.textContaining('Offline professor mode'), findsOneWidget);
    });
  });

  group('shell tabs', () {
    testWidgets('Account tabs host the menu roots', (t) async {
      final store = await _enrolledStore();
      await t.pumpWidget(ProviderScope(
        overrides: [
          ..._accountOverrides(
              store: store, cloud: _boundCloud()),
          hostDriverProvider.overrideWithValue(FakeHostDriver()),
          studentDriverProvider
              .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
          bleEngineProvider
              .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
          blePermissionProvider.overrideWithValue(() async => true),
          btPowerProvider.overrideWithValue(() async => BtState.on),
        ],
        child: MaterialApp(theme: proxLightTheme(), home: const StudentShell()),
      ));
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }

      expect(find.byType(StudentHomeScreen), findsOneWidget);
      await t.tap(find.text('Account'));
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }

      expect(find.byType(StudentAccountScreen), findsOneWidget);
      expect(find.byKey(const Key('account-row-enrollment')), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });
  });
}
