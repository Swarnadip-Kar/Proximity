// sec-liveness (2B): checkFace liveness gating + extended-ticket proving.
//
// - Liveness runs BEFORE the matcher (spoof never reaches verify).
// - Below-threshold liveness → mismatch (burns one attempt, never marks),
//   except the near-miss band just under Tl → inconclusive (free rescan).
// - Liveness throw/unreadable → inconclusive (rescan, burns nothing).
// - checkFaceAny bursts score every still and decides on the MAX.
// - Pass carries (livenessScore, livenessVer) into the Sig_s ticket; the
//   full listenAndProve below resolves it from the checkFace cache (no UI
//   change) and marks against a real ProxServer — driver ticket == server
//   ticket, or the proof fails bad-sig (liveness always enforced).
import 'dart:typed_data';

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

import 'test_device.dart';

const _email = 's@x.in';

Future<InMemoryDeviceStore> _enrolledStore() async {
  final s = InMemoryDeviceStore();
  await s.writeEnrollment(StoredEnrollment(
    email: _email,
    name: 'S',
    roll: '1',
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
  LivenessGate? liveness,
  required ProxBleEngine engine,
}) =>
    RealStudentDriver(
      store: store,
      verifier: verifier ?? FakeFaceVerifier(match: true, score: 0.85),
      deviceKey: FakeDeviceKey(),
      engine: engine,
      livenessGate: liveness ?? FakeLivenessGate(),
    );

/// Per-path scripted vitality for burst tests: [scores] maps a still path
/// to its live-prob; a null value (or unknown path) throws like an
/// unreadable still.
class _PathLivenessGate implements LivenessGate {
  final Map<String, double?> scores;
  final List<String> calls = [];
  _PathLivenessGate(this.scores);

  @override
  Future<LivenessResult> detectPassive(String imagePath) async {
    calls.add(imagePath);
    final s = scores[imagePath];
    if (s == null) throw StateError('unreadable still: $imagePath');
    return LivenessResult(score: s, ver: kLivenessVer);
  }
}

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

    test('threshold mapping: Tl passes, near-miss rescans, low burns',
        () async {
      final cases = {
        kLivenessThreshold: FaceMatch.pass,
        // 0.001 under Tl sits inside the near-miss band → free rescan.
        kLivenessThreshold - 0.001: FaceMatch.inconclusive,
        kLivenessThreshold - kLivenessNearMissBand: FaceMatch.inconclusive,
        // Below the band is readable-spoof territory → burns an attempt.
        kLivenessThreshold - kLivenessNearMissBand - 0.001:
            FaceMatch.mismatch,
        0.31: FaceMatch.mismatch,
      };
      for (final entry in cases.entries) {
        final d = _driver(
            store: await _enrolledStore(),
            liveness: FakeLivenessGate(score: entry.key),
            engine: ProxBleEngine(radio: FakeBleRadio()));
        final res = await d.checkFace('still.jpg');
        expect(res.match, entry.value,
            reason:
                'liveness=${entry.key} vs Tl=$kLivenessThreshold band=$kLivenessNearMissBand');
      }
    });

    test('near-miss never stamps the gates (no sign, no ticket)', () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.85);
      final live = FakeLivenessGate(score: kLivenessThreshold - 0.01);
      final d = _driver(
          store: await _enrolledStore(),
          verifier: verifier,
          liveness: live,
          engine: ProxBleEngine(radio: FakeBleRadio()));
      final res = await d.checkFace('still.jpg');
      expect(res.match, FaceMatch.inconclusive);
      expect(res.faceValidAtMs, 0);
      expect(res.livenessScore, 0);
      expect(res.livenessVer, isEmpty);
      expect(
          verifier.calls.where((c) => c.startsWith('verify:')), isEmpty);
    });
  });

  group('checkFaceAny best-of burst (max vitality decides)', () {
    test('one dip + one pass → pass on the winning still', () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.85);
      final live = _PathLivenessGate({'a.jpg': 0.80, 'b.jpg': 0.92});
      final d = _driver(
          store: await _enrolledStore(),
          verifier: verifier,
          liveness: live,
          engine: ProxBleEngine(radio: FakeBleRadio()));
      final res = await d.checkFaceAny(['a.jpg', 'b.jpg']);
      expect(res.match, FaceMatch.pass);
      expect(res.livenessScore, 0.92);
      expect(live.calls, ['a.jpg', 'b.jpg']);
      // The matcher ran ONCE, on the winning still — via checkFaceAny the
      // verify path carries the burst winner (FakeFaceVerifier records
      // verify calls; the gate calls above pin both stills were scored).
      expect(verifier.calls, contains('verify:face-test-id'));
    });

    test('all stills low → mismatch, matcher never ran', () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.85);
      final live = _PathLivenessGate({'a.jpg': 0.31, 'b.jpg': 0.20});
      final d = _driver(
          store: await _enrolledStore(),
          verifier: verifier,
          liveness: live,
          engine: ProxBleEngine(radio: FakeBleRadio()));
      final res = await d.checkFaceAny(['a.jpg', 'b.jpg']);
      expect(res.match, FaceMatch.mismatch);
      expect(
          verifier.calls.where((c) => c.startsWith('verify:')), isEmpty);
    });

    test('max inside the near-miss band → inconclusive, no burn',
        () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.85);
      final live = _PathLivenessGate({'a.jpg': 0.80, 'b.jpg': 0.79});
      final d = _driver(
          store: await _enrolledStore(),
          verifier: verifier,
          liveness: live,
          engine: ProxBleEngine(radio: FakeBleRadio()));
      final res = await d.checkFaceAny(['a.jpg', 'b.jpg']);
      expect(res.match, FaceMatch.inconclusive);
      expect(
          verifier.calls.where((c) => c.startsWith('verify:')), isEmpty);
    });

    test('throw on one still + pass on the other → pass', () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.85);
      final live = _PathLivenessGate({'a.jpg': null, 'b.jpg': 0.93});
      final d = _driver(
          store: await _enrolledStore(),
          verifier: verifier,
          liveness: live,
          engine: ProxBleEngine(radio: FakeBleRadio()));
      final res = await d.checkFaceAny(['a.jpg', 'b.jpg']);
      expect(res.match, FaceMatch.pass);
      expect(res.livenessScore, 0.93);
    });

    test('empty burst and all-blank burst → inconclusive, nothing ran',
        () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.85);
      final live = _PathLivenessGate({'a.jpg': 0.95});
      final d = _driver(
          store: await _enrolledStore(),
          verifier: verifier,
          liveness: live,
          engine: ProxBleEngine(radio: FakeBleRadio()));
      expect((await d.checkFaceAny([])).match, FaceMatch.inconclusive);
      expect((await d.checkFaceAny(['  '])).match, FaceMatch.inconclusive);
      expect(live.calls, isEmpty);
      expect(
          verifier.calls.where((c) => c.startsWith('verify:')), isEmpty);
    });
  });

  group('extended ticket prove (driver == server preimage)', () {
    test('checkFace cache threads liveness into Sig_s; marks',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      // Fresh FULL proof (HW test device + checkFace ticket + liveness).
      final prof = ProxCrypto.generateEdKeypair();
      final seed = randBytes(32);
      final hw = await freshHwDevice(email: _email, seedBytes: seed, salt: 81);
      final store = await hwEnrolledStore(email: _email, hw: hw);
      final server = ProxServer(
        classLabel: 't',
        profSk: prof.privateKey,
        profPk: prof.publicKey,
        sightings: (
                {required peerW,
                required expectedAirKey,
                required expectedUuid}) =>
            const RadioSighting(rssiDbm: -55, hop: 0),
        pinnedRoots: hw.pins,
        // ignore: cascade_invocations
      )..testChainGate = testChainGate;
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
        final d = RealStudentDriver(
          store: store,
          verifier: FakeFaceVerifier(match: true, score: 0.85),
          deviceKey: hw.deviceKey,
          engine: engine,
          livenessGate: FakeLivenessGate(),
        )..silenceCap = const Duration(seconds: 10);
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
          // Clean verdict wire form (explicit → no native probe in tests).
          integrityFlag: '',
          integrityHash: '00000000',
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

  group('spoof fail-closed end-to-end (never marked)', () {
    Future<ProxServer> openTestServer({List<Uint8List> pins = const []}) async {
      final prof = ProxCrypto.generateEdKeypair();
      final server = ProxServer(
        classLabel: 't',
        profSk: prof.privateKey,
        profPk: prof.publicKey,
        sightings: (
                {required peerW,
                required expectedAirKey,
                required expectedUuid}) =>
            const RadioSighting(rssiDbm: -55, hop: 0),
        pinnedRoots: pins.isEmpty ? null : pins,
        // ignore: cascade_invocations
      )..testChainGate = pins.isEmpty
          ? null
          : testChainGate;
      await server.start(port: 0);
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
      return server;
    }

    // Fresh HW test device (real P-256 dSig + AAD seal); [salt] distinct
    // per device.
    Future<({InMemoryDeviceStore store, TestHwDevice hw})> freshTestStore(
        int salt) async {
      final hw = await freshHwDevice(
          email: _email, seedBytes: randBytes(32), salt: salt);
      return (
        store: await hwEnrolledStore(email: _email, hw: hw),
        hw: hw,
      );
    }

    void injectSighting(ProxBleEngine engine, ProxServer server) {
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
    }

    ClassBeacon testTarget(int port) => ClassBeacon(
        classLabel: 't',
        host: '127.0.0.1',
        port: port,
        rssiDbm: 0,
        displayCode: 'X');

    const testIdentity = LinkedIdentity(name: 'S', gmail: _email, roll: '1');

    test('spoof (low liveness) then prove fails as faceFailed, never marked',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      final fdev = await freshTestStore(82);
      final server = await openTestServer(pins: fdev.hw.pins);
      try {
        final engine = ProxBleEngine(radio: FakeBleRadio());
        final d = RealStudentDriver(
          store: fdev.store,
          verifier: FakeFaceVerifier(match: true, score: 0.85),
          deviceKey: fdev.hw.deviceKey,
          engine: engine,
          // Readable still of the enrolled holder, but not live: the
          // matcher would hit, so the gate must stop it first.
          livenessGate: FakeLivenessGate(score: 0.31),
        )..silenceCap = const Duration(seconds: 10);
        final check = await d.checkFace('photo-of-enrolled.jpg');
        expect(check.match, FaceMatch.mismatch);
        expect(check.score, 0);
        expect(check.faceValidAtMs, 0);
        injectSighting(engine, server);
        // The spoof carried no holder evidence (score 0, stamp 0): the
        // SK-use gate was never armed, so proving refuses terminally.
        final res = await d.listenAndProve(
          target: testTarget(server.port),
          identity: testIdentity,
          faceScore: check.score,
          faceValidAtMs: check.faceValidAtMs,
          verifierVer: check.verifierVer,
          onStatus: (_) {},
        );
        expect(res.result, StudentResult.faceFailed,
            reason: 'detail=${res.detail}');
        expect(server.tally.presentCount, 0);
      } finally {
        await server.stop();
      }
    });

    test('explicit weak liveness is not masked by a strong cache',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      final fdev = await freshTestStore(83);
      final server = await openTestServer(pins: fdev.hw.pins);
      try {
        final engine = ProxBleEngine(radio: FakeBleRadio());
        final d = RealStudentDriver(
          store: fdev.store,
          verifier: FakeFaceVerifier(match: true, score: 0.85),
          deviceKey: fdev.hw.deviceKey,
          engine: engine,
          livenessGate: FakeLivenessGate(score: 0.92),
        )..silenceCap = const Duration(seconds: 10);
        final check = await d.checkFace('still.jpg');
        expect(check.match, FaceMatch.pass);
        expect(check.livenessScore, 0.92);
        injectSighting(engine, server);
        // Explicit args win over the 0.92 checkFace cache: the signed
        // ticket carries the weak claim, and the host (requireLiveness
        // enforced) rejects it — never a silent cache upgrade.
        final res = await d.listenAndProve(
          target: testTarget(server.port),
          identity: testIdentity,
          faceScore: check.score,
          faceValidAtMs: check.faceValidAtMs,
          verifierVer: check.verifierVer,
          livenessScore: 0.31,
          livenessVer: kLivenessVer,
          onStatus: (_) {},
        );
        expect(res.result, StudentResult.error,
            reason: 'detail=${res.detail}');
        expect(res.detail, contains('liveness-below-threshold'));
        expect(server.tally.presentCount, 0);
      } finally {
        await server.stop();
      }
    });
  });
}
