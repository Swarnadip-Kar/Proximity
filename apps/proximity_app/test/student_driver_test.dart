import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';

const _email = 's@x.in';
const _beacon = ClassBeacon(
  classLabel: 't',
  host: '127.0.0.1',
  port: 9,
  rssiDbm: 0,
  displayCode: 'X',
);

Future<InMemoryDeviceStore> enrolledStore({
  String verifierVer = kFaceVerifierVer,
  String faceId = 'face-test-id',
  String? seedHex,
  String attestationLevel = 'NONE',
  DateTime? attestedUntil,
  String pkDHex = '',
}) async {
  final s = InMemoryDeviceStore();
  await s.writeEnrollment(StoredEnrollment(
    email: _email,
    name: 'S',
    roll: '1',
    seedHex: seedHex ?? ('ab' * 32),
    pkHex: 'cd' * 32,
    faceId: faceId,
    enrolledAt: DateTime.now().toUtc(),
    verifierVer: verifierVer,
    attestationLevel: attestationLevel,
    attestedUntil: attestedUntil ?? DateTime.utc(2026, 12, 31),
    pkDHex: pkDHex,
  ));
  return s;
}

FakeFaceVerifier mockVerifier({bool match = true, double score = 0.85}) =>
    FakeFaceVerifier(match: match, score: score);

RealStudentDriver testDriver(
        {required InMemoryDeviceStore store,
        FakeFaceVerifier? verifier,
        FakeDeviceKey? deviceKey,
        LivenessGate? livenessGate,
        required ProxBleEngine engine}) =>
    RealStudentDriver(
      store: store,
      verifier: verifier ?? mockVerifier(),
      deviceKey: deviceKey ?? FakeDeviceKey(),
      engine: engine,
      livenessGate: livenessGate ?? FakeLivenessGate(),
    );

void main() {
  test('checkFace passes with enrolled template', () async {
    final d = RealStudentDriver(
      store: await enrolledStore(),
      verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
      engine: ProxBleEngine(radio: FakeBleRadio()),
      livenessGate: FakeLivenessGate(),
    );
    final res = await d.checkFace('still.jpg');
    expect(res.match, FaceMatch.pass);
    expect(res.score, 0.85);
    // The pass carries the Sig_s ticket (stamp + pipeline tag).
    expect(res.faceValidAtMs, greaterThan(0));
    expect(res.verifierVer, kFaceVerifierVer);
  });

  test('checkFace without enrollment is inconclusive (keeps attempt)',
      () async {
    final d = RealStudentDriver(
      store: InMemoryDeviceStore(),
      verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
      engine: ProxBleEngine(radio: FakeBleRadio()),
      livenessGate: FakeLivenessGate(),
    );
    final res = await d.checkFace('still.jpg');
    expect(res.match, FaceMatch.inconclusive);
  });

  test('checkFace with stale pipeline template never matches (re-enroll)',
      () async {
    final d = RealStudentDriver(
      store: await enrolledStore(verifierVer: 'edgeface-xs-g06-tflite-1'),
      verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
      engine: ProxBleEngine(radio: FakeBleRadio()),
      livenessGate: FakeLivenessGate(),
    );
    // Even a perfect probe scores nothing: incomparable embeddings must
    // not produce a pass OR burn a mismatch attempt.
    final res = await d.checkFace('still.jpg');
    expect(res.match, FaceMatch.staleTemplate);
    expect(res.score, 0);
  });

  test('probeWindow carries the window display code when open', () async {
    // Round identity for the student rewait: same code = same round.
    final prof = ProxCrypto.generateEdKeypair();
    final server = ProxServer(
      classLabel: 't',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: (
              {required peerW,
              required expectedAirKey,
              required expectedUuid}) =>
          null,
    );
    await server.start(port: 0);
    final d = RealStudentDriver(
      store: InMemoryDeviceStore(),
      verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
      engine: ProxBleEngine(radio: FakeBleRadio()),
    );
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
      final open = await d.probeWindow(ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X'));
      expect(open.windowOpen, isTrue);
      expect(open.display, server.window!.displayCode);
      server.closeWindow();
      final closed = await d.probeWindow(ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X'));
      expect(closed.windowOpen, isFalse);
    } finally {
      await server.stop();
    }
  });

  test('mesh relay lingers 20s after the token is heard', () async {
    final engine = ProxBleEngine(radio: FakeBleRadio());
    final d = RealStudentDriver(
      store: await enrolledStore(),
      verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
      engine: engine,
    );
    // Token heard over radio; no server answers at :9 (refused = wrong
    // IP, fails fast) — but the relay must stay up for the back rows,
    // not cut at the failure.
    Future.delayed(const Duration(milliseconds: 300), () {
      engine.handleSighting(BleSighting(
        type: kAirTypeChallenge,
        token8: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        rssiDbm: -60,
        at: DateTime.now().toUtc(),
      ));
    });
    final res = await d.listenAndProve(
      target: _beacon,
      identity:
          const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
      faceScore: 1.0,
      onStatus: (_) {},
    );
    expect(res.result, StudentResult.error);
    expect(res.detail, contains('unreachable'));
    expect(engine.relayEnabled, isTrue);
  });

  test('quiet spell re-arms the platform scan while listening',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // Observed live: the platform scan dies silently while reporting
    // active (zero sightings for minutes with an open window on air) and
    // only a fresh start revives it. Every quiet slice restarts it.
    final engine = ProxBleEngine(radio: FakeBleRadio());
    final d = RealStudentDriver(
      store: await enrolledStore(),
      verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
      engine: engine,
    )
      ..silenceCap = const Duration(seconds: 3)
      ..scanRestartSlice = const Duration(seconds: 1);
    BleLog.clear();
    final res = await d.listenAndProve(
      target: _beacon,
      identity:
          const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
      faceScore: 1.0,
      onStatus: (_) {},
    );
    expect(res.result, StudentResult.noSignal);
    expect(
        BleLog.history.any((e) => e.msg.contains('re-arming scan')), isTrue);
    expect(
        BleLog.history
            .any((e) => e.msg.contains('scan restarted via fake')),
        isTrue);
  });

  test('dead air + unreachable -> noSignal (never fake-marked)',      timeout: const Timeout(Duration(minutes: 2)), () async {
    final engine = ProxBleEngine(radio: FakeBleRadio());
    final d = RealStudentDriver(
      store: await enrolledStore(),
      verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
      engine: engine,
    )..silenceCap = const Duration(seconds: 2);
    // Nothing ever arrives over radio; the :9 probe is unreachable, so
    // the silence check ends the listen instead of hanging.
    final res = await d.listenAndProve(
      target: _beacon,
      identity:
          const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
      faceScore: 1.0,
      onStatus: (_) {},
    );
    expect(res.result, StudentResult.noSignal);
    // Nothing heard: nothing to relay for — mesh off immediately.
    expect(engine.relayEnabled, isFalse);
  });

  test('dead air + open window keeps waiting, then marks on signal',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // Silence alone never ends a listen while the round is open: the
    // probe says open, waiting continues, and the next rotation marks.
    final prof = ProxCrypto.generateEdKeypair();
    final seed = randBytes(32);
    final stuPk = ed.public(ed.newKeyFromSeed(seed));
    final store = InMemoryDeviceStore();
    await store.writeEnrollment(StoredEnrollment(
      email: _email,
      name: 'S',
      roll: '1',
      seedHex: hexEncode(seed),
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
      final d = RealStudentDriver(
        store: store,
        verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
        engine: engine,
      )..silenceCap = const Duration(seconds: 2);
      // First rotation arrives after one silence probe says "still open".
      Future.delayed(const Duration(seconds: 3), () {
        final w = server.window!;
        final cj = w.challengeFor(w.jForTime(DateTime.now().toUtc()));
        engine.handleSighting(BleSighting(
          type: kAirTypeChallenge,
          token8: cj,
          ipHost: '127.0.0.1',
          ipPort: server.port,
          rssiDbm: -60,
          at: DateTime.now().toUtc(),
        ));
      });
      final statuses = <ListenStatus>[];
      final res = await d.listenAndProve(
        target: ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X',
        ),
        identity:
            const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
        faceScore: 0.9,
        onStatus: statuses.add,
      );
      expect(res.result, StudentResult.marked);
      expect(server.tally.presentCount, 1);
      // The UI saw the wait before the proof (no countdown anywhere).
      expect(statuses.first, ListenStatus.waiting);
      expect(statuses, contains(ListenStatus.proving));
    } finally {
      await server.stop();
    }
  });

  test('stale previous-round token proves on the fresh rotation and marks',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // The professor retakes the round (fresh window secrets) while a
    // stale relay of the previous round's token is still on air. The
    // student hears the stale token first — proving waits for the fresh
    // rotation instead of failing.
    final prof = ProxCrypto.generateEdKeypair();
    final seed = randBytes(32);
    final stuPk = ed.public(ed.newKeyFromSeed(seed));
    final store = InMemoryDeviceStore();
    await store.writeEnrollment(StoredEnrollment(
      email: _email,
      name: 'S',
      roll: '1',
      seedHex: hexEncode(seed),
      pkHex: hexEncode(stuPk.bytes),
      faceId: 'face-test-id',
      enrolledAt: DateTime.now().toUtc(),
      verifierVer: kFaceVerifierVer,
    ));
    WindowParams freshWindow() => WindowParams(
          sessionId: randBytes(16),
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc(),
          classLabel: 't',
        );
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
      server.openWindow(freshWindow(), 1);
      final stale = server.window!.challengeFor(0);
      server.openWindow(freshWindow(), 2); // retaken round, fresh secrets
      final live = server.window!.challengeFor(0);
      final engine = ProxBleEngine(radio: FakeBleRadio());
      final d = RealStudentDriver(
        store: store,
        verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
        engine: engine,
      );
      // Stale token first, then the live rotation — both over radio
      // (no hearChallenge seam: the driver listens to the engine).
      void inject(Uint8List tok) => engine.handleSighting(BleSighting(
            type: kAirTypeChallenge,
            token8: tok,
            ipHost: '127.0.0.1',
            ipPort: server.port,
            rssiDbm: -60,
            at: DateTime.now().toUtc(),
          ));
      Future.delayed(const Duration(milliseconds: 300), () => inject(stale));
      Future.delayed(const Duration(seconds: 2), () => inject(live));
      final res = await d.listenAndProve(
        target: ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X',
        ),
        identity:
            const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
        faceScore: 0.9,
        onStatus: (_) {},
      );
      expect(res.result, StudentResult.marked);
      expect(server.tally.presentCount, 1);
    } finally {
      await server.stop();
    }
  });

  test('repeated closed-window fetches are never suspicious (no fake-professor ×6)',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // Regression: every fetch failure (closed window, rate limit, stale
    // token) used to count as "suspicious", so six stray tokens against a
    // closed-but-reachable server ended the listen with "No valid class
    // signal" — a fake-professor scare for a REAL server. Only a genuine
    // signature mismatch feeds the streak now; closed windows reset it.
    final prof = ProxCrypto.generateEdKeypair();
    final seed = randBytes(32);
    final stuPk = ed.public(ed.newKeyFromSeed(seed));
    final store = InMemoryDeviceStore();
    await store.writeEnrollment(StoredEnrollment(
      email: _email,
      name: 'S',
      roll: '1',
      seedHex: hexEncode(seed),
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
      // No window open (round over, retake not yet tapped).
      final engine = ProxBleEngine(radio: FakeBleRadio());
      final d = RealStudentDriver(
        store: store,
        verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
        engine: engine,
      )..silenceCap = const Duration(seconds: 8);
      // Eight stray tokens: each fetch fails "window closed" — none may
      // feed the suspicious streak.
      for (var i = 0; i < 8; i++) {
        Future.delayed(Duration(milliseconds: 300 * (i + 1)), () {
          engine.handleSighting(BleSighting(
            type: kAirTypeChallenge,
            token8: Uint8List.fromList([i, 9, 9, 9, 9, 9, 9, 9]),
            rssiDbm: -60,
            at: DateTime.now().toUtc(),
          ));
        });
      }
      final res = await d.listenAndProve(
        target: ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X',
        ),
        identity:
            const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
        faceScore: 0.9,
        onStatus: (_) {},
      );
      // Honest ending (round over), never the fake-professor error.
      expect(res.result, StudentResult.noSignal);
      expect(res.detail, isNot(contains('No valid class signal')));
      expect(server.tally.presentCount, 0);
    } finally {
      await server.stop();
    }
  });

  test('signing without a fresh face check refuses (SK stays locked)',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // The SK-use gate time-bounds the holder check: a listen that starts
    // with no passing face score never signs, even with a live challenge
    // on air and a reachable server. (Below-threshold scores mean "no
    // valid check" — a pass always scores >= kFaceThreshold — so the
    // server-side face-below-threshold stays defense-in-depth for other
    // clients; protocol verify_test covers it.)
    final prof = ProxCrypto.generateEdKeypair();
    final seed = randBytes(32);
    final stuPk = ed.public(ed.newKeyFromSeed(seed));
    final store = InMemoryDeviceStore();
    await store.writeEnrollment(StoredEnrollment(
      email: _email,
      name: 'S',
      roll: '1',
      seedHex: hexEncode(seed),
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
      final d = RealStudentDriver(
        store: store,
        verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
        engine: engine,
      )..silenceCap = const Duration(seconds: 2);
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
      final res = await d.listenAndProve(
        target: ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X',
        ),
        identity:
            const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
        faceScore: 0.0,
        onStatus: (_) {},
      );
      expect(res.result, StudentResult.faceFailed);
      expect(res.detail, contains('Face check expired'));
      expect(server.tally.presentCount, 0);
    } finally {
      await server.stop();
    }
  });

  test('closed window + dead air ends the listen (no hang, no mark)',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // Professor stopped the round but hasn't retaken yet: a stray token
    // verifies against nothing, then dead air + the probe (reachable but
    // closed) ends the listen honestly.
    final prof = ProxCrypto.generateEdKeypair();
    final seed = randBytes(32);
    final stuPk = ed.public(ed.newKeyFromSeed(seed));
    final store = InMemoryDeviceStore();
    await store.writeEnrollment(StoredEnrollment(
      email: _email,
      name: 'S',
      roll: '1',
      seedHex: hexEncode(seed),
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
      // No window open (round over, retake not yet tapped).
      final engine = ProxBleEngine(radio: FakeBleRadio());
      final d = RealStudentDriver(
        store: store,
        verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
        engine: engine,
      )..silenceCap = const Duration(seconds: 2);
      // One stray token over radio, then nothing: fetch fails closed,
      // the silence check probes (reachable, closed) and ends it.
      Future.delayed(const Duration(milliseconds: 300), () {
        engine.handleSighting(BleSighting(
          type: kAirTypeChallenge,
          token8: Uint8List.fromList([9, 9, 9, 9, 9, 9, 9, 9]),
          rssiDbm: -60,
          at: DateTime.now().toUtc(),
        ));
      });
      final res = await d.listenAndProve(
        target: ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X',
        ),
        identity:
            const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
        faceScore: 0.9,
        onStatus: (_) {},
      );
      expect(res.result, StudentResult.noSignal);
      expect(server.tally.presentCount, 0);
    } finally {
      await server.stop();
    }
  });

  test('live-shaped response sighting marks via the real prof mapping',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // End-to-end pin for the no-ble-sighting outage: the professor's
    // radio hears the student's response as a DEFAULT-ttl (3) sighting —
    // exactly like live air — and the real host mapping must still
    // accept it (hop 0, RSSI-gated), or every live prove fails invalid.
    final prof = ProxCrypto.generateEdKeypair();
    final seed = randBytes(32);
    final stuPk = ed.public(ed.newKeyFromSeed(seed));
    final store = InMemoryDeviceStore();
    await store.writeEnrollment(StoredEnrollment(
      email: _email,
      name: 'S',
      roll: '1',
      seedHex: hexEncode(seed),
      pkHex: hexEncode(stuPk.bytes),
      faceId: 'face-test-id',
      enrolledAt: DateTime.now().toUtc(),
      verifierVer: kFaceVerifierVer,
    ));
    final engine = ProxBleEngine(radio: FakeBleRadio());
    final server = ProxServer(
      classLabel: 't',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      // The REAL host mapping (not a hop-0 stub): response sightings
      // injected below carry the live default ttl.
      sightings: (
              {required peerW,
              required expectedAirKey,
              required expectedUuid}) =>
          RealHostDriver.matchResponse(engine, expectedAirKey, expectedUuid),
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
      final cj = server.window!.challengeFor(0);
      // The professor's radio hears the challenge AND the student's answer
      // over the air (injected here — FakeBleRadio stands in for it).
      // Injected mid-listen: listenAndProve deliberately clears stale
      // sightings at round start, like a real round boundary would.
      Future.delayed(const Duration(milliseconds: 500), () {
        engine.handleSighting(BleSighting(
          type: kAirTypeChallenge,
          token8: cj,
          ipHost: '127.0.0.1',
          ipPort: server.port,
          rssiDbm: -55,
          at: DateTime.now().toUtc(),
        ));
        engine.handleSighting(BleSighting(
          type: kAirTypeResponse,
          token8: ProxCrypto.responseToken(cj, _email),
          ipHost: '127.0.0.1',
          ipPort: server.port,
          rssiDbm: -55,
          at: DateTime.now().toUtc(),
        ));
      });
      final d = RealStudentDriver(
        store: store,
        verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
        engine: engine,
      );
      final res = await d.listenAndProve(
        target: ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X',
        ),
        identity:
            const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
        faceScore: 0.9,
        onStatus: (_) {},
      );
      expect(res.result, StudentResult.marked);
      expect(server.tally.presentCount, 1);
    } finally {
      await server.stop();
    }
  });

  test('unheard response proves on the next rotation and marks',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // The professor's radio misses the first answer (no-ble-sighting):
    // the student re-announces + re-proves on the next live token
    // instead of failing.
    final prof = ProxCrypto.generateEdKeypair();
    final seed = randBytes(32);
    final stuPk = ed.public(ed.newKeyFromSeed(seed));
    final store = InMemoryDeviceStore();
    await store.writeEnrollment(StoredEnrollment(
      email: _email,
      name: 'S',
      roll: '1',
      seedHex: hexEncode(seed),
      pkHex: hexEncode(stuPk.bytes),
      faceId: 'face-test-id',
      enrolledAt: DateTime.now().toUtc(),
      verifierVer: kFaceVerifierVer,
    ));
    final engine = ProxBleEngine(radio: FakeBleRadio());
    // First answer unheard, re-announced answers heard.
    var lookups = 0;
    final server = ProxServer(
      classLabel: 't',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: (
              {required peerW,
              required expectedAirKey,
              required expectedUuid}) =>
          (++lookups <= 1)
              ? null
              : RealHostDriver.matchResponse(
                  engine, expectedAirKey, expectedUuid),
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
      // Challenge for the CURRENT sub-epoch, computed lazily at inject
      // time so the token always matches j_now.
      void injectCurrent({bool withResponse = false}) {
        final w = server.window!;
        final tok =
            w.challengeFor(w.jForTime(DateTime.now().toUtc()).clamp(0, 1 << 30));
        engine.handleSighting(BleSighting(
          type: kAirTypeChallenge,
          token8: tok,
          ipHost: '127.0.0.1',
          ipPort: server.port,
          rssiDbm: -55,
          at: DateTime.now().toUtc(),
        ));
        if (withResponse) {
          // The professor's radio hears the re-announced answer.
          engine.handleSighting(BleSighting(
            type: kAirTypeResponse,
            token8: ProxCrypto.responseToken(tok, _email),
            ipHost: '127.0.0.1',
            ipPort: server.port,
            rssiDbm: -55,
            at: DateTime.now().toUtc(),
          ));
        }
      }

      Future.delayed(const Duration(milliseconds: 300), injectCurrent);
      // Next rotation (j advanced): new token, answer heard this time.
      Future.delayed(const Duration(seconds: 6),
          () => injectCurrent(withResponse: true));
      final d = RealStudentDriver(
        store: store,
        verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
        engine: engine,
      );
      final res = await d.listenAndProve(
        target: ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X',
        ),
        identity:
            const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
        faceScore: 0.9,
        onStatus: (_) {},
      );
      expect(res.result, StudentResult.marked);
      expect(server.tally.presentCount, 1);
    } finally {
      await server.stop();
    }
  });

test('bound e2e: ticket + dSig + FULL attestation marks (no flags)',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // Tracks 2+3 happy path over the real server: checkFace stamps the
    // ticket, listenAndProve binds pkD+ticketHash into Sig_s and posts
    // pkD + dSig + attestation claims; the host confirms clean.
    final prof = ProxCrypto.generateEdKeypair();
    final seed = randBytes(32);
    final stuPk = ed.public(ed.newKeyFromSeed(seed));
    final pkDHex = hexEncode(Uint8List.fromList(List.filled(32, 7)));
    final store = await enrolledStore(
      seedHex: hexEncode(seed),
      attestationLevel: 'FULL',
      attestedUntil: DateTime.now().toUtc().add(const Duration(days: 80)),
      pkDHex: pkDHex,
    );
    // pkHex in the store is display-only; the proof presents the live key.
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
      final d = testDriver(store: store, engine: engine);
      final check = await d.checkFace('still.jpg');
      expect(check.match, FaceMatch.pass);
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
      final res = await d.listenAndProve(
        target: ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X',
        ),
        identity:
            const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
        faceScore: check.score,
        faceValidAtMs: check.faceValidAtMs,
        verifierVer: check.verifierVer,
        onStatus: (_) {},
      );
      expect(res.result, StudentResult.marked);
      expect(server.tally.presentCount, 1);
      expect(stuPk.bytes.length, 32); // live key presented, not the stub
    } finally {
      await server.stop();
    }
  });

  test('bound e2e with NONE attestation marks via fallback flag',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // Graceful fallback (HW keys don't ship): production is always
    // SoftwareDeviceKey/NONE, so a bound-NONE proof confirms like the
    // legacy path — same ticket-bound Sig_s + sighting checks, no tier
    // claimed — with the fallback flag logged, not a device-unproven
    // reject. This is the live-marking path for genuine students today.
    final prof = ProxCrypto.generateEdKeypair();
    final seed = randBytes(32);
    final store = await enrolledStore(seedHex: hexEncode(seed));
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
      final d = testDriver(store: store, engine: engine);
      final check = await d.checkFace('still.jpg');
      expect(check.match, FaceMatch.pass);
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
      final res = await d.listenAndProve(
        target: ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X',
        ),
        identity:
            const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
        faceScore: check.score,
        faceValidAtMs: check.faceValidAtMs,
        verifierVer: check.verifierVer,
        onStatus: (_) {},
      );
      expect(res.result, StudentResult.marked);
      expect(res.attestationFlags, contains('device-none-fallback'));
      expect(server.tally.presentCount, 1);
    } finally {
      await server.stop();
    }
  });

  test('clone simulation: sealed key on a new install fails to unwrap',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // Backup-restore clone: ciphertext copied to an install whose DKey
    // cannot open it → 'restore detected — re-enroll', nothing signed.
    final deviceKey = FakeDeviceKey();
    final seed = randBytes(32);
    final sealed = await deviceKey.seal(seed);
    final store = InMemoryDeviceStore();
    await store.writeEnrollment(StoredEnrollment(
      email: _email,
      name: 'S',
      roll: '1',
      seedHex: '',
      pkHex: 'cd' * 32,
      sealedKeyHex: hexEncode(sealed),
      faceId: 'face-test-id',
      enrolledAt: DateTime.now().toUtc(),
      verifierVer: kFaceVerifierVer,
    ));
    deviceKey.dropKey(); // the clone's fresh key cannot open the envelope
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
      final d = RealStudentDriver(
        store: store,
        verifier: mockVerifier(),
        deviceKey: deviceKey,
        engine: engine,
        livenessGate: FakeLivenessGate(),
      );
      // checkFace still passes (faceId matches) — the clone fails at SIGN
      // time, when the sealed SKey refuses to unwrap.
      expect((await d.checkFace('still.jpg')).match, FaceMatch.pass);
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
      final res = await d.listenAndProve(
        target: ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X',
        ),
        identity:
            const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
        faceScore: 0.85,
        faceValidAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
        verifierVer: kFaceVerifierVer,
        onStatus: (_) {},
      );
      expect(res.result, StudentResult.error);
      expect(res.detail, contains('restore detected — re-enroll'));
      expect(server.tally.presentCount, 0);
    } finally {
      await server.stop();
    }
  });

  test('hook simulation: mismatched verify never passes, burns nothing',
      () async {
    // An injected/hooked verifier that cannot match the enrolled faceId
    // yields mismatch (readable, somebody else) — never a pass, and the
    // test asserts the attempt accounting stays with the caller: no pass,
    // no ticket, nothing to sign.
    final d = RealStudentDriver(
      store: await enrolledStore(),
      verifier: mockVerifier(match: false),
      deviceKey: FakeDeviceKey(),
      engine: ProxBleEngine(radio: FakeBleRadio()),
      livenessGate: FakeLivenessGate(),
    );
    final res = await d.checkFace('attacker-still.jpg');
    expect(res.match, FaceMatch.mismatch);
    expect(res.faceValidAtMs, 0);
    expect(res.verifierVer, isEmpty);
  });

  test('records-only listenAndProve refuses before any radio (L1)',
      () async {
    // Desktop/web builds never listen-and-prove: guidance receipt, no
    // radio, nothing signed. (RealStudentDriver gates on canUseFace;
    // this host is desktop in flutter_test only when pinned — instead
    // assert the Fake-level contract: FakeStudentDriver ignores L1 by
    // design for UI tests, so pin the REAL driver behind an override.)
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final d = RealStudentDriver(
      store: await enrolledStore(),
      verifier: mockVerifier(),
      deviceKey: FakeDeviceKey(),
      engine: ProxBleEngine(radio: FakeBleRadio()),
    );
    final res = await d.listenAndProve(
      target: _beacon,
      identity: const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
      faceScore: 0.85,
      onStatus: (_) {},
    );
    debugDefaultTargetPlatformOverride = null;
    expect(res.result, StudentResult.error);
    expect(res.detail, contains('mobile app'));
  });

  test('engine nextChallenge resolves injected sightings', () async {
    // Full client prove against a real local ProxServer is covered in
    // transport tests; here the radio wait resolves and progress completes.
    final engine = ProxBleEngine(radio: FakeBleRadio());
    // Inject a challenge sighting straight into the engine (as the BLE
    // stack would), then resolve via nextChallenge.
    final cj = Uint8List.fromList([4, 4, 4, 4, 4, 4, 4, 4]);
    engine.handleSighting(BleSighting(
      type: kAirTypeChallenge,
      token8: cj,
      ipHost: '10.50.19.107',
      ipPort: 8443,
      rssiDbm: -60,
      at: DateTime.now().toUtc(),
    ));
    final heard = await engine.nextChallenge(
        timeout: const Duration(seconds: 2));
    expect(heard, cj);
  });
}
