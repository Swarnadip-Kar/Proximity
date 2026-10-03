// Atomic enrollment save: the face-rescan slot is consumed only by a fully
// saved enrollment (server claim + local persist, both landed).
//
// Regression for the field case where the server claim filed (face stamp =
// now) but the device save was cancelled at the biometric prompt — every
// retry then hit the 30-day server cooldown for a rescan that never
// completed. Order + compensation + healing:
// - presence confirms BEFORE the claim (a cancel writes nothing anywhere);
// - a local-persist failure after the claim writes the pre-claim server
//   stamp back (slot freed);
// - a same install+key retry whose server stamp runs ahead of local
//   completes the orphaned save (narrow: a fresh key ceremony is a new
//   attempt and stays gated; clear-data reinstalls with a new installId
//   stay blocked — see clear_data_face_exploit_test).
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/security/user_presence.dart';
import 'package:proximity_app/core/sync/device_hardware_id.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';

const _b = SignedAccount(email: 'b@univ.edu', displayName: 'B', uid: 'ub');
const _stills = ['c.jpg', 'l.jpg', 'r.jpg', 'u.jpg', 'd.jpg'];

/// Store that fails the next enrollment persist once with the production
/// secure-store copy, then behaves normally (proves the compensating
/// server-stamp revert + the retry that follows it).
class _FailOnceStore extends InMemoryDeviceStore {
  var failNextWrite = false;
  @override
  Future<void> writeEnrollment(StoredEnrollment e) {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError(
          'Secure storage rejected the save (storage unavailable). '
          'Tap Save again.');
    }
    return super.writeEnrollment(e);
  }
}

EnrollmentController _ctlWithCloud(
  FakeAuthService auth,
  InMemoryDeviceStore store,
  FakeCloudSync cloud,
  FakePresenceGate presence,
) =>
    EnrollmentController(
      auth: auth,
      store: store,
      verifier: FakeFaceVerifier(),
      deviceKey: FakeDeviceKey(),
      presenceGate: presence,
      livenessGate: FakeLivenessGate(),
      cloud: cloud,
    );

/// First bind + one rescan so both stamps read now: the account holds a
/// template and the quota is live.
Future<EnrollmentController> _enrolledWithRescan(
  FakeAuthService auth,
  InMemoryDeviceStore store,
  FakeCloudSync cloud,
  FakePresenceGate presence,
) async {
  final ctl = _ctlWithCloud(auth, store, cloud, presence);
  await ctl.signIn();
  ctl.setRoll('B-ROLL');
  await ctl.generateKey();
  await ctl.enrollFace(_stills);
  expect(await ctl.upload(), isNotNull);
  await ctl.restartFace();
  await ctl.enrollFace(_stills);
  expect(await ctl.upload(), isNotNull);
  return ctl;
}

Future<void> _overwriteLocalStamp(
    InMemoryDeviceStore store, int stampMillis) async {
  final cur = (await store.readEnrollment())!;
  await store.writeEnrollment(StoredEnrollment(
    email: cur.email,
    name: cur.name,
    roll: cur.roll,
    pkHex: cur.pkHex,
    sealedKeyHex: cur.sealedKeyHex,
    faceId: cur.faceId,
    enrolledAt: cur.enrolledAt,
    verifierVer: cur.verifierVer,
    org: cur.org,
    pkDHex: cur.pkDHex,
    attestationLevel: cur.attestationLevel,
    attestedAt: cur.attestedAt,
    attestedUntil: cur.attestedUntil,
    lastFaceRescanAtMillis: stampMillis,
  ));
}

/// Re-stamps only the SERVER binding (install + key preserved) — the shape
/// an orphaned claim leaves behind: server ahead, local behind.
Future<void> _overwriteServerStamp(
    FakeCloudSync cloud, String email, int stampMillis) async {
  final b = (await cloud.fetchStudentDevice(email))!;
  cloud.devices[email.toLowerCase()] = StudentDeviceDoc(
    email: b.email,
    uid: b.uid,
    pkHex: b.pkHex,
    name: b.name,
    roll: b.roll,
    modelVer: b.modelVer,
    installId: b.installId,
    platform: b.platform,
    org: b.org,
    createdAtMillis: b.createdAtMillis,
    lastMoveAtMillis: b.lastMoveAtMillis,
    lastSeenAtMillis: b.lastSeenAtMillis,
    updatedAtMillis: b.updatedAtMillis,
    moveCount: b.moveCount,
    pkDHex: b.pkDHex,
    attestationLevel: b.attestationLevel,
    attestedAtMillis: b.attestedAtMillis,
    attestedUntilMillis: b.attestedUntilMillis,
    attestationChain: List<String>.of(b.attestationChain),
    livenessVer: b.livenessVer,
    integrityFlag: b.integrityFlag,
    appAttestRawHex: b.appAttestRawHex,
    appAttestCredKeyHex: b.appAttestCredKeyHex,
    deviceId: b.deviceId,
    lastFaceRescanAtMillis: stampMillis,
  );
}

void main() {
  // Hardware id has no native side in tests (and its channel deadlines
  // freeze under FakeAsync): never touch the real reader here.
  setUp(() {
    HardwareDeviceIds.source = () async => '';
  });
  tearDown(() {
    HardwareDeviceIds.source = getStableHardwareDeviceId;
  });

  group('atomic save (cancelled prompt consumes no slot)', () {
    test('cancelled presence writes nothing anywhere; retry stays free',
        () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      final presence = FakePresenceGate();
      final ctl =
          await _enrolledWithRescan(auth, store, cloud, presence);

      // Age BOTH stamps past the window so the next rescan is allowed.
      final old = DateTime.now().toUtc().millisecondsSinceEpoch -
          kFaceRescanCooldown.inMilliseconds -
          1000;
      await _overwriteLocalStamp(store, old);
      await _overwriteServerStamp(cloud, 'b@univ.edu', old);

      await ctl.restartFace();
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);

      // Cancel at the phone prompt: no server write, no local write.
      presence.willConfirm = false;
      expect(await ctl.upload(), isNull);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      expect(ctl.state.message, contains('Save cancelled'));
      expect((await cloud.fetchStudentDevice('b@univ.edu'))!
          .lastFaceRescanAtMillis, old,
          reason: 'cancelled save must not advance the server face stamp');
      expect((await store.readEnrollment())!.lastFaceRescanAtMillis, old);

      // Approving the prompt completes the same rescan and stamps both.
      presence.willConfirm = true;
      final before = DateTime.now().toUtc().millisecondsSinceEpoch;
      expect(await ctl.upload(), isNotNull);
      final localStamp =
          (await store.readEnrollment())!.lastFaceRescanAtMillis;
      final serverStamp = (await cloud.fetchStudentDevice('b@univ.edu'))!
          .lastFaceRescanAtMillis;
      expect(localStamp >= before, isTrue);
      expect(serverStamp, localStamp);
    });

    test('local persist failure after claim frees the server slot',
        () async {
      final auth = FakeAuthService(_b);
      final store = _FailOnceStore();
      final cloud = FakeCloudSync();
      final presence = FakePresenceGate();
      final ctl =
          await _enrolledWithRescan(auth, store, cloud, presence);

      final old = DateTime.now().toUtc().millisecondsSinceEpoch -
          kFaceRescanCooldown.inMilliseconds -
          1000;
      await _overwriteLocalStamp(store, old);
      await _overwriteServerStamp(cloud, 'b@univ.edu', old);

      await ctl.restartFace();
      await ctl.enrollFace(_stills);
      store.failNextWrite = true;
      expect(await ctl.upload(), isNull);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      // The claim filed, then the revert wrote the pre-claim stamp back.
      expect((await cloud.fetchStudentDevice('b@univ.edu'))!
          .lastFaceRescanAtMillis, old,
          reason: 'failed local save must revert the server face stamp');
      expect((await store.readEnrollment())!.lastFaceRescanAtMillis, old);

      // Retry lands cleanly and converges both stamps.
      expect(await ctl.upload(), isNotNull);
      final localStamp =
          (await store.readEnrollment())!.lastFaceRescanAtMillis;
      expect(localStamp > old, isTrue);
      expect((await cloud.fetchStudentDevice('b@univ.edu'))!
          .lastFaceRescanAtMillis, localStamp);
    });
  });

  group('orphan healing (stranded server stamp)', () {
    test('same install+key retry completes the pending save', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      final presence = FakePresenceGate();
      final ctl = _ctlWithCloud(auth, store, cloud, presence);
      await ctl.signIn();
      ctl.setRoll('B-ROLL');
      await ctl.generateKey();
      await ctl.enrollFace(_stills);
      expect(await ctl.upload(), isNotNull);

      // Orphan left by the old order: server stamped now (same install +
      // same key still bound), local never landed.
      final stranded = DateTime.now().toUtc().millisecondsSinceEpoch;
      await _overwriteServerStamp(cloud, 'b@univ.edu', stranded);
      expect((await store.readEnrollment())!.lastFaceRescanAtMillis, 0);

      await ctl.restartFace();
      await ctl.enrollFace(_stills);
      expect(await ctl.upload(), isNotNull,
          reason: 'orphaned stamp is not a completed rescan — '
              'finishing the pending save must stay allowed');
      final localStamp =
          (await store.readEnrollment())!.lastFaceRescanAtMillis;
      expect(localStamp >= stranded, isTrue);
      expect((await cloud.fetchStudentDevice('b@univ.edu'))!
          .lastFaceRescanAtMillis, localStamp);
    });

    test('fresh key ceremony after the orphan stays gated', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      final presence = FakePresenceGate();
      final ctl = _ctlWithCloud(auth, store, cloud, presence);
      await ctl.signIn();
      ctl.setRoll('B-ROLL');
      await ctl.generateKey();
      await ctl.enrollFace(_stills);
      expect(await ctl.upload(), isNotNull);

      final stranded = DateTime.now().toUtc().millisecondsSinceEpoch;
      await _overwriteServerStamp(cloud, 'b@univ.edu', stranded);

      // A NEW key ceremony is a new rescan attempt, not the pending save.
      await ctl.generateKey();
      await ctl.enrollFace(_stills);
      expect(await ctl.upload(), isNull);
      expect(ctl.state.message, contains('You already updated your face scan'));
      expect((await cloud.fetchStudentDevice('b@univ.edu'))!
          .lastFaceRescanAtMillis, stranded);
    });
  });
}
