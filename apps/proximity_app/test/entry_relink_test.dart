// Task 1 (D1) relink tests: `relinkLinkedIdentity` restores the
// startup-preseed `linkedIdentity` on re-sign-in / role-continue.
//
// Pins the three contract points (harness per account_screen_test.dart:
// FakeAuthService + FakeCloudSync + InMemoryDeviceStore, WidgetRef captured
// from a pumped Consumer):
// (a) enrolled store + same-Gmail sign-in (mixed case, proving lowercased
//     equality) restores linked from the stored fields;
// (b) a different Gmail leaves linked null (setup flow handles it);
// (c) the student `entryContinueWithRole` path relinks BEFORE the mode
//     flip (goto) — the mode observed at the moment linked is set is still
//     unset, and the call lands on student with linked set.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/app_config/force_update.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/security/integrity.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/entry/entry_flow.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/setup/role_sections.dart';
import 'package:proximity_app/mode.dart';

/// Cloud whose binding gate never answers (stalled network worse than
/// offline: no error, just silence). Models the classroom blackhole that
/// used to leave Continue spinning with a dead button and no message.
class _HangingGateCloud extends FakeCloudSync {
  _HangingGateCloud() : super(available: true, online: true);

  @override
  Future<StudentDeviceDoc?> fetchStudentDevice(String emailLower) =>
      Completer<StudentDeviceDoc?>().future;
}

const _email = 'student@example.com';
const _installId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _pkHex =
    'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';

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

ProviderContainer _container(
    {required InMemoryDeviceStore store,
    SignedAccount? account,
    FakeCloudSync? cloud}) {
  return ProviderContainer(overrides: [
    authServiceProvider.overrideWithValue(FakeAuthService(account)),
    // Offline cloud: the student continue path skips the binding gate and
    // goes straight to stamp + goto (no network semantics in this test).
    cloudSyncProvider
        .overrideWithValue(cloud ?? FakeCloudSync(available: false)),
    deviceStoreProvider.overrideWithValue(store),
  ]);
}

/// Captures the mounted WidgetRef the entry helpers take (WidgetRef, not
/// Ref — so a bare ProviderContainer is not enough).
/// Fixed-verdict integrity probe (H3 gate tests): the register paths must
/// consult the gate instead of deciding on their own.
class _TaintedProbe implements IntegrityProbe {
  final IntegritySignals signals;
  _TaintedProbe(this.signals);
  @override
  Future<IntegritySignals> check() async => signals;
}

Future<WidgetRef> _pumpRef(WidgetTester t, ProviderContainer container) async {
  late WidgetRef ref;
  await t.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: Consumer(builder: (context, r, _) {
      ref = r;
      return const SizedBox();
    }),
  ));
  await t.pump();
  return ref;
}

void main() {
  group('entry relink (Task 1)', () {
    testWidgets('same-Gmail sign-in restores linked identity', (t) async {
      final store = await _enrolledStore();
      final container = _container(
        store: store,
        // Mixed case proves the lowercased-email equality rule.
        account: const SignedAccount(
            email: 'Student@Example.com',
            displayName: 'Test User',
            uid: 'test-uid',
            org: 'example.com'),
      );
      addTearDown(container.dispose);
      final ref = await _pumpRef(t, container);

      // Post-sign-out state: session back, linked cleared.
      expect(container.read(linkedIdentityProvider), isNull);

      final acct = await entrySignIn(ref);

      expect(acct, isNotNull);
      expect(acct!.email, 'Student@Example.com');
      final linked = container.read(linkedIdentityProvider);
      expect(linked, isNotNull);
      // Same construction as main.dart `initialLinked`: stored fields,
      // stored (lowercase) Gmail.
      expect(linked!.gmail, _email);
      expect(linked.name, 'Test User');
      expect(linked.roll, 'R1001');
      expect(linked.org, 'example.com');
    });

    testWidgets('different Gmail leaves linked null', (t) async {
      final store = await _enrolledStore();
      final container = _container(
        store: store,
        account: const SignedAccount(
            email: 'other@example.com',
            displayName: 'Other User',
            uid: 'other-uid',
            org: 'example.com'),
      );
      addTearDown(container.dispose);
      final ref = await _pumpRef(t, container);

      final acct = await entrySignIn(ref);

      expect(acct, isNotNull);
      expect(acct!.email, 'other@example.com');
      // Mismatch: state untouched (today's behavior; setup flow handles it).
      expect(container.read(linkedIdentityProvider), isNull);
    });

    testWidgets('student continue relinks before goto', (t) async {
      final store = await _enrolledStore();
      final container = _container(
        store: store,
        account: const SignedAccount(
            email: _email,
            displayName: 'Test User',
            uid: 'test-uid',
            org: 'example.com'),
      );
      addTearDown(container.dispose);
      final ref = await _pumpRef(t, container);

      // Observe the mode at the exact moment linked is set: relink-before-
      // goto means the flip to student has not happened yet.
      AppMode? modeWhenLinkedSet;
      final sub = container.listen<LinkedIdentity?>(
        linkedIdentityProvider,
        (prev, next) {
          if (prev == null && next != null) {
            modeWhenLinkedSet = container.read(appModeProvider);
          }
        },
      );
      addTearDown(sub.close);

      const acct = SignedAccount(
          email: _email,
          displayName: 'Test User',
          uid: 'test-uid',
          org: 'example.com');
      const role = <String, String>{
        'email': _email,
        'uid': 'test-uid',
        'roles': 'student',
        'lastMode': 'student',
        'displayName': '',
        'org': 'example.com',
      };
      await entryContinueWithRole(ref, () => true, acct, role, 'student');

      final linked = container.read(linkedIdentityProvider);
      expect(linked, isNotNull);
      expect(linked!.gmail, _email);
      expect(linked.name, 'Test User');
      expect(linked.roll, 'R1001');
      // Goto ran: landed on student.
      expect(container.read(appModeProvider), AppMode.student);
      // …but linked was set before that flip.
      expect(modeWhenLinkedSet, AppMode.unset);
    });

    testWidgets('stalled gate fails fast with a connection message',
        (t) async {
      // Regression for the stuck Continue: a blackholed network used to
      // leave the button disabled with no feedback (each inner call can
      // burn its full budget in turn). The overall budget surfaces one
      // honest message and never navigates.
      final store = await _enrolledStore();
      final container = _container(
        store: store,
        account: const SignedAccount(
            email: _email,
            displayName: 'Test User',
            uid: 'test-uid',
            org: 'example.com'),
        cloud: _HangingGateCloud(),
      );
      addTearDown(container.dispose);
      final ref = await _pumpRef(t, container);

      const acct = SignedAccount(
          email: _email,
          displayName: 'Test User',
          uid: 'test-uid',
          org: 'example.com');
      const role = <String, String>{
        'email': _email,
        'uid': 'test-uid',
        'roles': 'student',
        'lastMode': 'student',
        'displayName': '',
        'org': 'example.com',
      };
      // runAsync: the operation budget is a real timer, and the hanging
      // fetch never yields — awaiting both under fake async would
      // deadlock the test body itself.
      await t.runAsync(() async {
        await expectLater(
          entryContinueWithRole(ref, () => true, acct, role, 'student',
              operationTimeout: const Duration(milliseconds: 200)),
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message', contains('Taking too long'))),
        );
      });
      // Never navigated on the timeout path.
      expect(container.read(appModeProvider), AppMode.unset);
    });

    testWidgets('resume narrates the wait while busy', (t) async {
      // The disabled-button silence is what read as "no response": while
      // busy, the resume section now says what it is doing.
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: const Scaffold(
          body: RoleResumeSection(
            role: <String, String>{},
            ordered: ['student'],
            lastMode: 'student',
            busy: true,
            onContinue: _noopContinue,
          ),
        ),
      ));
      await t.pump();
      expect(find.text('Contacting server…'), findsOneWidget);
    });

  group('entry H3 gates (register paths)', () {
    const acct = SignedAccount(
        email: _email,
        displayName: 'Test User',
        uid: 'test-uid',
        org: 'example.com');

    // Hermetic §6 floor (the live checkNow has no deadline-safe answer in
    // the widget harness — unmocked platform channels never reply there).
    Future<ForceUpdateResult> freshFloor() async => const ForceUpdateResult(
          checked: true,
          updateRequired: false,
          currentVersion: '0.2.0',
          config: ForceUpdateConfig(minVersion: '0.2.0', force: true),
        );

    ProviderContainer onlineContainer({required InMemoryDeviceStore store}) {
      final c = _container(
        store: store,
        account: acct,
        cloud: FakeCloudSync(available: true, online: true),
      );
      addTearDown(c.dispose);
      return c;
    }

    testWidgets('pre-enroll gate blocks rooted register before cloud writes',
        (t) async {
      // H3 enroll path: a privileged device refuses with actionable copy
      // BEFORE the device-claim gate or any cloud write runs.
      final prev = IntegrityGate.probe;
      IntegrityGate.probe =
          _TaintedProbe(const IntegritySignals(rooted: true));
      try {
        final store = InMemoryDeviceStore();
        final container = onlineContainer(store: store);
        final ref = await _pumpRef(t, container);
        await expectLater(
          entryRegisterStudent(ref, () => true, acct,
              checkNow: freshFloor),
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message', contains('root'))),
        );
        // Refused entry writes nothing and goes nowhere.
        expect(container.read(appModeProvider), AppMode.unset);
        expect(await store.readRole(), isNull);
      } finally {
        IntegrityGate.probe = prev;
      }
    });

    testWidgets('clean device registers (gates pass through)', (t) async {
      final prev = IntegrityGate.probe;
      IntegrityGate.probe = _TaintedProbe(const IntegritySignals());
      try {
        final store = InMemoryDeviceStore();
        final container = onlineContainer(store: store);
        final ref = await _pumpRef(t, container);
        await entryRegisterStudent(ref, () => true, acct,
            checkNow: freshFloor);
        expect(container.read(appModeProvider), AppMode.student);
        expect(roleSet((await store.readRole()) ?? {}), contains('student'));
      } finally {
        IntegrityGate.probe = prev;
      }
    });

    testWidgets('pre-host gate never blocks (advisory, offline-capable)',
        (t) async {
      // Even a TAINTED verdict must not refuse professor registration —
      // hosting stays offline-capable; the finding rides the SEC log.
      final prev = IntegrityGate.probe;
      IntegrityGate.probe =
          _TaintedProbe(const IntegritySignals(hooked: true));
      try {
        final store = InMemoryDeviceStore();
        final container = onlineContainer(store: store);
        final ref = await _pumpRef(t, container);
        await entryRegisterProf(ref, () => true, acct, 'Test User',
            checkNow: freshFloor);
        expect(container.read(appModeProvider), AppMode.prof);
      } finally {
        IntegrityGate.probe = prev;
      }
    });
  });

    testWidgets('resume stays quiet when idle', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: const Scaffold(
          body: RoleResumeSection(
            role: <String, String>{},
            ordered: ['student'],
            lastMode: 'student',
            busy: false,
            onContinue: _noopContinue,
          ),
        ),
      ));
      await t.pump();
      expect(find.text('Contacting server…'), findsNothing);
      expect(find.text('Continue as Student'), findsOneWidget);
    });
  });
}

Future<void> _noopContinue(Map<String, String> role, String which) async {}
