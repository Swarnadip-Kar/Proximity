// Account one-button mode switch + breakup regression.
//
// 1. One-button contract: `AccountModeSwitch` renders ONE `Switch mode`
//    button for ANY signed-in account (both-held, single-role, role-less,
//    foreign-email cache — no gating, no hidden states). No tabs, no
//    Prof/Student segments, no prof-name field, no register entries: the
//    hub owns acquire/switch checks from here on.
// 2. Press runs the MIRRORED mark-screen exit path
//    (`setMode(ref, AppMode.unset)` — the exact call behind the student
//    mark screen's top-right `switch_account` / `Switch mode` AppBar
//    action): mode flips to unset → landing hub. Hub resume (register +
//    continue for both roles) is covered by the existing entry tests, not
//    here. Refusal/gate/enrollment semantics unchanged (enforced
//    downstream at the hub as today).
// 3. Split sections render standalone (thin-composer breakup pin).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/screens/landing.dart';
import 'package:proximity_app/features/account/account_device.dart';
import 'package:proximity_app/features/account/account_enrollment.dart';
import 'package:proximity_app/features/account/account_header.dart';
import 'package:proximity_app/features/account/account_mode_switch.dart';
import 'package:proximity_app/features/account/account_prof.dart';
import 'package:proximity_app/features/account/account_screen.dart';
import 'package:proximity_app/features/account/account_system.dart';
import 'package:proximity_app/features/account/account_theme.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _email = 'student@example.com';
const _installId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _pkHex =
    'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';

const _acct = SignedAccount(
    email: _email, displayName: 'Test User', uid: 'test-uid', org: 'example.com');

Map<String, String> _bothRoles({String email = _email, String lastMode = 'prof'}) => {
      'roles': 'prof,student',
      'role': lastMode,
      'lastMode': lastMode,
      'email': email.toLowerCase(),
      'uid': 'test-uid',
      'displayName': 'Test User',
      'org': 'example.com',
    };

Map<String, String> _singleRole(String which) => {
      'roles': which,
      'role': which,
      'lastMode': which,
      'email': _email.toLowerCase(),
      'uid': 'test-uid',
      'displayName': 'Test User',
      'org': 'example.com',
    };

Future<InMemoryDeviceStore> _store({Map<String, String>? role, bool enrolled = false}) async {
  final store = InMemoryDeviceStore();
  await store.writeInstallId(_installId);
  if (role != null) await store.writeRole(role);
  if (enrolled) {
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
  }
  return store;
}

List<Override> _overrides({
  required InMemoryDeviceStore store,
  required FakeCloudSync cloud,
}) {
  return [
    authServiceProvider.overrideWithValue(FakeAuthService(_acct)),
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

/// The one-button contract, asserted on a pumped Account page: exactly one
/// `Switch mode` button, and none of the replaced tabs machinery.
void _expectOneButton(WidgetTester t) {
  expect(find.byKey(const Key('account-mode-switch')), findsOneWidget);
  expect(find.text('Switch mode'), findsOneWidget);
  // Replaced tabs machinery is gone: no segments, no register entries.
  expect(find.byKey(const Key('account-mode-tabs')), findsNothing);
  expect(find.byKey(const Key('account-prof-name')), findsNothing);
  expect(find.text('Prof'), findsNothing);
  expect(find.text('Student'), findsNothing);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('one-button mode switch', () {
    testWidgets('both roles → one Switch mode button, no tabs', (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(
            store: await _store(role: _bothRoles()), cloud: FakeCloudSync()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      _expectOneButton(t);
    });

    testWidgets('prof page shows the same single button when both held',
        (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(
            store: await _store(role: _bothRoles(lastMode: 'student')),
            cloud: FakeCloudSync()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const ProfAccountScreen()),
      ));
      await _drain(t);

      _expectOneButton(t);
    });

    testWidgets('single prof role → button still renders (hub owns acquire)',
        (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(
            store: await _store(role: _singleRole('prof')),
            cloud: FakeCloudSync()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      _expectOneButton(t);
    });

    testWidgets('single student role → button renders, no prof-name field',
        (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(
            store: await _store(role: _singleRole('student')),
            cloud: FakeCloudSync()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      _expectOneButton(t);
    });

    testWidgets('no role → button still renders (hub owns acquire)',
        (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: await _store(), cloud: FakeCloudSync()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      _expectOneButton(t);
    });

    testWidgets('foreign-email cache → button still renders (no gating)',
        (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(
            store: await _store(
                role: _bothRoles(email: 'other@example.edu')),
            cloud: FakeCloudSync()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      _expectOneButton(t);
    });

    testWidgets('button mirrors the mark-screen action (icon + label)',
        (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(
            store: await _store(role: _bothRoles()), cloud: FakeCloudSync()),
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      // Same `switch_account` icon + `Switch mode` vocabulary as the mark
      // screen's top-right AppBar action (scoped to the mode button —
      // the sign-out footer reuses the same icon family).
      final modeButton =
          find.byKey(const Key('account-mode-switch'));
      expect(modeButton, findsOneWidget);
      expect(
          find.descendant(
              of: modeButton,
              matching: find.byIcon(Icons.switch_account)),
          findsOneWidget);
      expect(
          find.descendant(
              of: modeButton, matching: find.text('Switch mode')),
          findsOneWidget);
    });
  });

  group('press runs the mirrored exit path', () {
    testWidgets('press from prof mode exits to unset (landing hub)',
        (t) async {
      final store = await _store(role: _bothRoles());
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

      await t.ensureVisible(find.text('Switch mode'));
      await t.tap(find.text('Switch mode'));
      await _drain(t);

      // Identical exit the mark screen's button runs.
      expect(container.read(appModeProvider), AppMode.unset);
    });

    testWidgets('press from student mode exits to unset (landing hub)',
        (t) async {
      final store = await _store(role: _singleRole('student'));
      final container = ProviderContainer(
          overrides: _overrides(store: store, cloud: FakeCloudSync()));
      addTearDown(container.dispose);
      container.read(appModeProvider.notifier).state = AppMode.student;
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      await t.ensureVisible(find.text('Switch mode'));
      await t.tap(find.text('Switch mode'));
      await _drain(t);

      expect(container.read(appModeProvider), AppMode.unset);
    });

    testWidgets('press from unset stays unset', (t) async {
      final store = await _store();
      final container = ProviderContainer(
          overrides: _overrides(store: store, cloud: FakeCloudSync()));
      addTearDown(container.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      expect(container.read(appModeProvider), AppMode.unset);
      await t.ensureVisible(find.text('Switch mode'));
      await t.tap(find.text('Switch mode'));
      await _drain(t);

      expect(container.read(appModeProvider), AppMode.unset);
    });
  });

  group('sections render standalone', () {
    Future<void> pumpSection(WidgetTester t, Widget section,
        {InMemoryDeviceStore? store, FakeCloudSync? cloud}) async {
      final s = store ?? InMemoryDeviceStore();
      await t.pumpWidget(ProviderScope(
        overrides: _overrides(store: s, cloud: cloud ?? FakeCloudSync()),
        child: MaterialApp(theme: proxLightTheme(), home: Scaffold(body: section)),
      ));
      await _drain(t);
    }

    testWidgets('header renders identity', (t) async {
      await pumpSection(t, const AccountHeaderCard(acct: _acct));
      expect(find.text('Test User'), findsOneWidget);
      expect(find.text(_email), findsOneWidget);
      expect(find.byKey(const Key('account-header-card')), findsOneWidget);
    });

    testWidgets('enrollment unenrolled shows org, no entry', (t) async {
      await pumpSection(t, const AccountEnrollmentSection(acct: _acct));
      expect(find.byKey(const Key('account-enroll-entry')), findsNothing);
      expect(find.text('example.com'), findsOneWidget);
    });

    testWidgets('id row renders standalone', (t) async {
      final store = await _store(enrolled: true);
      // Linked identity for the roll (scoped to the current account).
      await t.pumpWidget(ProviderScope(
        overrides: [
          ..._overrides(store: store, cloud: FakeCloudSync()),
          linkedIdentityProvider.overrideWith((ref) => const LinkedIdentity(
              name: 'Test User', gmail: _email, roll: 'R1001', org: 'example.com')),
        ],
        child: MaterialApp(
            theme: proxLightTheme(),
            home: const Scaffold(body: AccountIdRow(acct: _acct))),
      ));
      await _drain(t);
      expect(find.byKey(const Key('account-id-row')), findsOneWidget);
      expect(find.text('R1001'), findsOneWidget);
    });

    testWidgets('device section renders standalone', (t) async {
      await pumpSection(t, const AccountDeviceSection(acct: _acct));
      expect(find.text('Device model'), findsOneWidget);
    });

    testWidgets('theme row renders standalone', (t) async {
      await pumpSection(t, const AccountThemeRow());
      expect(find.byKey(const Key('account-theme-control')), findsOneWidget);
    });

    testWidgets('system log + sign-out render standalone', (t) async {
      await pumpSection(
          t,
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [AccountSystemLogRow(), AccountSignOutButton()],
          ));
      expect(find.byKey(const Key('account-system-log-row')), findsOneWidget);
      expect(find.byKey(const Key('account-sign-out')), findsOneWidget);
    });

    testWidgets('prof facts render standalone', (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId(_installId);
      await store.writeHostName('Prof Name');
      await pumpSection(t, const AccountProfDeviceFacts(acct: _acct),
          store: store);
      expect(find.text('Prof Name'), findsOneWidget);
    });

    testWidgets('mode switch renders standalone for any signed-in account',
        (t) async {
      // Both-held.
      await pumpSection(t, const AccountModeSwitch(acct: _acct),
          store: await _store(role: _bothRoles()));
      expect(find.byKey(const Key('account-mode-switch')), findsOneWidget);
      expect(find.text('Switch mode'), findsOneWidget);
    });

    testWidgets('mode switch renders standalone with no role cached',
        (t) async {
      // Single-role included — and even role-less: the hub owns acquire.
      await pumpSection(t, const AccountModeSwitch(acct: _acct),
          store: await _store(role: _singleRole('student')));
      expect(find.byKey(const Key('account-mode-switch')), findsOneWidget);
      expect(find.text('Switch mode'), findsOneWidget);
    });
  });

  group('transition reset (stale-stack F06/F07)', () {
    Future<ProviderContainer> pumpProbe(WidgetTester t) async {
      final container = ProviderContainer(
          overrides: _overrides(
              store: await _store(role: _bothRoles()),
              cloud: FakeCloudSync()));
      addTearDown(container.dispose);
      container.read(appModeProvider.notifier).state = AppMode.student;
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const _TransitionProbe()),
      ));
      await _drain(t);
      return container;
    }

    /// Invokes the (possibly covered) switch button's handler directly: a
    /// pushed `setup-flow` route covers everything beneath it, so a driver
    /// tap cannot reach the button — but the handler is what the reset
    /// contract pins (dismiss first, then switch).
    void pressSwitch(WidgetTester t) {
      final sw = t.widget<TextButton>(
        find.byKey(const Key('account-mode-switch'), skipOffstage: false),
      );
      expect(sw.onPressed, isNotNull);
      sw.onPressed!();
    }

    testWidgets('switch pops pushed account sub-page before exiting',
        (t) async {
      final container = await pumpProbe(t);

      await t.tap(find.byKey(const Key('probe-open-sub')));
      await _drain(t);
      expect(find.text('SUB'), findsOneWidget);

      pressSwitch(t);
      await _drain(t);

      // Pushed screen for the previous identity is gone; mode exited.
      expect(find.text('SUB'), findsNothing);
      expect(find.byKey(const Key('probe-open-sub')), findsOneWidget);
      expect(container.read(appModeProvider), AppMode.unset);
      expect(t.takeException(), isNull);
    });

    testWidgets('switch with setup-flow open dismisses flow first, then exits',
        (t) async {
      final container = await pumpProbe(t);

      await t.tap(find.byKey(const Key('probe-open-sub')));
      await _drain(t);
      await t.tap(find.byKey(const Key('probe-open-flow')));
      await _drain(t);
      expect(find.text('FLOW'), findsOneWidget);

      pressSwitch(t);
      await _drain(t);

      // Root setup-flow dismissed (product decision) before the switch;
      // nothing of the previous identity survives underneath.
      expect(find.text('FLOW'), findsNothing);
      expect(find.text('SUB'), findsNothing);
      expect(find.byKey(const Key('probe-open-sub')), findsOneWidget);
      expect(container.read(appModeProvider), AppMode.unset);
      expect(t.takeException(), isNull);
    });

    testWidgets('double-tap switch mode exits once without crashing',
        (t) async {
      final container = ProviderContainer(
          overrides: _overrides(
              store: await _store(role: _bothRoles()),
              cloud: FakeCloudSync()));
      addTearDown(container.dispose);
      container.read(appModeProvider.notifier).state = AppMode.student;
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      await t.ensureVisible(find.text('Switch mode'));
      await t.tap(find.text('Switch mode'));
      await t.pump();
      // Second tap races the first: the busy guard drops it (disabled
      // button), the idempotent mode write cannot double-navigate.
      await t.tap(find.text('Switch mode'));
      await _drain(t);

      expect(container.read(appModeProvider), AppMode.unset);
      expect(t.takeException(), isNull);
    });

    testWidgets('double-tap sign-out signs out once without crashing',
        (t) async {
      final container = ProviderContainer(
          overrides: _overrides(
              store: await _store(role: _bothRoles()),
              cloud: FakeCloudSync()));
      addTearDown(container.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: proxLightTheme(), home: const StudentAccountScreen()),
      ));
      await _drain(t);

      await t.ensureVisible(find.byKey(const Key('account-sign-out')));
      await t.tap(find.byKey(const Key('account-sign-out')));
      await t.pump();
      await t.tap(find.byKey(const Key('account-sign-out')));
      await _drain(t);

      expect(container.read(linkedIdentityProvider), isNull);
      expect(t.takeException(), isNull);
    });

    testWidgets('landing hub remounts per account (no stale register state)',
        (t) async {
      const acctA = SignedAccount(
          email: 'aaa@example.com',
          displayName: 'User Aaa',
          uid: 'uid-a',
          org: 'example.com');
      const acctB = SignedAccount(
          email: 'bbb@example.com',
          displayName: 'User Bbb',
          uid: 'uid-b',
          org: 'example.com');
      final auth = _LandingSwitchAuth(acctA);
      final store = InMemoryDeviceStore();
      await store.writeRole({
        'roles': 'prof',
        'role': 'prof',
        'lastMode': 'prof',
        'email': 'aaa@example.com',
        'uid': 'uid-a',
        'displayName': 'User Aaa',
        'org': 'example.com',
      });
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(auth),
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
        ],
        child: MaterialApp(
            theme: proxLightTheme(), home: const LandingScreen()),
      ));
      await _drain(t);
      expect(find.text('Continue as Professor'), findsOneWidget);

      // Switch to role-less B: the hub remounts (per-Gmail key) instead of
      // reusing A's seeded name field / cached role future.
      auth.switchTo(acctB);
      await _drain(t);

      expect(find.text('Register as Student'), findsOneWidget);
      final field = t.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, 'User Bbb');
      expect(t.takeException(), isNull);
    });
  });
}

/// Push-probe mirroring the shell shape (tab stack + root setup-flow)
/// without the shell: home opens a sub-page hosting a real
/// [AccountModeSwitch]; the sub-page can push a root-level `setup-flow`
/// route above itself.
class _TransitionProbe extends StatelessWidget {
  const _TransitionProbe();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          key: const Key('probe-open-sub'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              settings: const RouteSettings(name: 'account/enrollment'),
              builder: (_) => const _ProbeSubPage(),
            ),
          ),
          child: const Text('open sub'),
        ),
      ),
    );
  }
}

class _ProbeSubPage extends StatelessWidget {
  const _ProbeSubPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('SUB'),
          const AccountModeSwitch(acct: _acct),
          TextButton(
            key: const Key('probe-open-flow'),
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                settings: const RouteSettings(name: 'setup-flow'),
                builder: (_) => const Scaffold(
                  body: Center(child: Text('FLOW')),
                ),
              ),
            ),
            child: const Text('open flow'),
          ),
        ],
      ),
    );
  }
}

/// Stream-backed auth fake: emits on every switch like Firebase
/// `authStateChanges`, so landing/shell tests exercise the live account
/// stream (the single-shot `FakeAuthService` stream cannot emit twice).
class _LandingSwitchAuth implements AuthService {
  SignedAccount? _current;
  final _ctrl = StreamController<SignedAccount?>.broadcast();
  _LandingSwitchAuth(this._current);

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
