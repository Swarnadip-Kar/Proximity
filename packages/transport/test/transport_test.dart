// Real HTTPS loop over localhost: shelf server + TLS client + binding.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:pointycastle/export.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';
import 'package:test/test.dart';

const _email = 'student@example.com';

// Fresh-proof fixtures (no legacy bodies confirm): every confirming prove
// in this suite sends a bound+liveness+FULL proof with a genuine P-256 dSig
// and a fake-DER chain carrying the OID + recomputed challenge + pkD. The
// server verifies through the REAL testChainGate stub (challenge
// containment + pkD containment + pin) — X.509 signature math lives in
// protocol chain_verify_test on genuine fixtures.
const _freshInstallId = 'inst-test-1';
const _freshVerifierVer = 'face_verification/test+deadbeef';
// Allowlisted liveness pipeline tag (prefix `liveness/`).
const _freshLiveVer = 'liveness/minifasnet-v2-test+a1b2c3d4';

SecureRandom _frand([int salt = 5]) {
  final r = SecureRandom('Fortuna');
  r.seed(KeyParameter(Uint8List.fromList(
      List.generate(32, (i) => (i * 11 + salt) & 0xFF))));
  return r;
}

({Uint8List pkD, BigInt d}) _freshP256Key([int salt = 5]) {
  final domain = ECDomainParameters('prime256v1');
  final gen = ECKeyGenerator()
    ..init(ParametersWithRandom(
        ECKeyGeneratorParameters(domain), _frand(salt)));
  final pair = gen.generateKeyPair();
  final ECPublicKey pub = pair.publicKey;
  return (
    pkD: Uint8List.fromList(pub.Q!.getEncoded(false).sublist(1)),
    d: pair.privateKey.d!,
  );
}

Uint8List _freshP256Sign(BigInt d, Uint8List preimage, [int salt = 7]) {
  final domain = ECDomainParameters('prime256v1');
  final signer = ECDSASigner(SHA256Digest())
    ..init(
        true,
        ParametersWithRandom(
            PrivateKeyParameter(ECPrivateKey(d, domain)), _frand(salt)));
  final sig = signer.generateSignature(preimage) as ECSignature;
  Uint8List be(BigInt v) =>
      hexDecode(v.toRadixString(16).padLeft(64, '0'));
  return Uint8List.fromList([...be(sig.r), ...be(sig.s)]);
}

/// Fake-DER chain: leaf embeds the attestation OID + [challenge] + raw pkD
/// bytes; root is random bytes. Returns (chainHex, rootDer) — the caller
/// pins sha256(rootDer).
(List<String>, Uint8List) _freshChainFor(Uint8List challenge, Uint8List pkD,
    [int salt = 9]) {
  final leaf = Uint8List.fromList(
      [...kKeyAttestationOidDer, ...challenge, ...pkD, 0xAA, 0xBB]);
  final root = Uint8List.fromList(
      List.generate(64, (i) => (i * 13 + salt) & 0xFF));
  return ([hexEncode(leaf), hexEncode(root)], root);
}

/// Test-only chain gate for fake-DER fixtures (mirrors hw_prove_test):
/// challenge + pkD byte-containment, OID, pin. No X.509 math.
ChainPinResult _fakeChainGate({
  required AttestationChain chain,
  required List<Uint8List> pinnedRootHashes,
  required Uint8List expectedChallenge,
  required Uint8List? expectedLeafPkD,
  required AttestationLevel level,
  String appAttestRawHex = '',
}) {
  if (level == AttestationLevel.none) {
    return const ChainPinResult(
        ok: false, reason: 'level-none', flags: ['attest-level-none']);
  }
  if (chain.isEmpty) {
    return const ChainPinResult(
        ok: false, reason: 'empty-chain', flags: ['attest-empty-chain']);
  }
  final leaf = chain.leaf!;
  if (!attestationLeafHasKeyOid(leaf)) {
    return const ChainPinResult(
        ok: false,
        reason: 'missing-attestation-oid',
        flags: ['attest-missing-oid']);
  }
  if (expectedLeafPkD != null &&
      expectedLeafPkD.isNotEmpty &&
      !attestationLeafContainsChallenge(leaf, expectedLeafPkD)) {
    return const ChainPinResult(
        ok: false,
        reason: 'leaf-pkd-mismatch',
        flags: ['attest-leaf-pkd-mismatch']);
  }
  if (!attestationLeafContainsChallenge(leaf, expectedChallenge)) {
    return const ChainPinResult(
        ok: false,
        reason: 'challenge-mismatch',
        flags: ['attest-challenge-mismatch']);
  }
  final rootHash = ProxCrypto.sha256Sync(chain.root!);
  if (!pinnedRootHashes.any((h) => bytesEqual(h, rootHash))) {
    return const ChainPinResult(
        ok: false, reason: 'unknown-root', flags: ['attest-unknown-root']);
  }
  return const ChainPinResult(ok: true, reason: 'ok');
}

/// A test device enrollment: P-256 key + fake chain bound to
/// (email, installId, pkS) via the V2 challenge — the same binding the
/// professor recomputes. One per (email, key) pair.
({Uint8List pkD, BigInt d, List<String> chainHex, Uint8List rootDer})
    freshDevice({
  required String email,
  required Uint8List pkS,
  String installId = _freshInstallId,
  int salt = 5,
}) {
  final dev = _freshP256Key(salt);
  final challenge = deviceBindingChallengeV2(
      emailLower: email, installId: installId, pkS: pkS);
  final (chainHex, rootDer) = _freshChainFor(challenge, dev.pkD, salt);
  return (pkD: dev.pkD, d: dev.d, chainHex: chainHex, rootDer: rootDer);
}

/// Full fresh prove: bound ticket + liveness + FULL + genuine dSig +
/// chain. Confirms against a server pinning sha256(fd.rootDer).
Future<ProveResult> proveFresh(
  ProxClient client, {
  required WindowDescriptor desc,
  required Uint8List cj,
  required int j,
  required ed.KeyPair stu,
  required String email,
  required ({
    Uint8List pkD,
    BigInt d,
    List<String> chainHex,
    Uint8List rootDer,
  }) fd,
  double face = 0.9,
  String installId = _freshInstallId,
  String? vec,
  String verifierVer = _freshVerifierVer,
  int? faceValidAtMs,
  double livenessScore = 0.92,
  String livenessVer = _freshLiveVer,
}) {
  final pkS = pk32(stu.publicKey);
  final peerW = ProxCrypto.peerAlias(pkS, desc.windowId);
  final stampMs =
      faceValidAtMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
  return client.prove(
    desc: desc,
    studentId: email,
    challenge: cj,
    j: j,
    faceScore: face,
    peerW: peerW,
    pkS: pkS,
    name: email,
    roll: '12342210',
    sigSFor: (c, jj) => ProxCrypto.signStudentProve(
      studentSk: stu.privateKey,
      sessionId: desc.sessionId,
      windowId: desc.windowId,
      j: jj,
      challenge: c,
      studentId: email,
      faceScore: face,
      faceValidAtMs: stampMs,
      verifierVer: verifierVer,
      pkD: fd.pkD,
      livenessScore: livenessScore,
      livenessVer: livenessVer,
    ),
    sigBindFor: (fp, jj) => ProxCrypto.sign(
        stu.privateKey,
        bindPreimage(
            sessionId: desc.sessionId,
            windowId: desc.windowId,
            j: jj,
            tlsFingerprint: fp)),
    faceValidAtMs: stampMs,
    verifierVer: verifierVer,
    pkD: fd.pkD,
    dSigFor: (ticket, jj, h) async => _freshP256Sign(
        fd.d,
        ProxCrypto.deviceProvePreimage(
          sessionId: desc.sessionId,
          windowId: desc.windowId,
          j: jj,
          challenge: cj,
          faceTicketHashBytes: ticket,
          pkS: pkS,
          integrityHash: h,
        )),
    integrityHash: '00000000',
    attestationLevel: 'FULL',
    attestedUntilMs: DateTime.now()
        .toUtc()
        .add(kDeviceAttestedValidity)
        .millisecondsSinceEpoch,
    livenessScore: livenessScore,
    livenessVer: livenessVer,
    attestationChain: fd.chainHex,
    installId: installId,
    faceVecB64: vec ?? '',
  );
}

Future<ProxServer> makeServer({
  required ed.KeyPair prof,
  required ed.KeyPair stu,
  int windowNo = 1,
  void Function(String email, String decision, String reason)? onProve,
  // Pins for the fake-DER test chain gate (sha256 of each test device's
  // rootDer — see freshDevice). Confirming proofs need their root pinned;
  // tests asserting early invalid reasons pass none.
  List<Uint8List> pins = const [],
}) async {
  final window = WindowParams(
    sessionId: randBytes(16),
    windowId: randBytes(6),
    secret: randBytes(32),
    t0: DateTime.now().toUtc(),
    classLabel: 'CS201-Room301',
  );
  final server = ProxServer(
    classLabel: 'CS201-Room301',
    profSk: prof.privateKey,
    profPk: prof.publicKey,
    sightings: ({required peerW, required expectedAirKey, required expectedUuid}) =>
        const RadioSighting(rssiDbm: -55, hop: 0),
    onProve: onProve,
    pinnedRoots: pins,
  )..testChainGate = _fakeChainGate;
  await server.start(port: 0);
  server.openWindow(window, windowNo);
  return server;
}

Uint8List pk32(ed.PublicKey k) =>
    Uint8List.fromList(k.bytes.sublist(0, 32));

void main() {
  test('TLS cert generates with stable fingerprint', () {
    final a = generateWindowTls();
    expect(a.fingerprint.length, 32);
    expect(a.certPem, contains('BEGIN CERTIFICATE'));
    expect(a.keyPem, contains('PRIVATE KEY'));
  });

  test('GET /window: gated profName rides LAN unicast, omitted when empty',
      () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final server = await makeServer(prof: prof, stu: stu);
    server.sessionProfEmail = 'Prof@Example.com';
    server.sessionProfName = 'Dr Ada';
    try {
      // Named host: gated LAN name lands on the announcement (BLE
      // untouched — probeHost synthesizes from the unicast result).
      final hit = await probeHost('127.0.0.1', server.port, org: '');
      expect(hit, isNotNull);
      expect(hit!.prof, 'Dr Ada');
      // Unnamed host: name stays empty (key omitted server-side so legacy
      // payloads stay byte-equal).
      server.sessionProfEmail = '';
      server.sessionProfName = '';
      server.sessionProfPhoto = '';
      final bare = await probeHost('127.0.0.1', server.port, org: '');
      expect(bare, isNotNull);
      expect(bare!.prof, '');
    } finally {
      await server.stop();
    }
  });

  test('GET / status page: reachable, no auth, no PII', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final server = await makeServer(prof: prof, stu: stu);
    final client = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    try {
      final req = await client.getUrl(Uri(
          scheme: 'https', host: '127.0.0.1', port: server.port, path: '/'));
      final resp = await req.close();
      expect(resp.statusCode, 200);
      expect(resp.headers.contentType?.mimeType, 'text/html');
      final body = await resp.transform(utf8.decoder).join();
      expect(body, contains('Proximity attendance system running'));
      expect(body, contains('CS201-Room301'));
      expect(body, contains('window OPEN'));
      // Roster data never leaves guarded endpoints.
      expect(body, isNot(contains(_email)));
      expect(body, isNot(contains('Sig_s')));
    } finally {
      client.close(force: true);
      await server.stop();
    }
  });

  test('full loop: window -> prove -> confirmed -> ACK verifies', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final proved = <String>[];
    final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
    final server = await makeServer(
      prof: prof,
      stu: stu,
      onProve: (e, d, r) {
        proved.add('$e $d $r');
      },
      pins: [ProxCrypto.sha256Sync(fd.rootDer)],
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      // Radio: student heard UUID_P(0) over BLE (fake radio in test).
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      expect(desc.display, server.window!.displayCode);

      const face = 0.85;
      final res = await proveFresh(
        client,
        desc: desc,
        cj: cj,
        j: 0,
        stu: stu,
        email: _email,
        fd: fd,
        face: face,
      );
      expect(res.decision, ProveDecision.confirmed);
      // First prove from an unpinned email marks via TOFU with a
      // `first-seen` log token (log only — the wire verdict is unchanged).
      expect(proved, ['$_email confirmed ok|direct-rssi|first-seen']);
      expect(
          res.verifyAck(
            profPk: prof.publicKey,
            sessionId: desc.sessionId,
            windowId: desc.windowId,
            j: 0,
            studentId: _email,
          ),
          isTrue);
      expect(server.tally.presentCount, 1);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('early invalids carry signed ACKs; first-seen TOFU marks', () async {
    // Field regression: `unknown-pkS` (and `org-mismatch`) used to return
    // a ZERO sigAck, so the student logged `BAD prof signature` while the
    // professor logged `unknown-pkS` — the same event, two stories. Every
    // early invalid is now signed; unpinned first-seen emails still mark
    // (TOFU, offline-first) with a `first-seen` log token.
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
    final proved = <String>[];
    final server = await makeServer(
      prof: prof,
      stu: stu,
      onProve: (e, d, r) {
        proved.add('$e $d $r');
      },
      pins: [ProxCrypto.sha256Sync(fd.rootDer)],
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      // 1) First-seen (no pin for this email): marks normally (TOFU) with
      // a signed ACK and a first-seen log token — offline is not fatal.
      final first = await proveFresh(
        client,
        desc: desc,
        cj: cj,
        j: 0,
        stu: stu,
        email: _email,
        fd: fd,
        face: 0.9,
      );
      expect(first.decision, ProveDecision.confirmed);
      expect(
          first.verifyAck(
            profPk: prof.publicKey,
            sessionId: desc.sessionId,
            windowId: desc.windowId,
            j: 0,
            studentId: _email,
          ),
          isTrue);
      expect(proved.last, contains('first-seen'));
      // 2) Stale pin (professor cached an older key, student re-enrolled):
      // fails closed as unknown-pkS — but the ACK VERIFIES, so the student
      // sees the true verdict instead of `BAD prof signature`.
      server.pinStudentKey(_email, hexEncode(Uint8List(32)), force: true);
      final cj2 = server.window!.challengeFor(0);
      final desc2 = await client.fetchWindow(cj2);
      final stale = await proveFresh(
        client,
        desc: desc2,
        cj: cj2,
        j: 0,
        stu: stu,
        email: _email,
        fd: fd,
        face: 0.9,
      );
      expect(stale.decision, ProveDecision.invalid);
      expect(stale.reason, 'unknown-pkS');
      expect(
          stale.verifyAck(
            profPk: prof.publicKey,
            sessionId: desc2.sessionId,
            windowId: desc2.windowId,
            j: 0,
            studentId: _email,
          ),
          isTrue,
          reason: 'early invalids must verify — never BAD-sig');
      expect(proved.last, contains('pin-mismatch'));
      // 3) Forced re-pin (what the professor's per-window prefetch now
      // does): the fresh directory key converges instead of refusing for
      // the rest of the session. New window (new single-use scope), same
      // student key — marks normally.
      server.pinStudentKeys({_email: hexEncode(pk32(stu.publicKey))},
          force: true);
      server.openWindow(
        WindowParams(
          sessionId: server.window!.sessionId,
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc(),
          classLabel: 'CS201-Room301',
        ),
        2,
      );
      final cj3 = server.window!.challengeFor(0);
      final desc3 = await client.fetchWindow(cj3);
      final converged = await proveFresh(
        client,
        desc: desc3,
        cj: cj3,
        j: 0,
        stu: stu,
        email: _email,
        fd: fd,
        face: 0.9,
      );
      expect(converged.decision, ProveDecision.confirmed);
      expect(
          converged.verifyAck(
            profPk: prof.publicKey,
            sessionId: desc3.sessionId,
            windowId: desc3.windowId,
            j: 0,
            studentId: _email,
          ),
          isTrue);
      // 4) Closed window: unsigned by contract (nothing to bind), but the
      // shape still parses — the driver maps it pre-ACK-check.
      server.closeWindow();
      final closed = await proveFresh(
        client,
        desc: desc2,
        cj: cj2,
        j: 0,
        stu: stu,
        email: _email,
        fd: fd,
        face: 0.9,
      );
      expect(closed.decision, ProveDecision.invalid);
      expect(closed.reason, 'window-closed');
    } finally {
      client.close();
      await server.stop();
    }
  });

  Future<ProveResult> proveOnce(
    ProxClient client,
    WindowDescriptor desc,
    Uint8List cj,
    int j,
    ed.KeyPair stu, {
    double face = 0.85,
    required ({
      Uint8List pkD,
      BigInt d,
      List<String> chainHex,
      Uint8List rootDer,
    }) fd,
  }) =>
      proveFresh(
        client,
        desc: desc,
        cj: cj,
        j: j,
        stu: stu,
        email: _email,
        fd: fd,
        face: face,
      );

  test('late radio sighting still confirms within grace', () async {
    // The POST routinely beats the host BLE scan: a crypto-valid POST
    // with no sighting yet waits for the radio instead of instantly
    // failing (observed live: valid POST -> no-ble-sighting, response
    // heard 43ms later).
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
    RadioSighting? held;
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'CS201-Room301',
    );
    final server = ProxServer(
      classLabel: 'CS201-Room301',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) => held,
      pinnedRoots: [ProxCrypto.sha256Sync(fd.rootDer)],
    )
      ..sightingGrace = const Duration(seconds: 2)
      ..testChainGate = _fakeChainGate;
    await server.start(port: 0);
    server.openWindow(window, 1);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = window.challengeFor(window.jForTime(DateTime.now().toUtc()));
      final desc = await client.fetchWindow(cj);
      // The scan delivers the response a beat AFTER the POST lands.
      Future.delayed(const Duration(milliseconds: 800), () {
        held = const RadioSighting(rssiDbm: -55, hop: 0);
      });
      final res = await proveOnce(client, desc, cj, desc.jNow, stu, fd: fd);
      expect(res.decision, ProveDecision.confirmed);
      expect(server.tally.presentCount, 1);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('legacy unbound never confirms (liveness-unbound)', () async {
    // Fresh-only: a legacy (unbound, pre-liveness) body fails closed as
    // `liveness-unbound` — never a confirm. No opt-in exists.
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'CS201-Room301',
    );
    final server = ProxServer(
      classLabel: 'CS201-Room301',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) =>
          const RadioSighting(rssiDbm: -55, hop: 0),
    );
    await server.start(port: 0);
    server.openWindow(window, 1);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = window.challengeFor(window.jForTime(DateTime.now().toUtc()));
      final desc = await client.fetchWindow(cj);
      // Legacy-shaped body (6-field Sig_s, no ticket): kept only to pin
      // the closed verdict — production clients send fresh proofs.
      final peerW = ProxCrypto.peerAlias(pk32(stu.publicKey), desc.windowId);
      final res = await client.prove(
        desc: desc,
        studentId: _email,
        challenge: cj,
        j: desc.jNow,
        faceScore: 0.85,
        peerW: peerW,
        pkS: pk32(stu.publicKey),
        sigSFor: (c, j) => ProxCrypto.signStudentProve(
          studentSk: stu.privateKey,
          sessionId: desc.sessionId,
          windowId: desc.windowId,
          j: j,
          challenge: c,
          studentId: _email,
          faceScore: 0.85,
        ),
        sigBindFor: (fp, j) => ProxCrypto.sign(
            stu.privateKey,
            bindPreimage(
                sessionId: desc.sessionId,
                windowId: desc.windowId,
                j: j,
                tlsFingerprint: fp)),
      );
      expect(res.decision, ProveDecision.invalid);
      expect(res.reason, 'liveness-unbound');
      expect(server.tally.presentCount, 0);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('absent sighting still invalid after grace', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'CS201-Room301',
    );
    final server = ProxServer(
      classLabel: 'CS201-Room301',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) => null,
      pinnedRoots: [ProxCrypto.sha256Sync(fd.rootDer)],
    )
      ..sightingGrace = const Duration(milliseconds: 300)
      ..testChainGate = _fakeChainGate;
    await server.start(port: 0);
    server.openWindow(window, 1);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = window.challengeFor(window.jForTime(DateTime.now().toUtc()));
      final desc = await client.fetchWindow(cj);
      final res = await proveOnce(client, desc, cj, desc.jNow, stu, fd: fd);
      expect(res.decision, ProveDecision.invalid);
      expect(res.reason, 'no-ble-sighting');
      expect(server.tally.presentCount, 0);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('blackholed connects fail bounded (never an infinite hang)', () async {    // Enterprise WiFi drops SYNs without RST: without connect timeouts a
    // prove stalls mid-flow with zero log lines (observed live: "signs
    // but nothing proceeds"). Every connect is bounded; the driver
    // treats the timeout as transient and proves the next rotation.
    final client = ProxClient(host: '10.255.255.1', port: 8443);
    final sw = Stopwatch()..start();
    try {
      await expectLater(
          client.fetchWindow(Uint8List.fromList(List.filled(8, 1))),
          throwsA(anything));
    } finally {
      client.close();
    }
    expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
  });

  test('rotation-boundary token verifies via previous-signature fallback',
      () async {
    // The fetch can land one 5s tick after the hear: the radio copy is
    // C_0 but /window already signs C_1. The server ships sigP_prev, so
    // the boundary token verifies as j=0 (still fresh) instead of
    // failing the live round as "fake professor".
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final server = await makeServer(prof: prof, stu: stu);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      // Simulate the fetch landing one 10s tick after the hear: the radio
      // copy is C_0 but /window already signs C_1.
      server.openWindow(
        WindowParams(
          sessionId: server.window!.sessionId,
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc().subtract(const Duration(seconds: 11)),
          classLabel: 'CS201-Room301',
        ),
        1,
      );
      final w = server.window!;
      expect(w.jForTime(DateTime.now().toUtc()), 1);
      final descPrev = await client.fetchWindow(w.challengeFor(0));
      expect(descPrev.jNow, 0);
      // …while the live token verifies cleanly.
      final desc = await client.fetchWindow(w.challengeFor(1));
      expect(desc.jNow, 1);
      // A token from no live epoch is still rejected (fake professor?).
      await expectLater(
          client.fetchWindow(Uint8List.fromList(List.filled(8, 7))),
          throwsStateError);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('prove after a retake reports window-mismatch (driver retries)',
      () async {
    // Contract the student retry loop relies on: a proof built for round N
    // that lands after the professor retook round N must be distinguishable
    // from a verdict — invalid/window-mismatch, never a silent mark.
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final server = await makeServer(prof: prof, stu: stu);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final w1 = server.window!;
      final cj = w1.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      // Professor retakes the round before the POST lands.
      server.openWindow(
        WindowParams(
          sessionId: w1.sessionId,
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc(),
          classLabel: 'CS201-Room301',
        ),
        1,
      );
      final peerW = ProxCrypto.peerAlias(pk32(stu.publicKey), desc.windowId);
      const face = 0.9;
      final res = await client.prove(
        desc: desc,
        studentId: _email,
        challenge: cj,
        j: 0,
        faceScore: face,
        peerW: peerW,
        pkS: pk32(stu.publicKey),
        name: 'Student One',
        roll: '12342210',
        sigSFor: (c, j) => ProxCrypto.signStudentProve(
          studentSk: stu.privateKey,
          sessionId: desc.sessionId,
          windowId: desc.windowId,
          j: j,
          challenge: c,
          studentId: _email,
          faceScore: face,
        ),
        sigBindFor: (fp, j) => ProxCrypto.sign(
            stu.privateKey,
            bindPreimage(
                sessionId: desc.sessionId,
                windowId: desc.windowId,
                j: j,
                tlsFingerprint: fp)),
      );
      expect(res.decision, ProveDecision.invalid);
      expect(res.reason, 'window-mismatch');
      expect(server.tally.presentCount, 0);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('duplicate POST of a confirmed proof confirms (idempotent)', () async {
    // Flaky WiFi loses the ACK; the client's 3x retry then replays the
    // identical body. With the mark already tallied, the duplicate must
    // confirm — never fail a marked student as replay-id-j invalid.
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
    final server = await makeServer(
      prof: prof,
      stu: stu,
      pins: [ProxCrypto.sha256Sync(fd.rootDer)],
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      const face = 0.9;
      Future<ProveResult> once() => proveFresh(
            client,
            desc: desc,
            cj: cj,
            j: 0,
            stu: stu,
            email: _email,
            fd: fd,
            face: face,
          );
      final first = await once();
      expect(first.decision, ProveDecision.confirmed);
      final dup = await once();
      expect(dup.decision, ProveDecision.confirmed);
      expect(dup.reason, 'duplicate-confirmed');
      expect(server.tally.presentCount, 1);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('rosterless prove: presented key verifies, no roster needed', () async {
    // Offline-local phase: the server holds no roster at all. A student
    // presenting its device key confirms on radio + signatures alone —
    // whoever was present in class lands in the union, no enrollment sync.
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
    final server = ProxServer(
      classLabel: 'CS201-Room301',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: (
              {required peerW,
              required expectedAirKey,
              required expectedUuid}) =>
          const RadioSighting(rssiDbm: -55, hop: 0),
      pinnedRoots: [ProxCrypto.sha256Sync(fd.rootDer)],
      // ignore: cascade_invocations
    )..testChainGate = _fakeChainGate;
    await server.start(port: 0);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    Future<ProveResult> proveAt(int j) async {
      final cj = server.window!.challengeFor(j);
      final desc = await client.fetchWindow(cj);
      return proveFresh(
        client,
        desc: desc,
        cj: cj,
        j: j,
        stu: stu,
        email: _email,
        fd: fd,
      );
    }

    try {
      server.openWindow(
        WindowParams(
          sessionId: randBytes(16),
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc(),
          classLabel: 'CS201-Room301',
        ),
        1,
      );
      final first = await proveAt(0);
      expect(first.decision, ProveDecision.confirmed);
      expect(server.tally.presentCount, 1);
      // A forged key proves nothing: signatures must verify under pkS.
      // (Backdate the window so j_now == 1 and the fetch verifies.)
      server.openWindow(
        WindowParams(
          sessionId: server.window!.sessionId,
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc().subtract(const Duration(seconds: 11)),
          classLabel: 'CS201-Room301',
        ),
        2,
      );
      final evil = ProxCrypto.generateEdKeypair();
      final cj = server.window!.challengeFor(1);
      final desc = await client.fetchWindow(cj);
      final forged = await client.prove(
        desc: desc,
        studentId: _email,
        challenge: cj,
        j: 1,
        faceScore: 0.9,
        peerW: ProxCrypto.peerAlias(pk32(stu.publicKey), desc.windowId),
        pkS: pk32(stu.publicKey),
        sigSFor: (c, jj) => ProxCrypto.signStudentProve(
          studentSk: evil.privateKey,
          sessionId: desc.sessionId,
          windowId: desc.windowId,
          j: jj,
          challenge: c,
          studentId: _email,
          faceScore: 0.9,
        ),
        sigBindFor: (fp, jj) => ProxCrypto.sign(
            stu.privateKey,
            bindPreimage(
                sessionId: desc.sessionId,
                windowId: desc.windowId,
                j: jj,
                tlsFingerprint: fp)),
      );
      expect(forged.decision, ProveDecision.invalid);
      expect(forged.reason, 'bad-sig');
      expect(server.tally.presentCountAny, 1);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('evil-twin relay fails channel binding (tls-mismatch)', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final evil = ProxCrypto.generateEdKeypair();
    final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
    final server = await makeServer(
      prof: prof,
      stu: stu,
      pins: [ProxCrypto.sha256Sync(fd.rootDer)],
    );
    try {
      // Attacker runs their own server; student is tricked into binding the
      // ATTACKER's fingerprint, but the POST goes to the real professor.
      // The body is an otherwise fully-valid fresh proof (bound ticket +
      // liveness + FULL + genuine dSig + chain) so the failure pins the
      // channel binding, not an earlier gate.
      final evilServer = await makeServer(prof: evil, stu: stu);
      final evilFp = evilServer.tls.fingerprint;
      await evilServer.stop();

      final cj = server.window!.challengeFor(0);
      final raw = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      final req = await raw.postUrl(Uri(
          scheme: 'https',
          host: '127.0.0.1',
          port: server.port,
          path: '/prove'));
      req.headers.contentType = ContentType.json;
      const face = 0.9;
      final peerW =
          ProxCrypto.peerAlias(pk32(stu.publicKey), server.window!.windowId);
      final stampMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final pkS = pk32(stu.publicKey);
      final ticket = ProxCrypto.faceTicketHash(
        faceScore: face,
        faceValidAtMs: stampMs,
        verifierVer: _freshVerifierVer,
        livenessScore: 0.92,
        livenessVer: _freshLiveVer,
      );
      final dSig = _freshP256Sign(
          fd.d,
          ProxCrypto.deviceProvePreimage(
            sessionId: server.window!.sessionId,
            windowId: server.window!.windowId,
            j: 0,
            challenge: cj,
            faceTicketHashBytes: ticket,
            pkS: pkS,
            integrityHash: '00000000',
          ));
      req.write(jsonEncode(buildProveBody(
        id: _email,
        windowId: server.window!.windowId,
        j: 0,
        challenge: cj,
        sigS: ProxCrypto.signStudentProve(
          studentSk: stu.privateKey,
          sessionId: server.window!.sessionId,
          windowId: server.window!.windowId,
          j: 0,
          challenge: cj,
          studentId: _email,
          faceScore: face,
          faceValidAtMs: stampMs,
          verifierVer: _freshVerifierVer,
          pkD: fd.pkD,
          livenessScore: 0.92,
          livenessVer: _freshLiveVer,
        ),
        faceScore: face,
        peerW: peerW,
        pkS: pkS,
        tlsFp: evilFp, // what the victim saw through the relay
        sigBind: ProxCrypto.sign(
            stu.privateKey,
            bindPreimage(
                sessionId: server.window!.sessionId,
                windowId: server.window!.windowId,
                j: 0,
                tlsFingerprint: evilFp)),
        faceValidAtMs: stampMs,
        verifierVer: _freshVerifierVer,
        pkD: fd.pkD,
        dSig: dSig,
        attestationLevel: 'FULL',
        attestedUntilMs: DateTime.now()
            .toUtc()
            .add(kDeviceAttestedValidity)
            .millisecondsSinceEpoch,
        livenessScore: 0.92,
        livenessVer: _freshLiveVer,
        integrityHash: '00000000',
        attestationChain: fd.chainHex,
        installId: _freshInstallId,
      )));
      final resp = await req.close();
      final body =
          jsonDecode(await resp.transform(utf8.decoder).join()) as Map;
      expect(body['decision'], 'invalid');
      expect(body['reason'], 'tls-mismatch');
      raw.close();
    } finally {
      await server.stop();
    }
  });

  test('duplicate POST confirms without double-mark; rate-limit + bearer hold',
      () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
    final server = await makeServer(
      prof: prof,
      stu: stu,
      pins: [ProxCrypto.sha256Sync(fd.rootDer)],
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      const face = 0.9;
      Future<ProveResult> once() => proveFresh(
            client,
            desc: desc,
            cj: cj,
            j: 0,
            stu: stu,
            email: _email,
            fd: fd,
            face: face,
          );
      expect((await once()).decision, ProveDecision.confirmed);
      // Identical retry (lost ACK on flaky WiFi): confirms idempotently —
      // never fails a marked student, never marks twice.
      final replay = await once();
      expect(replay.decision, ProveDecision.confirmed);
      expect(replay.reason, 'duplicate-confirmed');
      expect(server.tally.presentCount, 1);
      // Genuine replay (never marked): current-j bad-sig attempt, then
      // its replay — still rejected, still unmarked. (j is the live
      // sub-epoch: future-j proofs verdict `late`, never `bad-sig`.)
      server.openWindow(
        WindowParams(
          sessionId: server.window!.sessionId,
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc(),
          classLabel: 'CS201-Room301',
        ),
        2,
      );
      final cj0 = server.window!.challengeFor(0);
      final desc2 = await client.fetchWindow(cj0);
      final peerW2 =
          ProxCrypto.peerAlias(pk32(stu.publicKey), desc2.windowId);
      Future<ProveResult> badOnce() => client.prove(
            desc: desc2,
            studentId: _email,
            challenge: cj0,
            j: 0,
            faceScore: 0.9,
            peerW: peerW2,
            pkS: pk32(stu.publicKey),
            sigSFor: (c, j) => Uint8List(64),
            sigBindFor: (fp, j) => ProxCrypto.sign(
                stu.privateKey,
                bindPreimage(
                    sessionId: desc2.sessionId,
                    windowId: desc2.windowId,
                    j: j,
                    tlsFingerprint: fp)),
          );
      final bad = await badOnce();
      expect(bad.decision, ProveDecision.invalid);
      final badReplay = await badOnce();
      expect(badReplay.decision, ProveDecision.invalid);
      expect(badReplay.reason, 'replay-id-j');
      expect(server.tally.presentCount, 1);

      // /window allows 5/10s/IP: hammer it.
      var limited = false;
      for (var i = 0; i < 8; i++) {
        try {
          await client.fetchWindow(cj);
        } catch (_) {
          limited = true;
          break;
        }
      }
      expect(limited, isTrue);

      // Bearer: live/export need host token.
      final raw = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      Future<int> get(String p, [String? token]) async {
        final r = await raw.getUrl(Uri(
            scheme: 'https',
            host: '127.0.0.1',
            port: server.port,
            path: p,
            queryParameters:
                token == null ? null : {'token': token}));
        final resp = await r.close();
        await resp.transform(utf8.decoder).join();
        return resp.statusCode;
      }

      expect(await get('/live', 'wrong'), 403);
      expect(await get('/live', server.bearer), 200);
      expect(await get('/export', server.bearer), 200);
      raw.close();
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('new window resets single-use: same (ID,j) provable again', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
    final server = await makeServer(
      prof: prof,
      stu: stu,
      pins: [ProxCrypto.sha256Sync(fd.rootDer)],
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    Future<ProveResult> proveOnce(int j) async {
      final cj = server.window!.challengeFor(j);
      final desc = await client.fetchWindow(cj);
      return proveFresh(
        client,
        desc: desc,
        cj: cj,
        j: j,
        stu: stu,
        email: _email,
        fd: fd,
      );
    }

    try {
      expect((await proveOnce(0)).decision, ProveDecision.confirmed);
      // Fresh window (#2, or a retaken round): the same sub-epoch must not
      // be mistaken for a replay of the previous window.
      server.openWindow(
        WindowParams(
          sessionId: server.window!.sessionId,
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc(),
          classLabel: 'CS201-Room301',
        ),
        2,
      );
      expect((await proveOnce(0)).decision, ProveDecision.confirmed);
      expect(server.tally.presentCount, 1);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('waiting room: presence registers + probe sees open/closed', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final server = await makeServer(prof: prof, stu: stu);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      var probe = await client.probeWindow();
      expect(probe.reachable, isTrue);
      expect(probe.windowOpen, isTrue);
      await client.postWaiting(
          email: _email, name: 'Student One', roll: '12342210');
      expect(server.waitingCount, 1);
      expect(server.waitingRows.single.email, _email);
      server.closeWindow();
      probe = await client.probeWindow();
      expect(probe.reachable, isTrue);
      expect(probe.windowOpen, isFalse);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('waiting room: explicit leave drops the count', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final server = await makeServer(prof: prof, stu: stu);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final join1 = await client.postWaiting(
          email: _email, name: 'Student One', roll: '12342210');
      expect(join1.leaveToken.isNotEmpty, isTrue);
      await client.postWaiting(
          email: 'student2@example.com', name: 'Student Two');
      expect(server.waitingCount, 2);
      await client.postLeave(email: _email, leaveToken: join1.leaveToken);
      expect(server.waitingCount, 1);
      expect(server.waitingRows.single.email, 'student2@example.com');
      // Replayed token after removal is forbidden (no oracle, no error
      // out — the client swallows it; the count is unchanged).
      await client.postLeave(email: _email, leaveToken: join1.leaveToken);
      // Unknown email without a token is forbidden, never an error out.
      await client.postLeave(email: 'ghost@institute.ac.in');
      expect(server.waitingCount, 1);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('waiting room: no-auth bulk ejection is closed (leaveToken)', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final server = await makeServer(prof: prof, stu: stu);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final victim = await client.postWaiting(
          email: _email, name: 'Student One', roll: '12342210');
      expect(server.waitingCount, 1);
      // Attacker without the token: tokenless, wrong, and cross-email
      // tokens all fail — the victim stays waiting.
      await client.postLeave(email: _email);
      await client.postLeave(email: _email, leaveToken: 'deadbeef' * 8);
      final attacker = await client.postWaiting(
          email: 'attacker@example.com', name: 'Attacker');
      await client.postLeave(
          email: _email, leaveToken: attacker.leaveToken);
      expect(server.waitingCount, 2);
      expect(
          server.waitingRows.map((w) => w.email), contains(_email));
      // The victim's own token still works (honest leave unchanged).
      await client.postLeave(email: _email, leaveToken: victim.leaveToken);
      expect(server.waitingCount, 1);
      expect(
          server.waitingRows.map((w) => w.email), isNot(contains(_email)));
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('manual attendance: request -> pending -> approve marks + status',
      () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final server = await makeServer(prof: prof, stu: stu);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      await client.postManualRequest(
          email: 'student2@example.com', name: 'Student Two', roll: '12342211');
      expect(server.manualPending.length, 1);
      expect(await client.fetchManualStatus('student2@example.com'), 'pending');
      expect(server.decideManual('student2@example.com', true), isTrue);
      expect(await client.fetchManualStatus('student2@example.com'),
          'approved');
      expect(server.tally.confirmedCount, 1);
      await client.postManualRequest(
          email: 'late@institute.ac.in', name: 'Late L');
      expect(server.decideManual('late@institute.ac.in', false), isTrue);
      expect(await client.fetchManualStatus('late@institute.ac.in'),
          'rejected');
      expect(server.tally.confirmedCount, 1);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('open window has no clock expiry; guarded endpoints need bearer',
      () async {
    // A window opened minutes ago still serves + verifies (rotation is
    // unbounded — only closeWindow ends acceptance). Host-only endpoints
    // still need the bearer.
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final server = await makeServer(prof: prof, stu: stu);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      server.openWindow(
        WindowParams(
          sessionId: server.window!.sessionId,
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc().subtract(const Duration(minutes: 3)),
          classLabel: 'CS201-Room301',
        ),
        1,
      );
      final w = server.window!;
      final j = w.jForTime(DateTime.now().toUtc());
      expect(j, greaterThan(15)); // 3min at 10s rotation; unbounded anyway
      expect(w.isFresh(j, DateTime.now().toUtc()), isTrue);
      final desc = await client.fetchWindow(w.challengeFor(j));
      expect(desc.jNow, j);
    } finally {
      client.close();
    }
    final raw = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    try {
      Future<int> get(String p, [String? token]) async {
        final r = await raw.getUrl(Uri(
            scheme: 'https',
            host: '127.0.0.1',
            port: server.port,
            path: p,
            queryParameters: token == null ? null : {'token': token}));
        final resp = await r.close();
        await resp.transform(utf8.decoder).join();
        return resp.statusCode;
      }

      expect(await get('/live', 'wrong'), 403);
      expect(await get('/live', server.bearer), 200);
      expect(await get('/extend', server.bearer), 404);
    } finally {
      raw.close();
      await server.stop();
    }
  });

  group('session-hardening regressions', () {
    Future<ProveResult> proveAs(
      ProxClient client, {
      required WindowDescriptor desc,
      required ed.KeyPair stu,
      required Uint8List challenge,
      required int j,
      required ({
        Uint8List pkD,
        BigInt d,
        List<String> chainHex,
        Uint8List rootDer,
      }) fd,
      double faceScore = 0.9,
    }) =>
        proveFresh(
          client,
          desc: desc,
          cj: challenge,
          j: j,
          stu: stu,
          email: _email,
          fd: fd,
          face: faceScore,
        );

    test('retake: same (ID,j) provable again under a new windowId', () async {
      // The single-use scope is (windowId, ID, j): a stale-window POST
      // that fails window-mismatch must not burn the new window's slot.
      final prof = ProxCrypto.generateEdKeypair();
      final stu = ProxCrypto.generateEdKeypair();
      final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
      final server = await makeServer(
        prof: prof,
        stu: stu,
        pins: [ProxCrypto.sha256Sync(fd.rootDer)],
      );
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj1 = server.window!.challengeFor(0);
        final desc1 = await client.fetchWindow(cj1);
        expect(
            (await proveAs(client,
                    desc: desc1, stu: stu, challenge: cj1, j: 0, fd: fd))
                .decision,
            ProveDecision.confirmed);
        // Retake: fresh windowId, same j.
        server.openWindow(
          WindowParams(
            sessionId: server.window!.sessionId,
            windowId: randBytes(6),
            secret: randBytes(32),
            t0: DateTime.now().toUtc(),
            classLabel: 'CS201-Room301',
          ),
          2,
        );
        final cj2 = server.window!.challengeFor(0);
        final desc2 = await client.fetchWindow(cj2);
        final r2 = await proveAs(client,
            desc: desc2, stu: stu, challenge: cj2, j: 0, fd: fd);
        expect(r2.decision, ProveDecision.confirmed);
        expect(r2.reason, isNot('replay-id-j'));
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('late verdict marks the round (flagged), never vanishes', () async {
      // Crypto-valid but aged past freshness (grace wait outlived it):
      // the student WAS there — the round keeps its mark.
      final prof = ProxCrypto.generateEdKeypair();
      final stu = ProxCrypto.generateEdKeypair();
      final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
      final server = await makeServer(
        prof: prof,
        stu: stu,
        pins: [ProxCrypto.sha256Sync(fd.rootDer)],
      );
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        server.openWindow(
          WindowParams(
            sessionId: server.window!.sessionId,
            windowId: randBytes(6),
            secret: randBytes(32),
            t0: DateTime.now()
                .toUtc()
                .subtract(const Duration(seconds: 60)),
            classLabel: 'CS201-Room301',
          ),
          1,
        );
        final w = server.window!;
        // j=0 aired a minute ago: fetch still serves it (j_now is large,
        // sigP_prev only covers j_now-1) — so build the descriptor by
        // hand and prove the aged token directly.
        final cj0 = w.challengeFor(0);
        final desc = WindowDescriptor(
          classLabel: w.classLabel,
          sessionId: w.sessionId,
          windowId: w.windowId,
          jNow: 0,
          profPk: prof.publicKey,
          sigP: ProxCrypto.signProfChallenge(
            profSk: prof.privateKey,
            sessionId: w.sessionId,
            windowId: w.windowId,
            j: 0,
            challenge: cj0,
          ),
          tlsFp: Uint8List.fromList(List.filled(32, 0)),
          display: w.displayCode,
        );
        // Swap in the real TLS fingerprint so binding passes.
        final live = await client.fetchWindow(w.challengeFor(w.jForTime(DateTime.now().toUtc())));
        final descLive = WindowDescriptor(
          classLabel: desc.classLabel,
          sessionId: desc.sessionId,
          windowId: desc.windowId,
          jNow: 0,
          profPk: desc.profPk,
          sigP: desc.sigP,
          tlsFp: live.tlsFp,
          display: desc.display,
        );
        final r = await proveAs(client,
            desc: descLive, stu: stu, challenge: cj0, j: 0, fd: fd);
        expect(r.decision, ProveDecision.late);
        expect(server.tally.windowNos, contains(1));
        expect(server.tally.lateList.map((e) => e.email),
            contains(_email));
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('closed empty rounds persist in history snapshots', () async {
      final prof = ProxCrypto.generateEdKeypair();
      final stu = ProxCrypto.generateEdKeypair();
      final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
      final server = await makeServer(
        prof: prof,
        stu: stu,
        pins: [ProxCrypto.sha256Sync(fd.rootDer)],
      );
      try {
        // Round 1 marked, round 2 opened and closed empty, round 3 live.
        final cj = server.window!.challengeFor(0);
        final client = ProxClient(host: '127.0.0.1', port: server.port);
        final desc = await client.fetchWindow(cj);
        await proveAs(client, desc: desc, stu: stu, challenge: cj, j: 0, fd: fd);
        client.close();
        server.openWindow(
          WindowParams(
            sessionId: server.window!.sessionId,
            windowId: randBytes(6),
            secret: randBytes(32),
            t0: DateTime.now().toUtc(),
            classLabel: 'CS201-Room301',
          ),
          2,
        );
        server.closeWindow();
        expect(server.tally.windowNos, [1, 2]);
        final rec = server.tally.toClassRecord(
            courseId: 'CS201',
            classLabel: 'CS201-Room301',
            dateIso: '2026-09-06');
        expect(rec.windows.length, 2);
      } finally {
        await server.stop();
      }
    });

    test('ACK binds decision+time+student: tampering fails verify', () async {
      final prof = ProxCrypto.generateEdKeypair();
      final stu = ProxCrypto.generateEdKeypair();
      final fd = freshDevice(email: _email, pkS: pk32(stu.publicKey));
      final server = await makeServer(
        prof: prof,
        stu: stu,
        pins: [ProxCrypto.sha256Sync(fd.rootDer)],
      );
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await client.fetchWindow(cj);
        final res = await proveAs(client,
            desc: desc, stu: stu, challenge: cj, j: 0, fd: fd);
        expect(res.decision, ProveDecision.confirmed);
        // Flipped decision with the same signature: rejected.
        final flipped = ProveResult(
          decision: ProveDecision.late,
          reason: res.reason,
          serverTime: res.serverTime,
          sigAck: res.sigAck,
        );
        expect(
            flipped.verifyAck(
              profPk: prof.publicKey,
              sessionId: desc.sessionId,
              windowId: desc.windowId,
              j: 0,
              studentId: _email,
            ),
            isFalse);
        // Wrong professor key: rejected.
        final evil = ProxCrypto.generateEdKeypair();
        expect(
            res.verifyAck(
              profPk: evil.publicKey,
              sessionId: desc.sessionId,
              windowId: desc.windowId,
              j: 0,
              studentId: _email,
            ),
            isFalse);
      } finally {
        client.close();
        await server.stop();
      }
    });
  });

  group('local same-face dup path (RAM-only, window-scoped)', () {
    List<double> tvec(int seed) {
      final rng = math.Random(seed);
      final v = List<double>.generate(
          kFacePrintDim, (_) => rng.nextDouble() * 2 - 1);
      var n = 0.0;
      for (final x in v) {
        n += x * x;
      }
      n = math.sqrt(n);
      return [for (final x in v) x / n];
    }


    Future<ProveResult> proveAs(
      ProxClient client,
      WindowDescriptor desc,
      Uint8List cj, {
      required ed.KeyPair key,
      required String email,
      required ({
        Uint8List pkD,
        BigInt d,
        List<String> chainHex,
        Uint8List rootDer,
      }) fd,
      String vec = '',
      String verifierVer = _freshVerifierVer,
      int? faceValidAtMs,
      // Liveness ticket (score >= Tl + allowlisted ver) — always required.
      double livenessScore = 0.92,
      String livenessVer = _freshLiveVer,
      String installId = _freshInstallId,
    }) {
      final pkS = pk32(key.publicKey);
      final stampMs =
          faceValidAtMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
      return client.prove(
        desc: desc,
        studentId: email,
        challenge: cj,
        j: 0,
        faceScore: 0.9,
        peerW: ProxCrypto.peerAlias(pkS, desc.windowId),
        pkS: pkS,
        name: email,
        sigSFor: (c, j) => ProxCrypto.signStudentProve(
          studentSk: key.privateKey,
          sessionId: desc.sessionId,
          windowId: desc.windowId,
          j: j,
          challenge: c,
          studentId: email,
          faceScore: 0.9,
          faceValidAtMs: stampMs,
          verifierVer: verifierVer,
          pkD: fd.pkD,
          livenessScore: livenessScore,
          livenessVer: livenessVer,
        ),
        sigBindFor: (fp, j) => ProxCrypto.sign(
            key.privateKey,
            bindPreimage(
                sessionId: desc.sessionId,
                windowId: desc.windowId,
                j: j,
                tlsFingerprint: fp)),
        faceVecB64: vec,
        verifierVer: verifierVer,
        faceValidAtMs: stampMs,
        pkD: fd.pkD,
        dSigFor: (ticket, j, h) async => _freshP256Sign(
            fd.d,
            ProxCrypto.deviceProvePreimage(
              sessionId: desc.sessionId,
              windowId: desc.windowId,
              j: j,
              challenge: cj,
              faceTicketHashBytes: ticket,
              pkS: pkS,
              integrityHash: h,
            )),
        integrityHash: '00000000',
        attestationLevel: 'FULL',
        attestedUntilMs: DateTime.now()
            .toUtc()
            .add(kDeviceAttestedValidity)
            .millisecondsSinceEpoch,
        livenessScore: livenessScore,
        livenessVer: livenessVer,
        attestationChain: fd.chainHex,
        installId: installId,
      );
    }

    test('pair flags on second prove; both marked; wire verdict clean',
        () async {
      final prof = ProxCrypto.generateEdKeypair();
      final ka = ProxCrypto.generateEdKeypair();
      final kb = ProxCrypto.generateEdKeypair();
      final log = <String>[];
      final fda = freshDevice(email: 'a@x.in', pkS: pk32(ka.publicKey));
      final fdb = freshDevice(
          email: 'b@x.in', pkS: pk32(kb.publicKey), salt: 11);
      final server = await makeServer(
        prof: prof,
        stu: ka,
        onProve: (e, d, r) => log.add('$e $d $r'),
        pins: [
          ProxCrypto.sha256Sync(fda.rootDer),
          ProxCrypto.sha256Sync(fdb.rootDer)
        ],
      );
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await client.fetchWindow(cj);
        final vec = faceVecEncode(tvec(5));
        final ra = await proveAs(client, desc, cj,
            key: ka, email: 'a@x.in', vec: vec, fd: fda);
        expect(ra.decision, ProveDecision.confirmed);
        expect(ra.reason, isNot(contains('dupface')));
        expect(server.faceVectorCount, 1);
        final rb = await proveAs(client, desc, cj,
            key: kb, email: 'b@x.in', vec: vec, fd: fdb);
        expect(rb.decision, ProveDecision.confirmed);
        // Wire verdict carries no trace; the host log line carries peers.
        expect(rb.reason, isNot(contains('dupface')));
        expect(rb.flags.any((f) => f.contains('dupface')), isFalse);
        expect(
            log.any((l) =>
                l.startsWith('b@x.in confirmed ') &&
                l.contains('dupface:a@x.in')),
            isTrue);
        // BOTH entries marked (never auto-absent).
        expect(server.tally.isMarked('a@x.in', 1), isTrue);
        expect(server.tally.isMarked('b@x.in', 1), isTrue);
        expect(server.faceVectorCount, 2);
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('triple: newcomer matching two plants flags both', () async {
      final prof = ProxCrypto.generateEdKeypair();
      final keys = [
        for (var i = 0; i < 3; i++) ProxCrypto.generateEdKeypair()
      ];
      final log = <String>[];
      final fds = [
        for (var i = 0; i < 3; i++)
          freshDevice(
              email: '${'abc'[i]}@x.in',
              pkS: pk32(keys[i].publicKey),
              salt: 20 + i),
      ];
      final server = await makeServer(
        prof: prof,
        stu: keys[0],
        onProve: (e, d, r) => log.add('$e|$d|$r'),
        pins: [for (final fd in fds) ProxCrypto.sha256Sync(fd.rootDer)],
      );
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await client.fetchWindow(cj);
        // All three carry the same holder vector (A/B/C group): the
        // newcomer's token must name BOTH earlier provers.
        final vec = faceVecEncode(tvec(5));
        await proveAs(client, desc, cj,
            key: keys[0], email: 'a@x.in', vec: vec, fd: fds[0]);
        await proveAs(client, desc, cj,
            key: keys[1], email: 'b@x.in', vec: vec, fd: fds[1]);
        final rc = await proveAs(client, desc, cj,
            key: keys[2], email: 'c@x.in', vec: vec, fd: fds[2]);
        expect(rc.decision, ProveDecision.confirmed);
        final line =
            log.firstWhere((l) => l.startsWith('c@x.in|confirmed|'));
        expect(line, contains('dupface:'));
        expect(line, contains('a@x.in'));
        expect(line, contains('b@x.in'));
        // And b's earlier token named only a (incremental pairing).
        final lineB =
            log.firstWhere((l) => l.startsWith('b@x.in|confirmed|'));
        expect(lineB, contains('dupface:a@x.in'));
        expect(lineB, isNot(contains('c@x.in')));
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('strangers, legacy-no-vec, garbage-vec: mark, no token', () async {
      final prof = ProxCrypto.generateEdKeypair();
      final ka = ProxCrypto.generateEdKeypair();
      final kb = ProxCrypto.generateEdKeypair();
      final kc = ProxCrypto.generateEdKeypair();
      final kd = ProxCrypto.generateEdKeypair();
      final log = <String>[];
      final fds = {
        'a@x.in': freshDevice(email: 'a@x.in', pkS: pk32(ka.publicKey), salt: 31),
        'b@x.in': freshDevice(email: 'b@x.in', pkS: pk32(kb.publicKey), salt: 32),
        'c@x.in': freshDevice(email: 'c@x.in', pkS: pk32(kc.publicKey), salt: 33),
        'd@x.in': freshDevice(email: 'd@x.in', pkS: pk32(kd.publicKey), salt: 34),
      };
      final server = await makeServer(
        prof: prof,
        stu: ka,
        onProve: (e, d, r) => log.add('$e|$d|$r'),
        pins: [for (final fd in fds.values) ProxCrypto.sha256Sync(fd.rootDer)],
      );
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await client.fetchWindow(cj);
        await proveAs(client, desc, cj,
            key: ka, email: 'a@x.in', vec: faceVecEncode(tvec(5)), fd: fds['a@x.in']!);
        final rb = await proveAs(client, desc, cj,
            key: kb, email: 'b@x.in', vec: faceVecEncode(tvec(6)), fd: fds['b@x.in']!);
        expect(rb.decision, ProveDecision.confirmed);
        expect(log.any((l) => l.contains('dupface')), isFalse);
        // No vector at all: marks, plants nothing.
        final rc = await proveAs(client, desc, cj,
            key: kc, email: 'c@x.in', fd: fds['c@x.in']!);
        expect(rc.decision, ProveDecision.confirmed);
        expect(server.faceVectorCount, 2);
        // Garbage vector: marks normally, plants nothing.
        final rd = await proveAs(client, desc, cj,
            key: kd, email: 'd@x.in', vec: '!!!not-base64!!!', fd: fds['d@x.in']!);
        expect(rd.decision, ProveDecision.confirmed);
        expect(server.faceVectorCount, 2);
        expect(log.any((l) => l.contains('dupface')), isFalse);
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('invalid proofs plant nothing; retry never self-flags', () async {
      final prof = ProxCrypto.generateEdKeypair();
      final stu = ProxCrypto.generateEdKeypair();
      final evil = ProxCrypto.generateEdKeypair();
      final log = <String>[];
      final fd = freshDevice(
          email: 'genuine@x.in', pkS: pk32(stu.publicKey), salt: 41);
      final server = await makeServer(
        prof: prof,
        stu: stu,
        onProve: (e, d, r) => log.add('$e|$d|$r'),
        pins: [ProxCrypto.sha256Sync(fd.rootDer)],
      );
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await client.fetchWindow(cj);
        final vec = faceVecEncode(tvec(5));
        // Forged Sig_s with a vector attached: invalid, plants nothing.
        final forged = await client.prove(
          desc: desc,
          studentId: _email,
          challenge: cj,
          j: 0,
          faceScore: 0.9,
          peerW: ProxCrypto.peerAlias(pk32(stu.publicKey), desc.windowId),
          pkS: pk32(stu.publicKey),
          sigSFor: (c, jj) => ProxCrypto.signStudentProve(
            studentSk: evil.privateKey,
            sessionId: desc.sessionId,
            windowId: desc.windowId,
            j: jj,
            challenge: c,
            studentId: _email,
            faceScore: 0.9,
          ),
          sigBindFor: (fp, jj) => ProxCrypto.sign(
              stu.privateKey,
              bindPreimage(
                  sessionId: desc.sessionId,
                  windowId: desc.windowId,
                  j: jj,
                  tlsFingerprint: fp)),
          faceVecB64: vec,
        );
        expect(forged.decision, ProveDecision.invalid);
        expect(server.faceVectorCount, 0);
        // Genuine prove as a DIFFERENT id (the forged attempt burned this
        // ID's single-use slot for j=0): no ghost to match.
        final ok = await proveAs(client, desc, cj,
            key: stu, email: 'genuine@x.in', vec: vec, fd: fd);
        expect(ok.decision, ProveDecision.confirmed);
        expect(log.any((l) => l.contains('dupface')), isFalse);
        // Identical retry (lost ACK): duplicate-confirmed, still no token.
        final retry = await proveAs(client, desc, cj,
            key: stu, email: 'genuine@x.in', vec: vec, fd: fd);
        expect(retry.decision, ProveDecision.confirmed);
        expect(log.any((l) => l.contains('dupface')), isFalse);
        expect(server.faceVectorCount, 1);
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('cross-pipeline vectors never compare', () async {
      final prof = ProxCrypto.generateEdKeypair();
      final ka = ProxCrypto.generateEdKeypair();
      final kb = ProxCrypto.generateEdKeypair();
      final log = <String>[];
      // Fresh FULL proofs (per-key test devices): the dup path is the
      // behavior under test — device trust is real, not bypassed.
      final fda = freshDevice(email: 'a@x.in', pkS: pk32(ka.publicKey), salt: 51);
      final fdb = freshDevice(email: 'b@x.in', pkS: pk32(kb.publicKey), salt: 52);
      final server = await makeServer(
        prof: prof,
        stu: ka,
        onProve: (e, d, r) => log.add('$e|$d|$r'),
        pins: [
          ProxCrypto.sha256Sync(fda.rootDer),
          ProxCrypto.sha256Sync(fdb.rootDer)
        ],
      );
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await client.fetchWindow(cj);
        final vec = faceVecEncode(tvec(5));
        // Same BYTES, different pipeline tags (both allowlisted, mutually
        // incomparable) → no token, both plant.
        // Bound signatures (explicit fresh stamp, matching ticket +
        // liveness ticket, allowlisted ver).
        final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
        await proveAs(client, desc, cj,
            key: ka,
            email: 'a@x.in',
            vec: vec,
            fd: fda,
            verifierVer: 'face_verification/pipe-A',
            faceValidAtMs: stamp,
            livenessScore: 0.9,
            livenessVer: 'liveness/test-pipe+a1b2c3d4');
        final rb = await proveAs(client, desc, cj,
            key: kb,
            email: 'b@x.in',
            vec: vec,
            fd: fdb,
            verifierVer: 'face_verification/pipe-B',
            faceValidAtMs: stamp,
            livenessScore: 0.9,
            livenessVer: 'liveness/test-pipe+a1b2c3d4');
        expect(rb.decision, ProveDecision.confirmed);
        expect(log.any((l) => l.contains('dupface')), isFalse);
        expect(server.faceVectorCount, 2);
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('wipe: closeWindow + openWindow drop vectors; exempt survives retake',
        () async {
      final prof = ProxCrypto.generateEdKeypair();
      final ka = ProxCrypto.generateEdKeypair();
      final kb = ProxCrypto.generateEdKeypair();
      final log = <String>[];
      final fda = freshDevice(email: 'a@x.in', pkS: pk32(ka.publicKey), salt: 61);
      final fdb = freshDevice(email: 'b@x.in', pkS: pk32(kb.publicKey), salt: 62);
      final server = await makeServer(
        prof: prof,
        stu: ka,
        onProve: (e, d, r) => log.add('$e|$d|$r'),
        pins: [
          ProxCrypto.sha256Sync(fda.rootDer),
          ProxCrypto.sha256Sync(fdb.rootDer)
        ],
      );
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final vec = faceVecEncode(tvec(5));
        Future<ProveResult> proveBoth() async {
          final cj = server.window!.challengeFor(0);
          final desc = await client.fetchWindow(cj);
          await proveAs(client, desc, cj,
              key: ka, email: 'a@x.in', vec: vec, fd: fda);
          return proveAs(client, desc, cj,
              key: kb, email: 'b@x.in', vec: vec, fd: fdb);
        }

        expect((await proveBoth()).decision, ProveDecision.confirmed);
        expect(log.any((l) => l.contains('dupface:a@x.in')), isTrue);
        expect(server.faceVectorCount, 2);
        // Window close wipes: reopened window compares against nothing.
        log.clear();
        server.closeWindow();
        expect(server.faceVectorCount, 0);
        server.openWindow(
            WindowParams(
              sessionId: randBytes(16),
              windowId: randBytes(6),
              secret: randBytes(32),
              t0: DateTime.now().toUtc(),
              classLabel: 'CS201-Room301',
            ),
            2);
        expect((await proveBoth()).decision, ProveDecision.confirmed);
        expect(log.any((l) => l.contains('dupface:a@x.in')), isTrue);
        // Professor exempts the pair; next retake stays quiet (exempt is
        // session-scoped, vectors are window-scoped).
        server.exemptFacePair('a@x.in', 'b@x.in');
        server.closeWindow();
        server.openWindow(
            WindowParams(
              sessionId: randBytes(16),
              windowId: randBytes(6),
              secret: randBytes(32),
              t0: DateTime.now().toUtc(),
              classLabel: 'CS201-Room301',
            ),
            3);
        log.clear();
        expect((await proveBoth()).decision, ProveDecision.confirmed);
        expect(log.any((l) => l.contains('dupface')), isFalse);
        // Explicit teardown wipe (hosting-end path calls this).
        server.clearFaceVectors();
        expect(server.faceVectorCount, 0);
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('per-prove compare cost is trivial (measured, not asserted)', () {
      // 500-entry session map, exact cosine over dequantized vectors —
      // the shape of one server-side compare at pilot scale.
      final mine = FacePrintDoc(
          org: '',
          verifierVer: 'v',
          embQ: faceVecEncode(tvec(5)),
          buckets: const [],
          updatedAtMillis: 0);
      final others = {
        for (var i = 0; i < 500; i++)
          'u$i@x.in': FacePrintDoc(
              org: '',
              verifierVer: 'v',
              embQ: faceVecEncode(tvec(1000 + i)),
              buckets: const [],
              updatedAtMillis: 0),
      };
      final sw = Stopwatch()..start();
      final hits = findFaceDuplicates(
          myEmail: 'me@x.in', mine: mine, others: others);
      sw.stop();
      expect(hits, isEmpty);
      // ignore: avoid_print
      print('dup-compare 1-vs-500: ${sw.elapsedMilliseconds}ms');
    });
  });
}
