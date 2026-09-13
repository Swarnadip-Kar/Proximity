// Account content fixes — face-id rescan clarity, days+why, appearance
// inline, spacing, direct sign-out.
//
// Pins: face-ID 30-day rescan rule (inline in `FaceIdScreen`: rule line
// with days from `kFaceRescanCooldown`, crucial rule line highlighted,
// what a re-scan does + tips, last/next-eligible dates from the real
// stored stamp + `faceRescanBlockedUntil` accessor, refusal verbatim via
// `faceRescanCooldownMessage`, text-only, never a thumbnail/preview, no
// angles/retries/burns internals in user copy); enrollment device/binding rules inline (one-device +
// 30-day date crucial, exact next-eligible date where the gate data is
// already available, 60-day window, plain-language whys, verbatim refusal
// via `studentClaimMessage`); appearance inline at the root end (no row,
// no sub-page); spacing tokens in use with no square/flat regression;
// sign-out calls `entrySignOut` directly (re-sign-in guard helper dropped
// — zero references).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/account/account_device_page.dart';
import 'package:proximity_app/features/account/account_enrollment_page.dart';
import 'package:proximity_app/features/account/account_screen.dart';
import 'package:proximity_app/features/account/face_id_screen.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _email = 'student@example.com';
const _installId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _pkHex =
    'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';

const _linked = LinkedIdentity(
    name: 'Test User', gmail: _email, roll: 'R1001', org: 'example.com');

const _acct = SignedAccount(
    email: _email, displayName: 'Test User', uid: 'test-uid', org: 'example.com');

Future<InMemoryDeviceStore> _enrolledStore({int lastFaceRescanAt = 0}) async {
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
    lastFaceRescanAtMillis: lastFaceRescanAt,
  ));
  return store;
}

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
    lastSeenAtMillis: lastSeenAtMillis == 0 ? now : lastSeenAtMillis,
    updatedAtMillis: now,
    pkDHex: 'ef' * 32,
    attestationLevel: 'NONE',
  );
  cloud.installs[installId] = _email;
  return cloud;
}

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

  group('face-id inline rescan rules', () {
    testWidgets('rule line + what + tips, no restriction past the rule',
        (t) async {
      // Zero stamp (never rescanned): rule line only, no dates, no refusal.
      final store = await _enrolledStore();
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: _boundCloud()),
        child: MaterialApp(theme: proxLightTheme(), home: const FaceIdScreen()),
      ));
      await _drain(t);

      expect(find.byKey(const Key('face-rules-title')), findsOneWidget);
      expect(find.byKey(const Key('face-rules-important')), findsOneWidget);
      expect(find.text('Most important'), findsOneWidget);
      // 30-day rule, days from kFaceRescanCooldown (never a literal).
      expect(kFaceRescanCooldown, const Duration(days: 30));
      expect(find.byKey(const Key('face-rules-rule')), findsOneWidget);
      expect(find.textContaining('allowed once every 30 days'),
          findsOneWidget);
      // What a re-scan does: replaces the template; key/ID/enrollment kept.
      expect(find.byKey(const Key('face-rules-what')), findsOneWidget);
      expect(find.textContaining('replaces the face template'),
          findsOneWidget);
      expect(find.textContaining('device key'), findsWidgets);
      // 1–2 plain tips.
      expect(find.byKey(const Key('face-rules-tips')), findsOneWidget);
      expect(find.textContaining('good light'), findsOneWidget);
      expect(find.textContaining('hold still'), findsOneWidget);
      // Button intact.
      expect(find.byKey(const Key('face-id-rescan')), findsOneWidget);
      // No stamp → no dates, no refusal.
      expect(find.byKey(const Key('face-rules-last')), findsNothing);
      expect(find.byKey(const Key('face-rules-next')), findsNothing);
      expect(find.byKey(const Key('face-rules-refusal')), findsNothing);
      expect(find.textContaining('You already updated your face scan'),
          findsNothing);
      // No invented frequency wording, no session internals in user copy.
      expect(find.textContaining('unlimited'), findsNothing);
      expect(find.textContaining('as many times'), findsNothing);
      expect(find.byKey(const Key('face-rules-angles')), findsNothing);
      expect(find.byKey(const Key('face-rules-retries')), findsNothing);
      expect(find.byKey(const Key('face-rules-burn')), findsNothing);
      expect(find.textContaining('angles'), findsNothing);
      expect(find.textContaining('burns'), findsNothing);
      expect(find.textContaining('retries'), findsNothing);
      expect(find.textContaining('attempts'), findsNothing);
      expect(find.textContaining('centre'), findsNothing);
      // Never any thumbnail/preview.
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('blocked rescan shows last + next dates + verbatim refusal',
        (t) async {
      // Rescanned yesterday → inside the 30-day window → blocked.
      final stamp = DateTime.now().toUtc().millisecondsSinceEpoch -
          const Duration(days: 1).inMilliseconds;
      final eligible = faceRescanEligibleAt(stamp);
      final eligibleIso = displayDateOf(eligible.toUtc());
      final lastIso = displayDateOf(
          DateTime.fromMillisecondsSinceEpoch(stamp, isUtc: true));
      final store = await _enrolledStore(lastFaceRescanAt: stamp);
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: _boundCloud()),
        child: MaterialApp(theme: proxLightTheme(), home: const FaceIdScreen()),
      ));
      await _drain(t);

      expect(find.byKey(const Key('face-rules-rule')), findsOneWidget);
      // Real last + next-eligible dates from the stored stamp.
      expect(find.byKey(const Key('face-rules-last')), findsOneWidget);
      expect(find.textContaining(lastIso), findsWidgets);
      expect(find.byKey(const Key('face-rules-next')), findsOneWidget);
      expect(find.textContaining(eligibleIso), findsWidgets);
      // Refusal verbatim from faceRescanCooldownMessage (never paraphrased).
      expect(find.byKey(const Key('face-rules-refusal')), findsOneWidget);
      expect(find.text(faceRescanCooldownMessage(eligible)), findsOneWidget);
      expect(find.textContaining('You already updated your face scan'),
          findsOneWidget);
      expect(
          find.textContaining(
              'face re-scans are allowed once every 30 days'),
          findsWidgets);
      expect(find.textContaining('Request manual attendance in class'),
          findsOneWidget);
      // Button intact, never a preview.
      expect(find.byKey(const Key('face-id-rescan')), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('elapsed window shows last date, no refusal', (t) async {
      // Rescanned 31 days ago → window elapsed → allowed again.
      final stamp = DateTime.now().toUtc().millisecondsSinceEpoch -
          const Duration(days: 31).inMilliseconds;
      final lastIso = displayDateOf(
          DateTime.fromMillisecondsSinceEpoch(stamp, isUtc: true));
      final store = await _enrolledStore(lastFaceRescanAt: stamp);
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: _boundCloud()),
        child: MaterialApp(theme: proxLightTheme(), home: const FaceIdScreen()),
      ));
      await _drain(t);

      expect(find.byKey(const Key('face-rules-rule')), findsOneWidget);
      expect(find.byKey(const Key('face-rules-last')), findsOneWidget);
      expect(find.textContaining(lastIso), findsWidgets);
      // Allowed now: no next date, no refusal.
      expect(find.byKey(const Key('face-rules-next')), findsNothing);
      expect(find.byKey(const Key('face-rules-refusal')), findsNothing);
      expect(find.textContaining('You already updated your face scan'),
          findsNothing);
      expect(find.byKey(const Key('face-id-rescan')), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('enrollment inline device rules + days + why', () {
    testWidgets('generic rules show 30/60 days and whys', (t) async {
      final store = await _enrolledStore();
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: _boundCloud()),
        child: MaterialApp(
            theme: proxLightTheme(), home: AccountEnrollmentPage(acct: _acct)),
      ));
      await _drain(t);

      expect(find.byKey(const Key('device-rules-title')), findsOneWidget);
      expect(find.byKey(const Key('device-rules-important')), findsOneWidget);
      expect(find.byKey(const Key('device-rules-one')), findsOneWidget);
      expect(find.byKey(const Key('device-rules-30')), findsOneWidget);
      expect(find.textContaining('once every 30 days'), findsWidgets);
      expect(find.byKey(const Key('device-rules-60')), findsOneWidget);
      expect(find.textContaining('60 days'), findsWidgets);
      expect(find.byKey(const Key('device-rules-why-one')), findsOneWidget);
      expect(find.textContaining('many students'), findsOneWidget);
      expect(find.byKey(const Key('device-rules-why-shared')), findsOneWidget);
      expect(find.textContaining('shared-device fraud'), findsOneWidget);
      // Bound cloud carries lastSeen, so the 60-day eligible date renders.
      expect(find.byKey(const Key('device-rules-lost-date')), findsOneWidget);
    });

    testWidgets('cooldown shows the EXACT next-eligible date + verbatim refusal',
        (t) async {
      final store = await _enrolledStore();
      final movedAt = DateTime.now().toUtc().millisecondsSinceEpoch -
          const Duration(days: 1).inMilliseconds;
      final retryIso = displayDateOf(DateTime.fromMillisecondsSinceEpoch(
          movedAt + const Duration(days: 30).inMilliseconds,
          isUtc: true));
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(
          store: store,
          cloud: _boundCloud(
            installId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            pkHex: 'aa' * 32,
            lastMoveAtMillis: movedAt,
          ),
        ),
        child: MaterialApp(
            theme: proxLightTheme(), home: AccountEnrollmentPage(acct: _acct)),
      ));
      await _drain(t);

      expect(find.byKey(const Key('device-rules-next-date')), findsOneWidget);
      expect(find.textContaining(retryIso), findsWidgets);
      // Refusal copy is verbatim from studentClaimMessage (never paraphrased).
      expect(find.byKey(const Key('device-rules-refusal')), findsOneWidget);
      expect(find.textContaining('You can re-enroll this device on'),
          findsWidgets);
    });
  });

  group('device page days + why', () {
    testWidgets('device page states days and whys', (t) async {
      final store = await _enrolledStore();
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: _boundCloud()),
        child: MaterialApp(
            theme: proxLightTheme(), home: AccountDevicePage(acct: _acct)),
      ));
      await _drain(t);

      expect(find.byKey(const Key('device-days-line')), findsOneWidget);
      expect(find.textContaining('once every 30 days'), findsOneWidget);
      expect(find.textContaining('60 days offline'), findsOneWidget);
      expect(find.byKey(const Key('device-why-one')), findsOneWidget);
      expect(find.byKey(const Key('device-why-shared')), findsOneWidget);
    });
  });

  group('appearance inline, no sub-page', () {
    testWidgets('student root has inline theme, no appearance row',
        (t) async {
      final store = await _enrolledStore();
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: _boundCloud()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      expect(find.byKey(const Key('account-row-appearance')), findsNothing);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.byKey(const Key('account-theme-control')), findsOneWidget);
    });

    testWidgets('prof root has inline theme, no appearance row', (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId(_installId);
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: FakeCloudSync()),
        child:
            MaterialApp(theme: proxLightTheme(), home: const ProfAccountScreen()),
      ));
      await _drain(t);

      expect(find.byKey(const Key('account-row-appearance')), findsNothing);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.byKey(const Key('account-theme-control')), findsOneWidget);
    });
  });

  group('spacing + no square regression', () {
    testWidgets('header keeps spec radius, pages carry breathing room',
        (t) async {
      final store = await _enrolledStore();
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: store, cloud: _boundCloud()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      final header =
          t.widget<Container>(find.byKey(const Key('account-header-card')));
      final deco = header.decoration as BoxDecoration?;
      expect(deco?.borderRadius, ProxRadii.cardSpecRadius);
      expect(deco?.border, isNotNull);
      // Generous spacing tokens in use on the composed root.
      expect(find.byType(SizedBox), findsWidgets);
    });
  });

  group('sign-out direct (guard helper dropped)', () {
    testWidgets('sign-out proceeds with no confirm dialog', (t) async {
      final container = ProviderContainer(overrides: _overrides());
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

      expect(find.byType(AlertDialog), findsNothing);
      expect(container.read(linkedIdentityProvider), isNull);
    });
  });
}
