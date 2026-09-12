// sec-liveness (2B): checkFace liveness gating + extended-ticket proving.
//
// - Liveness runs BEFORE the matcher (spoof never reaches verify).
// - Below-threshold liveness → mismatch (burns one attempt, never marks).
// - Liveness throw/unreadable → inconclusive (rescan, burns nothing).
// - Pass carries (livenessScore, livenessVer) into the Sig_s ticket; the
//   full listenAndProve below resolves it from the checkFace cache (no UI
//   change) and marks against a real ProxServer — driver ticket == server
//   ticket, or the proof fails bad-sig (migration: requireLiveness false).
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';

const _email = 's@x.in';

Future<InMemoryDeviceStore> _enrolledStore() async {
  final s = InMemoryDeviceStore();
  await s.writeEnrollment(StoredEnrollment(
    email: _email,
    name: 'S',
    roll: '1',
    seedHex: 'ab' * 32,
    pkHex: 'cd' * 32,
    faceId: 'face-test-id',
    enrolledAt: DateTime.now().toUtc(),
    verifierVer: kFaceVerifierVer,
  ));
  return s;
}

RealStudentDriver _driver({
  required InMemoryDeviceStore store,
  FakeFaceVerifier? verifier,
  FakeLivenessGate? liveness,
  required ProxBleEngine engine,
}) =>
    RealStudentDriver(
      store: store,
      verifier: verifier ?? FakeFaceVerifier(match: true, score: 0.85),
      deviceKey: FakeDeviceKey(),
      engine: engine,
      livenessGate: liveness ?? FakeLivenessGate(),
    );

void main() {
  group('checkFace liveness gate (before verify)', () {
    test('pass carries the liveness ticket (score + ver + stamp)', () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.85);
      final live = FakeLivenessGate(score: 0.92);
      final d = _driver(
          store: await _enrolledStore(),
          verifier: verifier,
          liveness: live,
          engine: ProxBleEngine(radio: FakeBleRadio()));
      final res = await d.checkFace('still.jpg');
      expect(res.match, FaceMatch.pass);
      expect(res.score, 0.85);
      expect(res.faceValidAtMs, greaterThan(0));
      expect(res.verifierVer, kFaceVerifierVer);
      // The §4 ticket: real gated score + pipeline tag (never hardcoded).
      expect(res.livenessScore, 0.92);
      expect(res.livenessVer, kLivenessVer);
      expect(res.livenessVer.startsWith('liveness/'), isTrue);
      // Ordering: liveness ran, then the matcher ran.
      expect(live.calls, ['still.jpg']);
      expect(verifier.calls, contains('verify:face-test-id'));
    });

    test('spoof (low liveness, matching face) fails as mismatch', () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.85);
      final live = FakeLivenessGate(score: 0.31);
      final d = _driver(
          store: await _enrolledStore(),
          verifier: verifier,
          liveness: live,
          engine: ProxBleEngine(radio: FakeBleRadio()));
      final res = await d.checkFace('photo-of-enrolled.jpg');
      // Readable spoof: consumes one attempt like matching somebody else.
      expect(res.match, FaceMatch.mismatch);
      expect(res.score, 0);
      expect(res.faceValidAtMs, 0);
      expect(res.verifierVer, isEmpty);
      expect(res.livenessScore, 0);
      expect(res.livenessVer, isEmpty);
      // The matcher NEVER ran: liveness gates first (fail-closed).
      expect(
          verifier.calls.where((c) => c.startsWith('verify:')), isEmpty);
      expect(live.calls, ['photo-of-enrolled.jpg']);
    });

    test('liveness throw degrades to inconclusive (rescan, no burn)',
        () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.85);
      final live = FakeLivenessGate(throwOnDetect: true);
      final d = _driver(
          store: await _enrolledStore(),
          verifier: verifier,
          liveness: live,
          engine: ProxBleEngine(radio: FakeBleRadio()));
      final res = await d.checkFace('still.jpg');
      expect(res.match, FaceMatch.inconclusive);
      expect(
          verifier.calls.where((c) => c.startsWith('verify:')), isEmpty);
    });

    test('threshold boundary: exactly Tl passes, just below fails',
        () async {
      for (final s in [kLivenessThreshold, kLivenessThreshold - 0.001]) {
        final d = _driver(
            store: await _enrolledStore(),
            liveness: FakeLivenessGate(score: s),
            engine: ProxBleEngine(radio: FakeBleRadio()));
        final res = await d.checkFace('still.jpg');
        expect(res.match,
            s >= kLivenessThreshold ? FaceMatch.pass : FaceMatch.mismatch,
            reason: 'liveness=$s vs Tl=$kLivenessThreshold');
      }
    });
  });

  group('extended ticket prove (driver == server preimage)', () {
    test('checkFace cache threads liveness into Sig_s; marks',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      final prof = ProxCrypto.generateEdKeypair();
      final seed = randBytes(32);
      final stuPk = ed.public(ed.newKeyFromSeed(seed));
      final store = InMemoryDeviceStore();
      // Sealed-only enrollment (security §2, sec-hwkey): the envelope is
      // sealed with a throwaway FakeDeviceKey so the driver-held fake
      // unseals it — same pattern as student_driver_test.enrolledStore.
      await store.writeEnrollment(StoredEnrollment(
        email: _email,
        name: 'S',
        roll: '1',
        seedHex: '',
        sealedKeyHex: hexEncode(await FakeDeviceKey().seal(seed)),
        pkHex: hexEncode(stuPk.bytes),
        faceId: 'face-test-id',
        enrolledAt: DateTime.now().toUtc(),
        verifierVer: kFaceVerifierVer,
      ));
      final server = ProxServer(
        classLabel: 't',
        profSk: prof.privateKey,
        profPk: prof.publicKey,
        sightings: (
                {required peerW,
                required expectedAirKey,
                required expectedUuid}) =>
            const RadioSighting(rssiDbm: -55, hop: 0),
      );
      await server.start(port: 0);
      try {
        server.openWindow(
          WindowParams(
            sessionId: randBytes(16),
            windowId: randBytes(6),
            secret: randBytes(32),
            t0: DateTime.now().toUtc(),
            classLabel: 't',
          ),
          1,
        );
        final engine = ProxBleEngine(radio: FakeBleRadio());
        final d = _driver(store: store, engine: engine)
          ..silenceCap = const Duration(seconds: 10);
        // Holder check first (stamps the face + liveness ticket caches).
        final check = await d.checkFace('still.jpg');
        expect(check.match, FaceMatch.pass);
        expect(check.livenessScore, 0.92);
        Future.delayed(const Duration(milliseconds: 300), () {
          final w = server.window!;
          engine.handleSighting(BleSighting(
            type: kAirTypeChallenge,
            token8: w.challengeFor(w.jForTime(DateTime.now().toUtc())),
            ipHost: '127.0.0.1',
            ipPort: server.port,
            rssiDbm: -60,
            at: DateTime.now().toUtc(),
          ));
        });
        // The face screen's call shape (no explicit liveness args): the
        // cache resolves them by stamp equality. A ticket mismatch on
        // either side fails bad-sig — marked proves driver == server.
        final res = await d.listenAndProve(
          target: ClassBeacon(
              classLabel: 't',
              host: '127.0.0.1',
              port: server.port,
              rssiDbm: 0,
              displayCode: 'X'),
          identity:
              const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
          faceScore: check.score,
          faceValidAtMs: check.faceValidAtMs,
          verifierVer: check.verifierVer,
          onStatus: (_) {},
        );
        expect(res.result, StudentResult.marked,
            reason: 'detail=${res.detail} flags=${res.attestationFlags}');
        expect(server.tally.presentCount, 1);
      } finally {
        await server.stop();
      }
    });

    test('extended ticket binds liveness (protocol golden sanity)', () {
      // The driver and server both derive this preimage; pin that the
      // liveness fields actually move the ticket (transplant-proof) and
      // that the driver's default FakeLivenessGate tag verifies.
      final a = ProxCrypto.faceTicketHash(
          faceScore: 0.85,
          faceValidAtMs: 1725628800000,
          verifierVer: kFaceVerifierVer,
          livenessScore: 0.92,
          livenessVer: kLivenessVer);
      final b = ProxCrypto.faceTicketHash(
          faceScore: 0.85,
          faceValidAtMs: 1725628800000,
          verifierVer: kFaceVerifierVer,
          livenessScore: 0.31,
          livenessVer: kLivenessVer);
      final c = ProxCrypto.faceTicketHash(
          faceScore: 0.85,
          faceValidAtMs: 1725628800000,
          verifierVer: kFaceVerifierVer);
      expect(hexEncode(a), isNot(hexEncode(b)));
      expect(hexEncode(a), isNot(hexEncode(c)));
      expect(a, hasLength(8));
    });
  });
}
