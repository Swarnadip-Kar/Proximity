// Account-section widget contracts (§5.1–§5.3 + §4.3/§4.5/§4.7).
//
// Pins the consolidated pages only: sections render, the ID row is
// read-only (gap-2 verdict — no server write path, so no TextField),
// face-id shows status with NEVER a preview widget, the theme control
// persists, the professor page carries no face content, and records-only
// devices see the records note instead of key/move UI.
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
import 'package:proximity_app/features/account/account_screen.dart';
import 'package:proximity_app/features/account/face_id_screen.dart';
import 'package:proximity_app/features/account/theme_mode.dart';
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

/// Stepped pumps (repo convention NAV-D6): lets each periodic tick's async
/// tail + one-shot entrance timers settle without `pumpAndSettle`'s
/// no-pending-timers teardown assertion tripping on them.
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('student account page', () {
    testWidgets('renders all sections with enrolled facts', (t) async {
      final store = await _enrolledStore();
      await _pumpAccount(t, const StudentAccountScreen(), extra: [
        deviceStoreProvider.overrideWithValue(store),
        cloudSyncProvider.overrideWithValue(_boundCloud()),
      ]);

      // Header (initials avatar — no photo field exists to render).
      expect(find.text('Test User'), findsWidgets);
      expect(find.text(_email), findsWidgets);
      // Sections.
      expect(find.text('Enrollment'), findsOneWidget);
      expect(find.text('ID'), findsOneWidget);
      expect(find.text('Face ID'), findsWidgets);
      expect(find.text('Device'), findsOneWidget);
      expect(find.text('Device model'), findsOneWidget);
      expect(find.text('Theme'), findsWidgets);
      expect(find.byKey(const Key('account-theme-control')), findsOneWidget);
      expect(find.text('System log'), findsOneWidget);
      expect(find.text('Switch account (sign out)'), findsOneWidget);
      // Enrolled facts.
      expect(find.textContaining('Enrolled as $_email'), findsWidgets);
      expect(find.text('2026-09-01'), findsOneWidget);
      expect(find.text('example.com'), findsWidgets);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('android'), findsOneWidget);
      // Trust tier visible, explainer collapsed behind Details.
      expect(find.textContaining('Device NONE'), findsWidgets);
      expect(find.text('What this means'), findsWidgets);
      // Re-enroll entry stays fallback weight (text button, not primary).
      expect(find.text('Re-enroll this device'), findsOneWidget);
    });

    testWidgets('ID row is read-only: value shown, no edit control',
        (t) async {
      final store = await _enrolledStore();
      await _pumpAccount(t, const StudentAccountScreen(), extra: [
        deviceStoreProvider.overrideWithValue(store),
        cloudSyncProvider.overrideWithValue(_boundCloud()),
      ]);

      expect(find.byKey(const Key('account-id-row')), findsOneWidget);
      expect(find.text('R1001'), findsWidgets);
      // Gap-2 verdict pin: no write path exists server-side, so no editor.
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('cooldown gate shows verbatim re-enroll date, no move entry',
        (t) async {
      final store = await _enrolledStore();
      final movedAt = DateTime.now().toUtc().millisecondsSinceEpoch -
          const Duration(days: 1).inMilliseconds;
      await _pumpAccount(t, const StudentAccountScreen(), extra: [
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

    testWidgets('eligible move shows the Move-to-this-device fallback',
        (t) async {
      final store = await _enrolledStore();
      await _pumpAccount(t, const StudentAccountScreen(), extra: [
        deviceStoreProvider.overrideWithValue(store),
        // Pre-timestamp binding on another install → allowedMove.
        cloudSyncProvider.overrideWithValue(_boundCloud(
          installId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          pkHex: 'aa' * 32,
        )),
      ]);

      expect(find.text('Eligible to move here'), findsOneWidget);
      expect(find.text('Move to this device'), findsOneWidget);
    });

    testWidgets('face-id row pushes the isolated status page', (t) async {
      final store = await _enrolledStore();
      await _pumpAccount(t, const StudentAccountScreen(), extra: [
        deviceStoreProvider.overrideWithValue(store),
        cloudSyncProvider.overrideWithValue(_boundCloud()),
      ]);

      await t.ensureVisible(find.byKey(const Key('account-face-id-row')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-face-id-row')));
      await _drain(t);

      expect(find.byType(FaceIdScreen), findsOneWidget);
      expect(find.textContaining('Enrolled ·'), findsOneWidget);
      // Never-preview assertion: no image widget anywhere on the page.
      expect(find.byType(Image), findsNothing);
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

    testWidgets('theme control persists the choice', (t) async {
      final container = ProviderContainer(overrides: _accountOverrides());
      addTearDown(container.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child:
            MaterialApp(theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      expect(container.read(themeModeProvider), ThemeMode.system);
      await t.ensureVisible(find.text('Dark'));
      await _drain(t);
      await t.tap(find.text('Dark'));
      await _drain(t);

      expect(container.read(themeModeProvider), ThemeMode.dark);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(themeModePrefsKey), 'dark');
    });

    testWidgets('records-only device sees the records note, no key/move UI',
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
        expect(find.text('Move status'), findsNothing);
        expect(find.text('Face ID'), findsNothing);
        // Header, theme, log, sign-out stay.
        expect(find.text('Theme'), findsWidgets);
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

  group('professor account page', () {
    testWidgets('device/key/theme/log/sign-out, no face content', (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId(_installId);
      await store.writeHostName('Prof Name');
      await _pumpAccount(t, const ProfAccountScreen(), extra: [
        deviceStoreProvider.overrideWithValue(store),
      ]);

      expect(find.text('Test User'), findsWidgets);
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('Prof Name'), findsOneWidget);
      expect(find.textContaining('aaaaaaaaaaaa'), findsOneWidget);
      expect(find.text('Theme'), findsWidgets);
      expect(find.text('System log'), findsOneWidget);
      expect(find.text('Switch account (sign out)'), findsOneWidget);
      // No Face-ID section/route, no enrollment-status section.
      expect(find.text('Face ID'), findsNothing);
      expect(find.text('Enrollment'), findsNothing);
      expect(find.byType(FaceIdScreen), findsNothing);
    });
  });

  group('shell tabs', () {
    testWidgets('Account tabs host the consolidated pages', (t) async {
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

      // Mark gate stays shut (linked), Mark tab lands on browse.
      expect(find.byType(StudentHomeScreen), findsOneWidget);
      // Tap the bar label itself (tapping the whole bar hits its center).
      await t.tap(find.text('Account'));
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }

      expect(find.byType(StudentAccountScreen), findsOneWidget);
      expect(find.byKey(const Key('account-id-row')), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });
  });
}
