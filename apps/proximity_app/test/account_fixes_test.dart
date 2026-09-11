// Regression tests for the three tester-reported Account-tab bugs:
//
// 1. Re-enroll after enrollment: enrolled for the signed-in account ⇒ the
//    Account page shows enrolled state and offers NO enroll CTA (enroll /
//    re-enroll / move entries all gated); re-scan stays on the face-id
//    sub-page only.
// 2. Stale account after switch: sign-out → sign-in as a different Gmail
//    shows the CURRENT account's email/org, never the previous account's
//    (stored enrollment + linked identity are scoped per account; the
//    shell remounts the tab root per Gmail).
// 3. Header/card UI: the student + professor header renders as a rounded
//    token-driven card (spec radius, flat border, clipped gradient wash),
//    never a flat square.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/account/account_screen.dart';
import 'package:proximity_app/features/account/face_id_screen.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/widgets/account_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _emailA = 'ada@school-a.edu';
const _emailB = 'bob@school-b.edu';
const _installId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _pkHexA =
    'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';

/// Stream-backed auth fake: emits on every sign-in/out like Firebase
/// `authStateChanges`, so account-switch tests exercise the live account
/// stream (the single-shot `FakeAuthService` stream cannot emit twice).
class SwitchableAuth implements AuthService {
  final _ctrl = StreamController<SignedAccount?>.broadcast();
  SignedAccount? _current;

  void signInAs(SignedAccount a) {
    _current = a.org.isNotEmpty
        ? a
        : SignedAccount(
            email: a.email,
            displayName: a.displayName,
            uid: a.uid,
            org: orgOf(a.email),
            photoUrl: a.photoUrl);
    _ctrl.add(_current);
  }

  @override
  Stream<SignedAccount?> watchAccount() => _ctrl.stream;

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

  void dispose() => _ctrl.close();
}

Future<InMemoryDeviceStore> _storeEnrolledAsA() async {
  final store = InMemoryDeviceStore();
  await store.writeInstallId(_installId);
  await store.writeEnrollment(StoredEnrollment(
    email: _emailA,
    name: 'Ada A',
    roll: 'RA1001',
    seedHex: 'ab' * 32,
    pkHex: _pkHexA,
    faceId: 'face-ada-id',
    enrolledAt: DateTime.utc(2026, 9, 1),
    verifierVer: kFaceVerifierVer,
    org: 'school-a.edu',
    pkDHex: 'ef' * 32,
    attestationLevel: 'NONE',
    attestedAt: DateTime.utc(2026, 9, 1),
    attestedUntil: DateTime.utc(2026, 11, 30),
  ));
  return store;
}

/// Server binding matching this install + key → `sameDevice` gate for A.
FakeCloudSync _boundCloudForA() {
  final cloud = FakeCloudSync();
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  cloud.devices[_emailA] = StudentDeviceDoc(
    email: _emailA,
    uid: 'uid-a',
    pkHex: _pkHexA,
    name: 'Ada A',
    roll: 'RA1001',
    modelVer: kFaceVerifierVer,
    installId: _installId,
    platform: 'android',
    org: 'school-a.edu',
    createdAtMillis: now,
    lastSeenAtMillis: now,
    updatedAtMillis: now,
    pkDHex: 'ef' * 32,
    attestationLevel: 'NONE',
  );
  cloud.installs[_installId] = _emailA;
  return cloud;
}

const _linkedA = LinkedIdentity(
    name: 'Ada A', gmail: _emailA, roll: 'RA1001', org: 'school-a.edu');

List<Override> _overrides({
  required SwitchableAuth auth,
  required InMemoryDeviceStore store,
  FakeCloudSync? cloud,
}) {
  return [
    authServiceProvider.overrideWithValue(auth),
    cloudSyncProvider.overrideWithValue(cloud ?? FakeCloudSync()),
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('fix 1: no enroll CTA while enrolled for the signed-in account', () {
    testWidgets('enrolled state shows in sub-pages, no CTA on menu', (t) async {
      final auth = SwitchableAuth();
      addTearDown(auth.dispose);
      final container = ProviderContainer(
        overrides: _overrides(
            auth: auth,
            store: await _storeEnrolledAsA(),
            cloud: _boundCloudForA()),
      );
      addTearDown(container.dispose);
      // Seeded like the sign-in relink helper would (same-Gmail match).
      container.read(linkedIdentityProvider.notifier).state = _linkedA;
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      auth.signInAs(const SignedAccount(
          email: _emailA, displayName: 'Ada A', uid: 'uid-a'));
      await _drain(t);

      // Compact menu: rows only, no fact bodies, no enroll CTA.
      expect(find.byKey(const Key('account-row-enrollment')), findsOneWidget);
      expect(find.textContaining('Enrolled as $_emailA'), findsNothing);
      expect(find.text('01-09-2026'), findsNothing);
      expect(find.text('Enroll this device'), findsNothing);
      expect(find.text('Re-enroll this device'), findsNothing);
      expect(find.text('Move to this device'), findsNothing);
      // Facts live one level down.
      await t.tap(find.byKey(const Key('account-row-enrollment')));
      await _drain(t);
      expect(find.textContaining('Enrolled as $_emailA'), findsWidgets);
      expect(find.text('01-09-2026'), findsOneWidget);
      expect(find.text('Enroll this device'), findsNothing);
      expect(find.text('Move to this device'), findsNothing);
    });

    testWidgets('re-scan stays available only via the face-id sub-page',
        (t) async {
      final auth = SwitchableAuth();
      addTearDown(auth.dispose);
      final container = ProviderContainer(
        overrides: _overrides(
            auth: auth,
            store: await _storeEnrolledAsA(),
            cloud: _boundCloudForA()),
      );
      addTearDown(container.dispose);
      container.read(linkedIdentityProvider.notifier).state = _linkedA;
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      auth.signInAs(const SignedAccount(
          email: _emailA, displayName: 'Ada A', uid: 'uid-a'));
      await _drain(t);

      // The Account menu itself carries no re-scan entry.
      expect(find.text('Re-scan face'), findsNothing);
      // The Face ID row is still the one path in, and the sub-page keeps
      // its re-scan fallback.
      await t.ensureVisible(find.byKey(const Key('account-row-face-id')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-row-face-id')));
      await _drain(t);
      expect(find.byType(FaceIdScreen), findsOneWidget);
      expect(find.byKey(const Key('face-id-rescan')), findsOneWidget);
    });

    testWidgets('unenrolled account shows org, no enroll entry', (t) async {
      final auth = SwitchableAuth();
      addTearDown(auth.dispose);
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(auth: auth, store: InMemoryDeviceStore()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      auth.signInAs(const SignedAccount(
          email: _emailB, displayName: 'Bob B', uid: 'uid-b'));
      await _drain(t);

      // Menu rows exist; the Enrollment sub-page shows the current
      // account's org with no enroll entry (enrollment lives in SetupFlow).
      expect(find.byKey(const Key('account-row-enrollment')), findsOneWidget);
      await t.tap(find.byKey(const Key('account-row-enrollment')));
      await _drain(t);
      expect(find.byKey(const Key('account-enroll-entry')), findsNothing);
      expect(find.text('school-b.edu'), findsWidgets);
    });
  });

  group('fix 2: account switch shows the current account only', () {
    testWidgets('sign in A → sign out → sign in B shows B, never A',
        (t) async {
      final auth = SwitchableAuth();
      addTearDown(auth.dispose);
      // A's enrollment lingers in the device store across the switch —
      // sign-out never wipes it, which is what used to leak A's facts.
      final container = ProviderContainer(
        overrides: _overrides(
            auth: auth,
            store: await _storeEnrolledAsA(),
            cloud: _boundCloudForA()),
      );
      addTearDown(container.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));

      // Sign in as A (linked restored like the relink helper would).
      container.read(linkedIdentityProvider.notifier).state = _linkedA;
      auth.signInAs(const SignedAccount(
          email: _emailA, displayName: 'Ada A', uid: 'uid-a'));
      await _drain(t);
      expect(find.text(_emailA), findsWidgets);
      // Facts live in sub-pages now — menu shows rows, not bodies.
      expect(find.byKey(const Key('account-row-enrollment')), findsOneWidget);
      await t.tap(find.byKey(const Key('account-row-enrollment')));
      await _drain(t);
      expect(find.textContaining('Enrolled as $_emailA'), findsWidgets);
      expect(find.text('RA1001'), findsWidgets);
      // Back to menu for sign-out.
      await t.pageBack();
      await _drain(t);

      // Sign out through the real page action: identity clears immediately
      // (Welcome, no trace of A).
      await t.ensureVisible(find.byKey(const Key('account-sign-out')));
      await _drain(t);
      await t.tap(find.byKey(const Key('account-sign-out')));
      await _drain(t);
      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(find.text(_emailA), findsNothing);
      expect(find.textContaining('Enrolled as $_emailA'), findsNothing);
      expect(find.text('RA1001'), findsNothing);

      // Sign in as B: the page reflects B's email/org, never A's — even
      // though A's enrollment is still on file in the device store.
      auth.signInAs(const SignedAccount(
          email: _emailB, displayName: 'Bob B', uid: 'uid-b'));
      await _drain(t);
      expect(find.text(_emailB), findsWidgets);
      // B's org shows in the Enrollment sub-page, never A's.
      await t.tap(find.byKey(const Key('account-row-enrollment')));
      await _drain(t);
      expect(find.text('school-b.edu'), findsWidgets);
      expect(find.text(_emailA), findsNothing);
      expect(find.textContaining('Enrolled as $_emailA'), findsNothing);
      expect(find.text('RA1001'), findsNothing);
      expect(find.text('school-a.edu'), findsNothing);
      // B holds no key here: no enroll entry (enrollment lives in SetupFlow).
      expect(find.byKey(const Key('account-enroll-entry')), findsNothing);
    });
  });

  group('fix 3: rounded header card, never a flat square', () {
    testWidgets('student header card uses spec radius + flat border',
        (t) async {
      final auth = SwitchableAuth();
      addTearDown(auth.dispose);
      final container = ProviderContainer(
        overrides: _overrides(
            auth: auth,
            store: await _storeEnrolledAsA(),
            cloud: _boundCloudForA()),
      );
      addTearDown(container.dispose);
      container.read(linkedIdentityProvider.notifier).state = _linkedA;
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      auth.signInAs(const SignedAccount(
          email: _emailA, displayName: 'Ada A', uid: 'uid-a'));
      await _drain(t);

      final header =
          t.widget<Container>(find.byKey(const Key('account-header-card')));
      final decor = header.decoration! as BoxDecoration;
      expect(decor.borderRadius, ProxRadii.cardSpecRadius);
      expect(decor.border, isNotNull);
      expect(decor.boxShadow ?? const [], isEmpty);
      expect(header.clipBehavior, Clip.antiAlias);
      // The approved large-header wash stays inside the card.
      expect(
          find.descendant(
              of: find.byKey(const Key('account-header-card')),
              matching: find.byType(AccountChip)),
          findsOneWidget);
    });

    testWidgets('professor header card uses spec radius + flat border',
        (t) async {
      final auth = SwitchableAuth();
      addTearDown(auth.dispose);
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(auth: auth, store: InMemoryDeviceStore()),
        child:
            MaterialApp(theme: proxLightTheme(), home: const ProfAccountScreen()),
      ));
      auth.signInAs(const SignedAccount(
          email: _emailA, displayName: 'Ada A', uid: 'uid-a'));
      await _drain(t);

      final header =
          t.widget<Container>(find.byKey(const Key('account-header-card')));
      final decor = header.decoration! as BoxDecoration;
      expect(decor.borderRadius, ProxRadii.cardSpecRadius);
      expect(decor.border, isNotNull);
      expect(decor.boxShadow ?? const [], isEmpty);
      expect(header.clipBehavior, Clip.antiAlias);
    });
  });
}
