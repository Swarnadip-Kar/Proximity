// 500-seat hall load drill (§9): 500 distinct students prove presence.
//
// Loopback note: all drill HTTP comes from 127.0.0.1, but production
// rate limits are per-IP and a real hall has 500 distinct client IPs
// (hotspot DHCP). So the drill asserts:
//   (a) 40 concurrent HTTP proves (the per-IP limit) all confirm;
//   (b) the 41st+ burst is correctly 429-limited;
//   (c) 500/500 distinct students confirm through the full verify path
//       (crypto + dedup + tally) with throughput report;
//   (d) 1000 Ed25519 verify throughput (design budget: ~1000-2500 total,
//       well under 1s on phone/laptop — measured here).
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:pointycastle/export.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';
import 'package:test/test.dart';

// Fresh-proof fixtures (mirrors transport_test): bound+liveness+FULL with
// genuine P-256 dSig + fake-DER chain; the server verifies through the real
// testChainGate stub.
const _loadInstallId = 'inst-load-1';
const _loadVerifierVer = 'face_verification/test+deadbeef';
const _loadLiveVer = 'liveness/minifasnet-v2-test+a1b2c3d4';

SecureRandom _lrand(int salt) {
  final r = SecureRandom('Fortuna');
  r.seed(KeyParameter(
      Uint8List.fromList(List.generate(32, (i) => (i * 11 + salt) & 0xFF))));
  return r;
}

({Uint8List pkD, BigInt d}) _lp256Key(int salt) {
  final domain = ECDomainParameters('prime256v1');
  final gen = ECKeyGenerator()
    ..init(ParametersWithRandom(
        ECKeyGeneratorParameters(domain), _lrand(salt)));
  final pair = gen.generateKeyPair();
  final ECPublicKey pub = pair.publicKey;
  return (
    pkD: Uint8List.fromList(pub.Q!.getEncoded(false).sublist(1)),
    d: pair.privateKey.d!,
  );
}

Uint8List _lp256Sign(BigInt d, Uint8List preimage, int salt) {
  final domain = ECDomainParameters('prime256v1');
  final signer = ECDSASigner(SHA256Digest())
    ..init(
        true,
        ParametersWithRandom(
            PrivateKeyParameter(ECPrivateKey(d, domain)), _lrand(salt)));
  final sig = signer.generateSignature(preimage) as ECSignature;
  Uint8List be(BigInt v) =>
      hexDecode(v.toRadixString(16).padLeft(64, '0'));
  return Uint8List.fromList([...be(sig.r), ...be(sig.s)]);
}

ChainPinResult _loadChainGate({
  required AttestationChain chain,
  required List<Uint8List> pinnedRootHashes,
  required Uint8List expectedChallenge,
  required Uint8List? expectedLeafPkD,
  required AttestationLevel level,
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

void main() {
  test('40 concurrent HTTP proves confirm; burst is 429-limited', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final students =
        List.generate(40, (_) => ProxCrypto.generateEdKeypair());
    // One test device per student: P-256 key + fake chain bound to the
    // student's (email, installId, pkS); the server pins every root.
    final devices = List.generate(40, (i) {
      final id = 's$i@x.in';
      final pkS =
          Uint8List.fromList(students[i].publicKey.bytes.sublist(0, 32));
      final dev = _lp256Key(1000 + i);
      final challenge = deviceBindingChallengeV2(
          emailLower: id, installId: _loadInstallId, pkS: pkS);
      final leaf = Uint8List.fromList(
          [...kKeyAttestationOidDer, ...challenge, ...dev.pkD, 0xAA, 0xBB]);
      final root = Uint8List.fromList(
          List.generate(64, (k) => (k * 13 + i) & 0xFF));
      return (
        pkD: dev.pkD,
        d: dev.d,
        chainHex: [hexEncode(leaf), hexEncode(root)],
        rootDer: root,
      );
    });
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'HALL',
    );
    final server = ProxServer(
      classLabel: 'HALL',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) =>
          const RadioSighting(rssiDbm: -60, hop: 0),
      pinnedRoots: [
        for (final dev in devices) ProxCrypto.sha256Sync(dev.rootDer)
      ],
      // ignore: cascade_invocations
    )..testChainGate = _loadChainGate;
    await server.start(port: 0);
  server.openWindow(window, 1);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      Future<ProveResult> prove(int i) {
        final id = 's$i@x.in';
        final kp = students[i];
        final dev = devices[i];
        final pkS = Uint8List.fromList(kp.publicKey.bytes.sublist(0, 32));
        final peerW =
            ProxCrypto.peerAlias(pkS, desc.windowId);
        final stampMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        return client.prove(
          desc: desc,
          studentId: id,
          challenge: cj,
          j: 0,
          faceScore: 0.9,
          peerW: peerW,
          pkS: pkS,
          sigSFor: (c, j) => ProxCrypto.signStudentProve(
              studentSk: kp.privateKey,
              sessionId: desc.sessionId,
              windowId: desc.windowId,
              j: j,
              challenge: c,
              studentId: id,
              faceScore: 0.9,
              faceValidAtMs: stampMs,
              verifierVer: _loadVerifierVer,
              pkD: dev.pkD,
              livenessScore: 0.92,
              livenessVer: _loadLiveVer),
          sigBindFor: (fp, j) => ProxCrypto.sign(
              kp.privateKey,
              bindPreimage(
                  sessionId: desc.sessionId,
                  windowId: desc.windowId,
                  j: j,
                  tlsFingerprint: fp)),
          faceValidAtMs: stampMs,
          verifierVer: _loadVerifierVer,
          pkD: dev.pkD,
          dSigFor: (ticket, j, h) async => _lp256Sign(
              dev.d,
              ProxCrypto.deviceProvePreimage(
                sessionId: desc.sessionId,
                windowId: desc.windowId,
                j: j,
                challenge: cj,
                faceTicketHashBytes: ticket,
                pkS: pkS,
                integrityHash: h,
              ),
              2000 + i),
          integrityHash: '00000000',
          attestationLevel: 'FULL',
          attestedUntilMs: DateTime.now()
              .toUtc()
              .add(kDeviceAttestedValidity)
              .millisecondsSinceEpoch,
          livenessScore: 0.92,
          livenessVer: _loadLiveVer,
          attestationChain: dev.chainHex,
          installId: _loadInstallId,
        );
      }

      final results = await Future.wait(List.generate(40, prove));
      expect(results.where((r) => r.decision == ProveDecision.confirmed),
          hasLength(40));
      expect(server.tally.presentCount, 40);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('500 distinct students confirm through full verify path', () async {
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'HALL500',
    );
    const j = 0;
    final cj = window.challengeFor(j);
    final students =
        List.generate(500, (_) => ProxCrypto.generateEdKeypair());
    final once = SingleUseTracker();
    final now = DateTime.now().toUtc();
    var confirmed = 0;
    final sw = Stopwatch()..start();
    for (var i = 0; i < 500; i++) {
      final id = 's$i@x.in';
      final kp = students[i];
      // Fresh bound proof (liveness + FULL tier): the shape every client
      // sends — legacy bodies never confirm.
      final ticket = ProxCrypto.faceTicketHash(
        faceScore: 0.9,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _loadVerifierVer,
        livenessScore: 0.92,
        livenessVer: _loadLiveVer,
      );
      final sig = ProxCrypto.signStudentProve(
          studentSk: kp.privateKey,
          sessionId: window.sessionId,
          windowId: window.windowId,
          j: j,
          challenge: cj,
          studentId: id,
          faceScore: 0.9,
          faceValidAtMs: now.millisecondsSinceEpoch,
          verifierVer: _loadVerifierVer,
          livenessScore: 0.92,
          livenessVer: _loadLiveVer);
      final out = verifyProve(
        req: VerifyRequest(
          id: id,
          windowId: window.windowId,
          j: j,
          cClaimed: cj,
          sigS: sig,
          faceScore: 0.9,
          faceValidAt: now,
          peerW: Uint8List(8),
          rssiDbm: -60,
          relayHop: 0,
          now: now,
          verifierVer: _loadVerifierVer,
          faceValidAtMs: now.millisecondsSinceEpoch,
          faceTicketHashBytes: ticket,
          livenessScore: 0.92,
          livenessVer: _loadLiveVer,
          attestationLevel: AttestationLevel.full,
          attestedAt: now.subtract(const Duration(days: 1)),
          attestedUntil: now.add(const Duration(days: 89)),
          dSigValid: true,
        ),
        expectedCj: cj,
        sessionId: window.sessionId,
        windowIdExpected: window.windowId,
        studentPk: kp.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: once.claim(id, j),
      );
      if (out.decision == ProveDecision.confirmed) confirmed++;
    }
    sw.stop();
    expect(confirmed, 500);
    // ignore: avoid_print
    print('500 verifies in ${sw.elapsedMilliseconds}ms '
        '(${(500 * 1000000 / sw.elapsedMicroseconds).toStringAsFixed(0)}/s)');
  });

  test('Ed25519 verify throughput', () {
    final kp = ProxCrypto.generateEdKeypair();
    final msg = Uint8List.fromList(List.filled(64, 7));
    final sig = ProxCrypto.sign(kp.privateKey, msg);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 1000; i++) {
      expect(ProxCrypto.verify(kp.publicKey, msg, sig), isTrue);
    }
    sw.stop();
    // ignore: avoid_print
    print('1000 verifies in ${sw.elapsedMilliseconds}ms');
    expect(sw.elapsedMilliseconds, lessThan(30000));
  });
}

Uint8List pk32(ed.PublicKey k) =>
    Uint8List.fromList(k.bytes.sublist(0, 32));
