// Account photo plumbing (§4.3): the Google OAuth profile photo flows
// `SignedAccount.photoUrl` → `AccountChip(photoUrl:)` + shell
// `_AccountTabIcon`, with the deterministic initials avatar preserved for
// null/empty/failed loads. Presentation of existing account metadata only —
// NOT `face_verification` output; no verdict, timing, threshold, or network
// contract is asserted here.
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
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_app/widgets/account_chip.dart';
import 'package:proximity_ble/ble.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _email = 'student@example.com';
const _photo = 'https://example.invalid/avatar.png';

const _linked = LinkedIdentity(
    name: 'Test User', gmail: _email, roll: 'R1001', org: 'example.com');

List<Override> _overrides({String? photoUrl}) => [
      authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
        email: _email,
        displayName: 'Test User',
        uid: 'test-uid',
        org: 'example.com',
        photoUrl: photoUrl,
      ))),
      cloudSyncProvider.overrideWithValue(FakeCloudSync()),
      deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
      faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
      deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
      linkedIdentityProvider.overrideWith((ref) => _linked),
      enrollmentControllerProvider.overrideWith(
        (ref) => EnrollmentController(
          auth: ref.watch(authServiceProvider),
          store: ref.watch(deviceStoreProvider),
          verifier: FakeFaceVerifier(),
          deviceKey: FakeDeviceKey(),
        ),
      ),
    ];

/// Stepped pumps (repo convention NAV-D6): lets each periodic tick's async
/// tail settle without `pumpAndSettle`'s no-pending-timers assertion
/// tripping on them.
Future<void> _drain(WidgetTester t, [int steps = 6]) async {
  await t.pump();
  for (var i = 0; i < steps; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SignedAccount photo field', () {
    test('defaults to null and stays const-compatible', () {
      const a = SignedAccount(
          email: _email, displayName: 'Test User', uid: 'u', org: 'example.com');
      expect(a.photoUrl, isNull);
    });

    test('preserves an explicit photo URL', () {
      const a = SignedAccount(
          email: _email,
          displayName: 'Test User',
          uid: 'u',
          org: 'example.com',
          photoUrl: _photo);
      expect(a.photoUrl, _photo);
    });
  });

  group('FakeAuthService photo passthrough', () {
    test('constructor preserves photo through org derivation', () {
      final fake = FakeAuthService(const SignedAccount(
          email: _email, displayName: 'Test User', photoUrl: _photo));
      expect(fake.current?.photoUrl, _photo);
      // Org derivation still ran (empty org → domain).
      expect(fake.current?.org, 'example.com');
    });

    test('seedAccount preserves photo through org derivation', () {
      final fake = FakeAuthService();
      fake.seedAccount(const SignedAccount(
          email: _email, displayName: 'Test User', photoUrl: _photo));
      expect(fake.current?.photoUrl, _photo);
    });

    test('explicit org passes the same instance through', () {
      const a = SignedAccount(
          email: _email,
          displayName: 'Test User',
          uid: 'u',
          org: 'example.com',
          photoUrl: _photo);
      final fake = FakeAuthService(a);
      expect(identical(fake.current, a), isTrue);
      expect(fake.current?.photoUrl, _photo);
    });

    test('null photo stays null (fallback preserved)', () {
      final fake = FakeAuthService(const SignedAccount(
          email: _email, displayName: 'Test User'));
      expect(fake.current?.photoUrl, isNull);
    });
  });

  group('AccountChip photo contract', () {
    testWidgets('photo URL builds Image.network with that URL', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: const Scaffold(
          body: AccountChip(
            displayName: 'Test User',
            email: _email,
            photoUrl: _photo,
          ),
        ),
      ));
      // Pre-settle: the photo branch is taken before the failed fetch
      // resolves into the errorBuilder fallback.
      await t.pump();
      final image = testerImage(t);
      expect(image, isNotNull);
      expect((image!.image as NetworkImage).url, _photo);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('null photo renders initials, no Image', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: const Scaffold(
          body: AccountChip(
            displayName: 'Test User',
            email: _email,
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('TU'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('empty photo renders initials, no Image', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: const Scaffold(
          body: AccountChip(
            displayName: 'Test User',
            email: _email,
            photoUrl: '  ',
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('TU'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('failed photo load falls back to initials', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: const Scaffold(
          body: AccountChip(
            displayName: 'Ada Lovelace',
            email: 'ada@gmail.com',
            photoUrl: _photo,
            largeHeader: true,
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('AL'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image), findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('account screens feed acct.photoUrl into the chip', () {
    testWidgets('student header carries the account photo', (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(photoUrl: _photo),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      final chip = t.widget<AccountChip>(find.byType(AccountChip).first);
      expect(chip.photoUrl, _photo);
    });

    testWidgets('professor header carries the account photo', (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(photoUrl: _photo),
        child:
            MaterialApp(theme: proxLightTheme(), home: const ProfAccountScreen()),
      ));
      await _drain(t);

      final chip = t.widget<AccountChip>(find.byType(AccountChip).first);
      expect(chip.photoUrl, _photo);
    });

    testWidgets('null photo preserves the initials fallback', (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(photoUrl: null),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      final chip = t.widget<AccountChip>(find.byType(AccountChip).first);
      expect(chip.photoUrl, isNull);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('shell account tab icon', () {
    Future<void> pumpShell(WidgetTester t, {String? photoUrl}) async {
      await t.pumpWidget(ProviderScope(
        overrides: [
          ..._overrides(photoUrl: photoUrl),
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
    }

    testWidgets('photo account takes the ClipOval photo branch', (t) async {
      await pumpShell(t, photoUrl: _photo);
      await _drain(t, 2);
      // Photo branch wraps in ClipOval (initials-only renders a bare
      // CircleAvatar). The ClipOval survives even after the invalid-URL
      // fetch resolves into the errorBuilder fallback.
      expect(find.byType(ClipOval), findsWidgets);
    });

    testWidgets('null photo renders the bare initial, no photo widgets',
        (t) async {
      await pumpShell(t, photoUrl: null);
      await _drain(t, 2);

      expect(find.byType(ClipOval), findsNothing);
      expect(find.byType(Image), findsNothing);
      // Initials fallback for 'Test User'.
      expect(find.text('T'), findsWidgets);
    });
  });
}

/// First Image in the tree, or null when the initials fallback rendered.
Image? testerImage(WidgetTester t) {
  final finder = find.byType(Image);
  if (finder.evaluate().isEmpty) return null;
  return t.widget<Image>(finder.first);
}
