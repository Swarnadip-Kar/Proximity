// Setup claim-denial root-cause contracts (verdict-by-evidence).
//
// Second-account-same-device enrolls used to surface raw Firestore text:
// a cross-org install-doc read denies before the claim transaction ever
// runs, so the client verdict never saw the evidence. The fix scopes the
// denial by evidence — clean own-doc read + denied install-doc read
// proves the install holds another Gmail (installConflict friendly copy
// verbatim); own-doc denied stays the deploy hint verbatim — in three
// places: the enroll pre-claim (upload), the claim transaction itself,
// and the entry register gate. No new server semantics, no new copy:
// every expected string below comes from studentClaimMessage /
// cloudRulesHint, the same sources production uses.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/features/entry/entry_flow.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';

const _b =
    SignedAccount(email: 'b@univ.edu', displayName: 'B', uid: 'ub');

const _stills = ['c.jpg', 'l.jpg', 'r.jpg', 'u.jpg', 'd.jpg'];
const _dayMs = 24 * 60 * 60 * 1000;

/// Prod-faithful denial: cross-org install reads deny with the deploy
/// hint (mirrors FirestoreCloudSync.fetchInstallEmail permission-denied).
class _DenyInstallCloud extends FakeCloudSync {
  @override
  Future<String?> fetchInstallEmail(String installId) async {
    throw StateError(cloudRulesHint('device lookup'));
  }
}

/// Genuine rules problem: even the caller's own binding is unreadable.
class _DenyOwnCloud extends FakeCloudSync {
  @override
  Future<StudentDeviceDoc?> fetchStudentDevice(String emailLower) async {
    throw StateError(cloudRulesHint('device lookup'));
  }
}

Future<EnrollmentController> _readyToSave(
    FakeAuthService auth, InMemoryDeviceStore store, FakeCloudSync cloud,
    {String installId = 'i-new'}) async {
  await store.writeInstallId(installId);
  final ctl = EnrollmentController(
    auth: auth,
    store: store,
    verifier: FakeFaceVerifier(),
    deviceKey: FakeDeviceKey(),
    cloud: cloud,
    // enrollFace measures liveness: scripted pass (liveness itself is
    // pinned in enroll_liveness_gate_test.dart).
    livenessGate: FakeLivenessGate(),
  );
  await ctl.signIn();
  ctl.setRoll('B-ROLL');
  await ctl.generateKey();
  await ctl.enrollFace(_stills);
  expect(ctl.state.phase, EnrollPhase.faceDone);
  return ctl;
}

void main() {
  group('isRulesDenialMessage (evidence check)', () {
    test('hint is denial; friendly copies and empty are not', () {
      expect(isRulesDenialMessage(cloudRulesHint('device lookup')), isTrue);
      expect(isRulesDenialMessage(cloudRulesHint('enrollment')), isTrue);
      expect(
          isRulesDenialMessage(studentClaimMessage(
              const StudentClaimResult(StudentClaim.installConflict), null)),
          isFalse);
      expect(
          isRulesDenialMessage(studentClaimMessage(
              StudentClaimResult(StudentClaim.cooldownBlocked,
                  retryAfter: DateTime.utc(2026, 10, 8)),
              null)),
          isFalse);
      expect(
          isRulesDenialMessage(
              'Student enrollment needs internet (one enrolled device per Gmail is checked online). Connect and tap Save again — your face capture is kept.'),
          isFalse);
      expect(isRulesDenialMessage(''), isFalse);
      expect(isRulesDenialMessage('Save failed: boom'), isFalse);
    });
  });

  group('upload pre-claim (verdict-by-evidence)', () {
    test('denied install read → exact installConflict copy, stores nothing',
        () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl =
          await _readyToSave(auth, store, _DenyInstallCloud());
      final id = await ctl.upload();
      expect(id, isNull);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(
          ctl.state.message,
          studentClaimMessage(
              const StudentClaimResult(StudentClaim.installConflict), null));
      expect(await store.readEnrollment(), isNull);
    });

    test('denied own read → deploy hint verbatim', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _readyToSave(auth, store, _DenyOwnCloud());
      final id = await ctl.upload();
      expect(id, isNull);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.state.message, cloudRulesHint('device lookup'));
      expect(await store.readEnrollment(), isNull);
    });

    test('known install conflict still names the incumbent', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      cloud.installs['i1'] = 'a@gmail.com';
      final ctl =
          await _readyToSave(auth, store, cloud, installId: 'i1');
      final id = await ctl.upload();
      expect(id, isNull);
      expect(
          ctl.state.message,
          studentClaimMessage(
              const StudentClaimResult(StudentClaim.installConflict,
                  installEmail: 'a@gmail.com'),
              null));
    });

    test('cooldown pre-claim carries the exact retry copy', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      cloud.devices['b@univ.edu'] = StudentDeviceDoc(
        email: 'b@univ.edu',
        uid: 'ub',
        pkHex: 'aa',
        name: 'Old',
        roll: '1',
        modelVer: 'v',
        installId: 'i-old',
        lastMoveAtMillis: now - 5 * _dayMs,
        lastSeenAtMillis: now - 5 * _dayMs,
      );
      final ctl =
          await _readyToSave(auth, store, cloud, installId: 'i-new');
      final id = await ctl.upload();
      expect(id, isNull);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.state.message, contains('another device'));
      expect(ctl.state.message, contains('re-enroll'));
      expect(await store.readEnrollment(), isNull);
    });

    test('happy first-bind path unchanged (claim wins, stored)', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _readyToSave(auth, store, FakeCloudSync());
      final id = await ctl.upload();
      expect(id, isNotNull);
      expect(id!.gmail, 'b@univ.edu');
      expect(ctl.state.phase, EnrollPhase.uploaded);
      expect((await store.readEnrollment())?.email, 'b@univ.edu');
    });

    test('raw FirebaseException never reaches the screen message', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl =
          await _readyToSave(auth, store, _DenyInstallCloud());
      await ctl.upload();
      expect(ctl.state.message, isNot(contains('FirebaseException')));
      expect(ctl.state.message, isNot(contains('permission-denied')));
      expect(ctl.state.message, isNot(contains('grpc')));
      expect(ctl.state.message, contains('already enrolled'));
    });
  });

  group('entry gate scoping', () {
    Future<WidgetRef> captureRef(WidgetTester t, InMemoryDeviceStore store,
        FakeCloudSync cloud) async {
      late WidgetRef got;
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(FakeAuthService(_b)),
          cloudSyncProvider.overrideWithValue(cloud),
          deviceStoreProvider.overrideWithValue(store),
        ],
        child: Consumer(builder: (context, ref, _) {
          got = ref;
          return const SizedBox();
        }),
      ));
      return got;
    }

    testWidgets('denied install read → installConflict verdict', (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId('i-held-by-a');
      final ref = await captureRef(t, store, _DenyInstallCloud());
      final gate = await entryStudentGate(ref, 'b@univ.edu');
      expect(gate.verdict.claim, StudentClaim.installConflict);
      expect(studentClaimMessage(gate.verdict, gate.binding),
          contains('already enrolled'));
    });

    testWidgets('denied own read still surfaces (callers stay put)', (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId('i-new');
      final ref = await captureRef(t, store, _DenyOwnCloud());
      await expectLater(
          () => entryStudentGate(ref, 'b@univ.edu'),
          throwsA(predicate((e) =>
              e is StateError && isRulesDenialMessage(e.message))));
    });

    testWidgets('clean reads keep the happy verdict', (t) async {
      final store = InMemoryDeviceStore();
      await store.writeInstallId('i-new');
      final ref = await captureRef(t, store, FakeCloudSync());
      final gate = await entryStudentGate(ref, 'b@univ.edu');
      expect(gate.verdict.claim, StudentClaim.firstBind);
    });
  });
}
