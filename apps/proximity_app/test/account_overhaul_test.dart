// Account overhaul verification (tester-verified items + compactness).
//
// Covers: submenu navigation (menu → one-feature sub-pages), one-button
// mode switch (renders for any signed-in account; press runs the mirrored
// mark-screen exit path — hub resume covered by the entry tests), ID edit
// success/collision/rules-denied/local-sync (+ history untouched), device
// facts render + trust honesty (truthful NONE, never faked FULL), compact
// root (header + button + rows only, no section bodies).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/account/account_device_page.dart';
import 'package:proximity_app/features/account/account_enrollment_page.dart';
import 'package:proximity_app/features/account/account_screen.dart';
import 'package:proximity_app/features/account/face_id_screen.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/widgets/trust_cards.dart';
import 'package:proximity_storage/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _email = 'student@example.com';
const _otherEmail = 'other@example.com';
const _installId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherInstall = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _pkHex =
    'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';
const _pkDHex = 'efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef';

const _acct = SignedAccount(
    email: _email, displayName: 'Test User', uid: 'test-uid', org: 'example.com');
const _linked = LinkedIdentity(
    name: 'Test User', gmail: _email, roll: 'R1001', org: 'example.com');

Future<InMemoryDeviceStore> _enrolledStore({String roll = 'R1001'}) async {
  final store = InMemoryDeviceStore();
  await store.writeInstallId(_installId);
  await store.writeEnrollment(StoredEnrollment(
    email: _email,
    name: 'Test User',
    roll: roll,
    seedHex: 'ab' * 32,
    pkHex: _pkHex,
    faceId: 'face-test-id',
    enrolledAt: DateTime.utc(2026, 9, 1),
    verifierVer: kFaceVerifierVer,
    org: 'example.com',
    pkDHex: _pkDHex,
    attestationLevel: 'NONE',
    attestedAt: DateTime.utc(2026, 9, 1),
    attestedUntil: DateTime.utc(2026, 11, 30),
  ));
  return store;
}

FakeCloudSync _boundCloud({String roll = 'R1001'}) {
  final cloud = FakeCloudSync();
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  cloud.devices[_email] = StudentDeviceDoc(
    email: _email,
    uid: 'test-uid',
    pkHex: _pkHex,
    name: 'Test User',
    roll: roll,
    modelVer: kFaceVerifierVer,
    installId: _installId,
    platform: 'android',
    org: 'example.com',
    createdAtMillis: now,
    lastMoveAtMillis: 0,
    lastSeenAtMillis: now,
    updatedAtMillis: now,
    pkDHex: _pkDHex,
    attestationLevel: 'NONE',
  );
  cloud.installs[_installId] = _email;
  cloud.dir[_email] = StudentDirectoryEntry(
      email: _email, name: 'Test User', roll: roll, org: 'example.com');
  return cloud;
}

Map<String, String> _bothRoles({String lastMode = 'prof'}) => {
      'roles': 'prof,student',
      'role': lastMode,
      'lastMode': lastMode,
      'email': _email.toLowerCase(),
      'uid': 'test-uid',
      'displayName': 'Test User',
      'org': 'example.com',
    };

List<Override> _overrides({
  InMemoryDeviceStore? store,
  FakeCloudSync? cloud,
  LinkedIdentity? linked = _linked,
}) {
  return [
    authServiceProvider.overrideWithValue(FakeAuthService(_acct)),
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

Future<void> _drain(WidgetTester t, [int steps = 8]) async {
  await t.pump();
  for (var i = 0; i < steps; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('compact root', () {
    testWidgets('menu shows header + tabs + rows only', (t) async {
      final store = await _enrolledStore();
      await store.writeRole(_bothRoles());
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: _boundCloud()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      expect(find.byKey(const Key('account-header-card')), findsOneWidget);
      expect(find.byKey(const Key('account-mode-switch')), findsOneWidget);
      expect(find.text('Switch mode'), findsOneWidget);
      expect(find.byKey(const Key('account-row-enrollment')), findsOneWidget);
      expect(find.byKey(const Key('account-row-device')), findsOneWidget);
      expect(find.byKey(const Key('account-row-appearance')), findsNothing);
      expect(find.byKey(const Key('account-row-face-id')), findsOneWidget);
      expect(find.byKey(const Key('account-system-log-row')), findsOneWidget);
      expect(find.byKey(const Key('account-sign-out')), findsOneWidget);
      // Appearance is inline at the root end (no row, no sub-page).
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.byKey(const Key('account-theme-control')), findsOneWidget);
      // No fact bodies, no explainers, no embedded sections on the root.
      expect(find.text('2026-09-01'), findsNothing);
      expect(find.text('Active'), findsNothing);
      expect(find.byKey(const Key('account-id-row')), findsNothing);
      expect(find.byKey(const Key('account-device-id-row')), findsNothing);
      expect(find.text('What this means'), findsNothing);
      expect(find.text('Offline & hosting'), findsNothing);
    });
  });

  group('submenu navigation', () {
    testWidgets('each row pushes its one-feature sub-page', (t) async {
      final store = await _enrolledStore();
      Future<void> pumpRoot() async {
        await t.pumpWidget(ProviderScope(
          overrides: _overrides(store: store, cloud: _boundCloud()),
          child: MaterialApp(
              theme: proxLightTheme(), home: const StudentAccountScreen()),
        ));
        await _drain(t);
      }

      await pumpRoot();
      await t.tap(find.byKey(const Key('account-row-enrollment')));
      await _drain(t);
      expect(find.byType(AccountEnrollmentPage), findsOneWidget);
      await t.pageBack();
      await _drain(t);

      await t.tap(find.byKey(const Key('account-row-device')));
      await _drain(t);
      expect(find.byType(AccountDevicePage), findsOneWidget);
      await t.pageBack();
      await _drain(t);

      // Appearance has no row and no sub-page — it renders inline.
      expect(find.byKey(const Key('account-row-appearance')), findsNothing);
      expect(find.byKey(const Key('account-theme-control')), findsOneWidget);

      await t.tap(find.byKey(const Key('account-row-face-id')));
      await _drain(t);
      expect(find.byType(FaceIdScreen), findsOneWidget);
    });
  });

  group('one-button mode switch', () {
    testWidgets('renders for any signed-in account, no tabs', (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId(_installId);
      await store.writeRole(_bothRoles(lastMode: 'student'));
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: FakeCloudSync()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      expect(find.byKey(const Key('account-mode-switch')), findsOneWidget);
      expect(find.text('Switch mode'), findsOneWidget);
      expect(find.text('Prof'), findsNothing);
      expect(find.text('Student'), findsNothing);
    });

    testWidgets('press runs the mirrored exit path (prof → unset)',
        (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId(_installId);
      await store.writeRole(_bothRoles(lastMode: 'student'));
      final container = ProviderContainer(
          overrides: _overrides(store: store, cloud: FakeCloudSync()));
      addTearDown(container.dispose);
      container.read(appModeProvider.notifier).state = AppMode.prof;
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      await t.tap(find.text('Switch mode'));
      await _drain(t);
      expect(container.read(appModeProvider), AppMode.unset);
    });

    testWidgets('single-role account still gets the button', (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId(_installId);
      await store.writeRole({
        'roles': 'student',
        'role': 'student',
        'lastMode': 'student',
        'email': _email.toLowerCase(),
        'uid': 'test-uid',
        'displayName': 'Test User',
        'org': 'example.com',
      });
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: FakeCloudSync()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      expect(find.byKey(const Key('account-mode-switch')), findsOneWidget);
      expect(find.text('Switch mode'), findsOneWidget);
    });
  });

  group('ID edit', () {
    testWidgets('success updates cloud + local + linked, history untouched',
        (t) async {
      final store = await _enrolledStore();
      // Historical session keeps the old roll (immutable history).
      await store.appendHistory(ClassRecord(
        id: 's-hist',
        courseId: 'CS201',
        classLabel: 'CS201',
        dateIso: '2026-09-01',
        timestampIso: '2026-09-01T10:00:00.000Z',
        startIso: '2026-09-01T09:00:00.000Z',
        windows: const [
          {'student@example.com': true}
        ],
        names: const {'student@example.com': 'Test User'},
        rolls: const {'student@example.com': 'R1001'},
      ));
      final cloud = _boundCloud();
      final container = ProviderContainer(
          overrides: _overrides(store: store, cloud: cloud));
      addTearDown(container.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(),
            home: AccountEnrollmentPage(acct: _acct)),
      ));
      await _drain(t);

      await t.ensureVisible(find.byKey(const Key('account-id-edit')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-id-edit')));
      await _drain(t);
      await t.enterText(find.byKey(const Key('account-id-field')), 'R2002');
      await t.ensureVisible(find.byKey(const Key('account-id-save')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-id-save')));
      await _drain(t, 10);

      // Cloud binding + directory updated.
      expect(cloud.devices[_email]!.roll, 'R2002');
      expect(cloud.dir[_email]!.roll, 'R2002');
      // Local enrollment + linked identity in sync.
      expect((await store.readEnrollment())!.roll, 'R2002');
      expect(container.read(linkedIdentityProvider)!.roll, 'R2002');
      // History untouched.
      final hist = await store.readHistory();
      expect(hist.single.rolls['student@example.com'], 'R1001');
      expect(hist.single.names['student@example.com'], 'Test User');
      // Editing closed back to view.
      expect(find.byKey(const Key('account-id-row')), findsOneWidget);
    });

    testWidgets('empty validates, no overwrite', (t) async {
      final store = await _enrolledStore();
      final cloud = _boundCloud();
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: cloud),
        child: MaterialApp(
            theme: proxLightTheme(), home: AccountEnrollmentPage(acct: _acct)),
      ));
      await _drain(t);

      await t.ensureVisible(find.byKey(const Key('account-id-edit')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-id-edit')));
      await _drain(t);
      await t.enterText(find.byKey(const Key('account-id-field')), '   ');
      await t.ensureVisible(find.byKey(const Key('account-id-save')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-id-save')));
      await _drain(t);

      expect(find.text('ID Number is required.'), findsOneWidget);
      expect(cloud.devices[_email]!.roll, 'R1001');
      expect((await store.readEnrollment())!.roll, 'R1001');
    });

    testWidgets('collision shows already-held copy, no overwrite', (t) async {
      final store = await _enrolledStore();
      final cloud = _boundCloud();
      // Another student in the same org holds R2002.
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      cloud.devices[_otherEmail] = StudentDeviceDoc(
        email: _otherEmail,
        uid: 'uid-other',
        pkHex: 'ff' * 32,
        name: 'Other',
        roll: 'R2002',
        modelVer: kFaceVerifierVer,
        installId: _otherInstall,
        platform: 'android',
        org: 'example.com',
        createdAtMillis: now,
        lastSeenAtMillis: now,
        updatedAtMillis: now,
        pkDHex: 'aa' * 32,
        attestationLevel: 'NONE',
      );
      cloud.dir[_otherEmail] = const StudentDirectoryEntry(
          email: _otherEmail, name: 'Other', roll: 'R2002', org: 'example.com');
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: cloud),
        child: MaterialApp(
            theme: proxLightTheme(), home: AccountEnrollmentPage(acct: _acct)),
      ));
      await _drain(t);

      await t.ensureVisible(find.byKey(const Key('account-id-edit')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-id-edit')));
      await _drain(t);
      await t.enterText(find.byKey(const Key('account-id-field')), 'R2002');
      await t.ensureVisible(find.byKey(const Key('account-id-save')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-id-save')));
      await _drain(t, 10);

      expect(find.textContaining('already held'), findsOneWidget);
      expect(cloud.devices[_email]!.roll, 'R1001');
      expect((await store.readEnrollment())!.roll, 'R1001');
    });

    testWidgets('rules-denied shows friendly error, never raw text', (t) async {
      final store = await _enrolledStore();
      final cloud = _boundCloud()..denyIdUpdate = true;
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: cloud),
        child: MaterialApp(
            theme: proxLightTheme(), home: AccountEnrollmentPage(acct: _acct)),
      ));
      await _drain(t);

      await t.ensureVisible(find.byKey(const Key('account-id-edit')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-id-edit')));
      await _drain(t);
      await t.enterText(find.byKey(const Key('account-id-field')), 'R3003');
      await t.ensureVisible(find.byKey(const Key('account-id-save')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-id-save')));
      await _drain(t, 10);

      expect(find.textContaining('security rules'), findsOneWidget);
      expect(find.byType(AccountEnrollmentPage), findsOneWidget);
      // Never raw Firebase/grpc text.
      expect(find.textContaining('FirebaseException'), findsNothing);
      expect(find.textContaining('cloud_firestore'), findsNothing);
      expect(cloud.devices[_email]!.roll, 'R1001');
      expect((await store.readEnrollment())!.roll, 'R1001');
    });
  });

  group('device facts + trust honesty', () {
    testWidgets('device id + fingerprint render, tier truthful', (t) async {
      final store = await _enrolledStore();
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: _boundCloud()),
        child: MaterialApp(
            theme: proxLightTheme(), home: AccountDevicePage(acct: _acct)),
      ));
      await _drain(t);

      expect(find.byKey(const Key('account-device-id-row')), findsOneWidget);
      expect(find.byKey(const Key('account-device-id-full')), findsOneWidget);
      expect(find.text(_installId), findsOneWidget);
      expect(find.byType(SelectableText), findsWidgets);
      final expectedFp = trustPkDFingerprint(_pkDHex);
      expect(find.textContaining(expectedFp.substring(0, 8)), findsWidgets);
      expect(find.byKey(const Key('account-device-key-row')), findsOneWidget);
      // Truthful NONE on this software-backed build — never faked FULL.
      expect(find.textContaining('Device NONE'), findsWidgets);
      expect(find.textContaining('Device trust FULL'), findsNothing);
      expect(find.byKey(const Key('account-trust-note')), findsOneWidget);
      expect(find.textContaining('software-backed keys'), findsOneWidget);
      expect(find.textContaining('flagged fallback'), findsOneWidget);
    });
  });
}
