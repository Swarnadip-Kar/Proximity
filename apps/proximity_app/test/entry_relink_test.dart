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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/features/entry/entry_flow.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/mode.dart';

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

ProviderContainer _container(
    {required InMemoryDeviceStore store, SignedAccount? account}) {
  return ProviderContainer(overrides: [
    authServiceProvider.overrideWithValue(FakeAuthService(account)),
    // Offline cloud: the student continue path skips the binding gate and
    // goes straight to stamp + goto (no network semantics in this test).
    cloudSyncProvider.overrideWithValue(FakeCloudSync(available: false)),
    deviceStoreProvider.overrideWithValue(store),
  ]);
}

/// Captures the mounted WidgetRef the entry helpers take (WidgetRef, not
/// Ref — so a bare ProviderContainer is not enough).
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
  });
}
