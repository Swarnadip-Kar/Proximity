// Offline switch-account → landing (welcome) regression.
//
// Pins the app-state fix for the offline professor path (Continue-offline,
// no sign-in, prof mode set):
// 1. Tapping Switch account unsets the mode so the landing router shows
//    Welcome with a working sign-in button (previously a dead tap —
//    `entrySignOut` cleared caches but left mode=prof, stranding the UI on
//    the offline page).
// 2. No identity leak: a lingering enrollment + linked identity from
//    another Gmail is never rendered as current, before or after the tap.
// 3. Double-tap safe: rapid taps cannot double-navigate (mounted + busy
//    guard, idempotent mode write — a home switch, never a push).
// 4. Signed-in sign-out ALSO unsets the mode (one-click landing): leaving
//    mode=prof remounted the prof shell with a null account ('?' logo on
//    a dead home — desktop needed a second sign-out to reach Welcome).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/account/account_header.dart';
import 'package:proximity_app/features/account/account_screen.dart';
import 'package:proximity_app/features/entry/entry_flow.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _otherEmail = 'other@example.com';

List<Override> _offlineOverrides({
  required InMemoryDeviceStore store,
  LinkedIdentity? linked,
}) {
  return [
    // No sign-in: the Continue-offline path.
    authServiceProvider.overrideWithValue(FakeAuthService(null)),
    // Fully offline cloud: proves the switch path adds no network calls.
    cloudSyncProvider.overrideWithValue(FakeCloudSync(available: false)),
    deviceStoreProvider.overrideWithValue(store),
    faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
    deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
    if (linked != null)
      linkedIdentityProvider.overrideWith((ref) => linked),
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

/// Mode-driven host mimicking `main.dart` home: unset → Welcome (landing),
/// prof → professor shell account page. Mode flip itself is the navigation
/// (no push), so rapid taps cannot stack routes.
class _ModeHost extends ConsumerWidget {
  const _ModeHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(appModeProvider);
    return MaterialApp(
      theme: proxLightTheme(),
      home: mode == AppMode.unset
          ? const _WelcomeProbe()
          : const ProfAccountScreen(),
    );
  }
}

/// Welcome probe: the real Welcome screen carries the working sign-in
/// button; this probe keeps the assertion on the user-visible contract
/// (sign-in affordance back) without pulling the full welcome sections.
class _WelcomeProbe extends StatelessWidget {
  const _WelcomeProbe();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Sign in with Google')),
    );
  }
}

Future<void> _drain(WidgetTester t, [int steps = 8]) async {
  await t.pump();
  for (var i = 0; i < steps; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('offline switch account → landing', () {
    testWidgets('offline switch lands on welcome (mode unset)', (t) async {
      final store = InMemoryDeviceStore();
      final container = ProviderContainer(
        overrides: _offlineOverrides(store: store),
      );
      addTearDown(container.dispose);
      container.read(appModeProvider.notifier).state = AppMode.prof;

      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const _ModeHost(),
      ));
      await _drain(t);

      // Starts on the offline local page.
      expect(find.textContaining('Offline professor mode'), findsOneWidget);
      expect(find.text('Sign in with Google'), findsNothing);
      expect(find.byKey(const Key('account-sign-out')), findsOneWidget);

      await t.ensureVisible(find.byKey(const Key('account-sign-out')));
      await t.tap(find.byKey(const Key('account-sign-out')));
      await _drain(t);

      expect(container.read(appModeProvider), AppMode.unset);
      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(find.textContaining('Offline professor mode'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('no identity rendered before or after switch', (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
      await store.writeEnrollment(StoredEnrollment(
        email: _otherEmail,
        name: 'Other User',
        roll: 'R9',
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
      final container = ProviderContainer(
        overrides: _offlineOverrides(
          store: store,
          linked: const LinkedIdentity(
              name: 'Other User', gmail: _otherEmail, roll: 'R9'),
        ),
      );
      addTearDown(container.dispose);
      container.read(appModeProvider.notifier).state = AppMode.prof;

      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const _ModeHost(),
      ));
      await _drain(t);

      // Lingering enrollment + linked identity never render as current.
      expect(find.text('Other User'), findsNothing);
      expect(find.text(_otherEmail), findsNothing);
      expect(find.textContaining('Enrolled as'), findsNothing);
      expect(find.byType(AccountHeaderCard), findsNothing);

      await t.ensureVisible(find.byKey(const Key('account-sign-out')));
      await t.tap(find.byKey(const Key('account-sign-out')));
      await _drain(t);

      expect(container.read(appModeProvider), AppMode.unset);
      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(find.text('Other User'), findsNothing);
      expect(find.text(_otherEmail), findsNothing);
      expect(find.textContaining('Enrolled as'), findsNothing);
      expect(find.byType(AccountHeaderCard), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('double-tap is safe (no crash, single landing)', (t) async {
      final store = InMemoryDeviceStore();
      final container = ProviderContainer(
        overrides: _offlineOverrides(store: store),
      );
      addTearDown(container.dispose);
      container.read(appModeProvider.notifier).state = AppMode.prof;

      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const _ModeHost(),
      ));
      await _drain(t);

      await t.ensureVisible(find.byKey(const Key('account-sign-out')));
      // Rapid taps before the mode flip settles: the busy guard drops the
      // second, and the idempotent mode write cannot double-navigate.
      await t.tap(find.byKey(const Key('account-sign-out')));
      await t.pump();
      // Second tap may hit the disabled button or the landing host already;
      // either way it must never throw.
      try {
        await t.tap(find.byKey(const Key('account-sign-out')));
      } catch (_) {
        // Button already gone (landing shown) — the safe outcome.
      }
      await _drain(t);

      expect(container.read(appModeProvider), AppMode.unset);
      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('signed-in sign-out lands in one tap (mode unset)', (t) async {
      const acct = SignedAccount(
          email: 'prof@example.com',
          displayName: 'Prof User',
          uid: 'prof-uid',
          org: 'example.com');
      final store = InMemoryDeviceStore();
      final container = ProviderContainer(overrides: [
        authServiceProvider.overrideWithValue(FakeAuthService(acct)),
        cloudSyncProvider.overrideWithValue(FakeCloudSync(available: false)),
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
      ]);
      addTearDown(container.dispose);
      container.read(appModeProvider.notifier).state = AppMode.prof;

      late WidgetRef ref;
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (context, r, _) {
          ref = r;
          return const SizedBox();
        }),
      ));
      await t.pump();

      await entrySignOut(ref);

      // One-click landing: caches clear AND the mode unsets — the prof
      // shell never remounts account-less (no '?' logo on a dead home),
      // so Welcome arrives on the first tap, never the second.
      expect(container.read(appModeProvider), AppMode.unset);
      expect(container.read(linkedIdentityProvider), isNull);
    });
  });
}
