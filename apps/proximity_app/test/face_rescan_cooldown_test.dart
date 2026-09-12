// 30-day face rescan rule: one SAVED face-template replacement per
// account every 30 days (product-owner rule).
//
// - New constant kFaceRescanCooldown (30d, SEPARATE from kStudentMoveCooldown).
// - StoredEnrollment.lastFaceRescanAtMillis (0 = never rescanned → allowed).
// - Enforcement on the rescan-SAVE path only (upload replacing an existing
//   template); first enrollment never gated; started-but-unsaved rescans
//   never stamp; failed saves never stamp.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';

const _b = SignedAccount(email: 'b@univ.edu', displayName: 'B', uid: 'ub');
const _stills = ['c.jpg', 'l.jpg', 'r.jpg', 'u.jpg', 'd.jpg'];

EnrollmentController _ctl(FakeAuthService auth, InMemoryDeviceStore store) =>
    EnrollmentController(
      auth: auth,
      store: store,
      verifier: FakeFaceVerifier(),
      deviceKey: FakeDeviceKey(),
      // enrollFace measures liveness: scripted pass (liveness itself is
      // pinned in enroll_liveness_gate_test.dart).
      livenessGate: FakeLivenessGate(),
    );

Future<EnrollmentController> _signedInWithKey(
    FakeAuthService auth, InMemoryDeviceStore store, String roll) async {
  final ctl = _ctl(auth, store);
  await ctl.signIn();
  ctl.setRoll(roll);
  await ctl.generateKey();
  return ctl;
}

Future<StoredEnrollment> _firstEnroll(
    FakeAuthService auth, InMemoryDeviceStore store) async {
  final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
  await ctl.enrollFace(_stills);
  expect(ctl.state.phase, EnrollPhase.faceDone);
  final id = await ctl.upload();
  expect(id, isNotNull);
  final stored = (await store.readEnrollment())!;
  return stored;
}

Future<void> _overwriteStamp(
    InMemoryDeviceStore store, int stampMillis) async {
  final cur = (await store.readEnrollment())!;
  await store.writeEnrollment(StoredEnrollment(
    email: cur.email,
    name: cur.name,
    roll: cur.roll,
    seedHex: cur.seedHex,
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

void main() {
  group('kFaceRescanCooldown constant', () {
    test('is 30 days, same duration but a separate rule', () {
      expect(kFaceRescanCooldown, const Duration(days: 30));
      expect(kFaceRescanCooldown, kStudentMoveCooldown);
      // Separate rule by declaration (not an alias): kFaceRescanCooldown is
      // declared on its own line beside kStudentMoveCooldown so changing one
      // can never change the other. (No identical() pin: const Duration(30d)
      // canonicalizes, so identical() is true despite separate declarations.)
      expect(kFaceRescanCooldown.inDays, 30);
      expect(kStudentMoveCooldown.inDays, 30);
    });

    test('pure helpers derive from the constant (boundary)', () {
      final now = DateTime.utc(2026, 9, 8);
      final coolMs = kFaceRescanCooldown.inMilliseconds;
      final nowMs = now.millisecondsSinceEpoch;
      expect(
          faceRescanBlocked(stampMillis: 0, now: now), isFalse);
      expect(
          faceRescanBlocked(
              stampMillis: nowMs - (coolMs - 1000), now: now),
          isTrue);
      expect(
          faceRescanBlocked(
              stampMillis: nowMs - (coolMs + 1000), now: now),
          isFalse);
      // Exact boundary is exclusive (elapsed == cooldown → allowed).
      expect(
          faceRescanBlocked(stampMillis: nowMs - coolMs, now: now),
          isFalse);
      expect(faceRescanEligibleAt(nowMs - coolMs), now);
    });
  });

  group('StoredEnrollment schema (additive)', () {
    test('round-trips the stamp; missing key defaults to 0', () async {
      final e = StoredEnrollment(
        email: 'a@x.in',
        name: 'A',
        roll: '1',
        seedHex: 'ab' * 32,
        pkHex: 'cd' * 32,
        faceId: 'f',
        enrolledAt: DateTime.utc(2026, 1, 1),
        verifierVer: 'v',
        lastFaceRescanAtMillis: 123456789,
      );
      final back = StoredEnrollment.fromJson(e.toJson());
      expect(back.lastFaceRescanAtMillis, 123456789);
      expect(back.lastFaceRescanAt,
          DateTime.fromMillisecondsSinceEpoch(123456789, isUtc: true));

      final legacy = StoredEnrollment.fromJson({
        'email': 'a@x.in',
        'name': 'A',
        'roll': '1',
        'seedHex': 'ab' * 32,
        'pkHex': 'cd' * 32,
        'faceId': 'f',
        'enrolledAt': '2026-01-01T00:00:00.000Z',
        'verifierVer': 'v',
      });
      expect(legacy.lastFaceRescanAtMillis, 0);

      final store = InMemoryDeviceStore();
      await store.writeEnrollment(e);
      expect((await store.readEnrollment())!.lastFaceRescanAtMillis,
          123456789);
    });
  });

  group('upload rescan gate (SAVE path only)', () {
    test('first enrollment unaffected and leaves zero stamp', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final stored = await _firstEnroll(auth, store);
      expect(stored.email, 'b@univ.edu');
      expect(stored.faceId.isNotEmpty, isTrue);
      expect(stored.lastFaceRescanAtMillis, 0);
    });

    test('successful rescan stamps now', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
      await ctl.enrollFace(_stills);
      expect(await ctl.upload(), isNotNull);
      expect((await store.readEnrollment())!.lastFaceRescanAtMillis, 0);

      // First rescan (zero stamp → allowed once), then stamps.
      await ctl.restartFace();
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      final before = DateTime.now().toUtc().millisecondsSinceEpoch;
      expect(await ctl.upload(), isNotNull);
      final after = DateTime.now().toUtc().millisecondsSinceEpoch;
      final stamp =
          (await store.readEnrollment())!.lastFaceRescanAtMillis;
      expect(stamp >= before && stamp <= after, isTrue,
          reason: 'rescan save stamps now ($stamp not in [$before,$after])');
    });

    test('within-window rescan refused with EXACT eligible date', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
      await ctl.enrollFace(_stills);
      expect(await ctl.upload(), isNotNull);

      // Simulate a recent rescan: 5 days ago (well inside the window).
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final recent = nowMs - 5 * 24 * 60 * 60 * 1000;
      await _overwriteStamp(store, recent);
      final eligible = faceRescanEligibleAt(recent);
      final eligibleIso = displayDateOf(eligible);

      await ctl.restartFace();
      // Started-but-unsaved rescan never stamps the quota.
      expect((await store.readEnrollment())!.lastFaceRescanAtMillis,
          recent);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);

      final id = await ctl.upload();
      expect(id, isNull);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.state.message, faceRescanCooldownMessage(eligible));
      expect(ctl.state.message, contains(eligibleIso));
      expect(ctl.state.message, contains('once every 30 days'));
      expect(ctl.state.message, contains('manual attendance'));
      expect(ctl.state.message, contains('Request manual attendance'));
      // Refused save changes nothing on disk.
      final kept = (await store.readEnrollment())!;
      expect(kept.lastFaceRescanAtMillis, recent);
      expect(kept.faceId.isNotEmpty, isTrue);

      // UI accessor exposes the same eligible date (account follow-up).
      expect(await ctl.faceRescanBlockedUntil(), eligible);
    });

    test('post-window rescan allowed and re-stamps', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
      await ctl.enrollFace(_stills);
      expect(await ctl.upload(), isNotNull);

      final old = DateTime.now().toUtc().millisecondsSinceEpoch -
          kFaceRescanCooldown.inMilliseconds -
          1000;
      await _overwriteStamp(store, old);
      expect(await ctl.faceRescanBlockedUntil(), isNull);

      await ctl.restartFace();
      await ctl.enrollFace(_stills);
      final before = DateTime.now().toUtc().millisecondsSinceEpoch;
      expect(await ctl.upload(), isNotNull);
      final stamp =
          (await store.readEnrollment())!.lastFaceRescanAtMillis;
      expect(stamp >= before, isTrue);
      expect(stamp > old, isTrue);
      expect(await ctl.faceRescanBlockedUntil(), isNotNull);
    });

    test('failed save does not stamp', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
      await ctl.enrollFace(_stills);
      expect(await ctl.upload(), isNotNull);
      expect((await store.readEnrollment())!.lastFaceRescanAtMillis, 0);
      final faceBefore = (await store.readEnrollment())!.faceId;

      // Validation failure (no fresh capture): Save stays blocked, disk kept.
      await ctl.restartFace();
      ctl.setRoll('B-ROLL');
      final noFace = await ctl.upload();
      expect(noFace, isNull);
      expect((await store.readEnrollment())!.lastFaceRescanAtMillis, 0);
      expect((await store.readEnrollment())!.faceId, faceBefore);

      // Roll failure: capture validates but the ID gate refuses first.
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      ctl.setRoll('');
      // Clear the restored-roll fallback path too by using a fresh draft
      // without any stored roll? The stored roll exists, so emulate a truly
      // empty ID by wiping both: fresh controller with no roll.
      final auth2 = FakeAuthService(_b);
      final store2 = InMemoryDeviceStore();
      final ctl2 = _ctl(auth2, store2);
      await ctl2.signIn();
      await ctl2.generateKey();
      await ctl2.enrollFace(_stills);
      expect(await ctl2.upload(), isNull);
      expect(ctl2.state.message, contains('ID number'));
      expect(await store2.readEnrollment(), isNull);
    });

    test('pre-upgrade zero-stamp allowed once, then stamps', () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      await _firstEnroll(auth, store);
      // Pre-upgrade doc: template present, no stamp key (defaults to 0).
      final cur = (await store.readEnrollment())!;
      expect(cur.lastFaceRescanAtMillis, 0);

      final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
      // Fresh draft for the same account: restore path is not used here;
      // drive a rescan save against the zero-stamp doc.
      await ctl.enrollFace(_stills);
      expect(await ctl.upload(), isNotNull);
      expect((await store.readEnrollment())!.lastFaceRescanAtMillis > 0,
          isTrue);
    });

    test('different account never gated by another Gmail stamp', () async {
      final authB = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      await _firstEnroll(authB, store);
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      await _overwriteStamp(store, nowMs - 1000);

      const a = SignedAccount(email: 'a@gmail.com', displayName: 'A', uid: 'ua');
      final authA = FakeAuthService(a);
      final ctlA = _ctl(authA, store);
      await ctlA.signIn();
      ctlA.setRoll('A-ROLL');
      await ctlA.generateKey();
      await ctlA.enrollFace(_stills);
      // Same install, different Gmail: first enrollment for A, allowed.
      expect(await ctlA.upload(), isNotNull);
      expect((await store.readEnrollment())!.email, 'a@gmail.com');
      expect((await store.readEnrollment())!.lastFaceRescanAtMillis, 0);
    });
  });
}
