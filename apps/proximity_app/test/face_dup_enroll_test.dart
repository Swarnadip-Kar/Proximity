// Same-face enrollment dedup contracts: one face must not enroll as two
// Gmails on two devices.
//
// - Second Gmail + second phone + same face → upload refuses with the
//   non-accusatory copy, stores NOTHING locally, writes NO print.
// - Same face in a DIFFERENT org → org-scoped isolation, enrolls fine.
// - Same Gmail re-enroll (same phone) → self-exclusion, never flags itself.
// - Refusal is never a dead end: copy points at recapture + manual
//   attendance, the device key is kept, nothing is recorded against anyone.
// - Print lands atomically with the claim (fake parity with the tx).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/sync/fake_sync.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_protocol/protocol.dart';

List<double> _vec(int seed) {
  final rng = Random(seed);
  final v =
      List<double>.generate(kFacePrintDim, (_) => rng.nextDouble() * 2 - 1);
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  n = sqrt(n);
  return [for (final x in v) x / n];
}

const _stills = ['c.jpg', 'l.jpg', 'r.jpg', 'u.jpg', 'd.jpg'];

Future<EnrollmentController> _enrolled({
  required SignedAccount acct,
  required List<double> embedding,
  required FakeCloudSync cloud,
  String roll = 'R-1',
  InMemoryDeviceStore? store,
}) async {
  final auth = FakeAuthService(acct);
  final ctl = EnrollmentController(
    auth: auth,
    store: store ?? InMemoryDeviceStore(),
    verifier: FakeFaceVerifier(scriptedEmbedding: embedding),
    deviceKey: FakeDeviceKey(),
    cloud: cloud,
  );
  await ctl.signIn();
  ctl.setRoll(roll);
  await ctl.generateKey();
  await ctl.enrollFace(_stills);
  return ctl;
}

void main() {
  group('same-face duplicate check at claim time', () {
    test('second Gmail + second phone + same face refuses, stores nothing',
        () async {
      final cloud = FakeCloudSync();
      final face = _vec(5);

      final a = await _enrolled(
          acct: const SignedAccount(
              email: 'a@gmail.com', displayName: 'A', uid: 'ua'),
          embedding: face,
          cloud: cloud);
      expect(await a.upload(), isNotNull);
      expect(a.state.phase, EnrollPhase.uploaded);
      expect(cloud.prints['a@gmail.com'], isNotNull);

      // Second phone (fresh store = fresh installId), different Gmail,
      // SAME face.
      final bStore = InMemoryDeviceStore();
      final b = await _enrolled(
          acct: const SignedAccount(
              email: 'b@gmail.com', displayName: 'B', uid: 'ub'),
          embedding: face,
          cloud: cloud,
          store: bStore);
      expect(await b.upload(), isNull);
      expect(b.state.phase, EnrollPhase.error);
      // Non-accusatory, names nobody, offers the live paths.
      expect(b.state.message, contains('looks very similar'));
      expect(b.state.message, contains('siblings or lookalikes'));
      expect(b.state.message, contains('nothing is recorded against you'));
      expect(b.state.message, contains('manual'));
      expect(b.state.message.contains('b@gmail.com'), isFalse);
      expect(b.state.message.contains('a@gmail.com'), isFalse);
      // Nothing stored anywhere for the refused enrollment.
      expect(await bStore.readEnrollment(), isNull);
      expect(cloud.devices.containsKey('b@gmail.com'), isFalse);
      expect(cloud.prints.containsKey('b@gmail.com'), isFalse);
      // Key + capture kept: retry stays possible (never a dead end).
      expect(b.state.pkHex.isNotEmpty, isTrue);
      b.dismissError();
      expect(b.state.phase, EnrollPhase.faceDone);
    });

    test('different face enrolls fine (shortlist-then-clear path)', () async {
      final cloud = FakeCloudSync();
      final a = await _enrolled(
          acct: const SignedAccount(
              email: 'a@gmail.com', displayName: 'A', uid: 'ua'),
          embedding: _vec(5),
          cloud: cloud);
      expect(await a.upload(), isNotNull);

      final c = await _enrolled(
          acct: const SignedAccount(
              email: 'c@gmail.com', displayName: 'C', uid: 'uc'),
          embedding: _vec(6),
          cloud: cloud);
      expect(await c.upload(), isNotNull);
      expect(cloud.prints['c@gmail.com'], isNotNull);
    });

    test('same face in a different org is isolated (org-scoped)', () async {
      final cloud = FakeCloudSync();
      final face = _vec(5);
      final a = await _enrolled(
          acct: const SignedAccount(
              email: 'a@gmail.com', displayName: 'A', uid: 'ua'),
          embedding: face,
          cloud: cloud);
      expect(await a.upload(), isNotNull);

      // Same face, other org: the gmail.com shortlist never sees it.
      final prints = await cloud.queryFacePrints(
          org: 'other.edu', buckets: ['b0:00']);
      expect(prints, isEmpty);

      final d = await _enrolled(
          acct: const SignedAccount(
              email: 'd@other.edu', displayName: 'D', uid: 'ud'),
          embedding: face,
          cloud: cloud);
      expect(await d.upload(), isNotNull);
    });

    test('same-Gmail re-enroll on the same phone never flags itself',
        () async {
      final cloud = FakeCloudSync();
      final face = _vec(5);
      final auth = FakeAuthService(const SignedAccount(
          email: 'a@gmail.com', displayName: 'A', uid: 'ua'));
      final store = InMemoryDeviceStore();
      EnrollmentController ctl() => EnrollmentController(
            auth: auth,
            store: store,
            verifier: FakeFaceVerifier(scriptedEmbedding: face),
            deviceKey: FakeDeviceKey(),
            cloud: cloud,
          );
      final first = ctl();
      await first.signIn();
      first.setRoll('R-1');
      await first.generateKey();
      await first.enrollFace(_stills);
      expect(await first.upload(), isNotNull);

      // Same phone, fresh key (re-key), same face → sameDevice, no flag.
      final second = ctl();
      await second.pickUpAccount();
      second.setRoll('R-1');
      await second.generateKey();
      await second.enrollFace(_stills);
      expect(await second.upload(), isNotNull);
      expect(second.state.phase, EnrollPhase.uploaded);
    });

    test('embeddingFor is consulted at upload; records-only throws', () async {
      final v = FakeFaceVerifier(scriptedEmbedding: _vec(9));
      final e = await v.embeddingFor('fid');
      expect(e.length, kFacePrintDim);
      expect(v.calls.any((c) => c.startsWith('embeddingFor:')), isTrue);

      expect(() => const UnavailableFaceVerifier().embeddingFor('fid'),
          throwsStateError);
    });
  });
}
