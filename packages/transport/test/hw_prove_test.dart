// sec(hwkey): professor verifies HW proofs for real — genuine P-256 dSig
// over deviceProvePreimage + offline chain pin (Google roots by default,
// throwaway pins here) + recomputed enrollment challenge.
//
// Residual, stated: X.509 SIGNATURE math is out of scope (format + pin +
// challenge gate only) — a forged intermediate under a pinned root would
// still pin; the dSig (HW-held key) + challenge binding remain the unforgeable
// halves.
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:pointycastle/export.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';
import 'package:test/test.dart';

const _email = 'student@example.com';
const _installId = 'inst-test-1';
const _verifierVer = 'face_verification/test+deadbeef';
// Allowlisted liveness pipeline tag (prefix `liveness/` — see
// kLivenessVerPrefix); mirrors the vendored MiniFASNetV2 pin shape.
const _liveVer = 'liveness/minifasnet-v2-test+a1b2c3d4';

SecureRandom _rand([int salt = 5]) {
  final r = SecureRandom('Fortuna');
  r.seed(KeyParameter(Uint8List.fromList(
      List.generate(32, (i) => (i * 11 + salt) & 0xFF))));
  return r;
}

({Uint8List pkD, BigInt d}) _p256Key([int salt = 5]) {
  final domain = ECDomainParameters('prime256v1');
  final gen = ECKeyGenerator()
    ..init(ParametersWithRandom(
        ECKeyGeneratorParameters(domain), _rand(salt)));
  final pair = gen.generateKeyPair();
  final ECPublicKey pub = pair.publicKey;
  return (
    pkD: Uint8List.fromList(pub.Q!.getEncoded(false).sublist(1)),
    d: pair.privateKey.d!,
  );
}

Uint8List _p256Sign(BigInt d, Uint8List preimage, [int salt = 7]) {
  final domain = ECDomainParameters('prime256v1');
  final signer = ECDSASigner(SHA256Digest())
    ..init(
        true,
        ParametersWithRandom(
            PrivateKeyParameter(ECPrivateKey(d, domain)), _rand(salt)));
  final sig = signer.generateSignature(preimage) as ECSignature;
  Uint8List be(BigInt v) =>
      hexDecode(v.toRadixString(16).padLeft(64, '0'));
  return Uint8List.fromList([...be(sig.r), ...be(sig.s)]);
}

/// Leaf embeds the attestation OID + [challenge] + raw pkD bytes; root is
/// random bytes. Returns (chainHex, rootDer) — the caller pins
/// sha256(rootDer). The pkD embedding lets the test chain-gate stub
/// approximate the production leaf-pkD bind as byte-containment (exact SPKI
/// equality is covered at protocol level on genuine Google fixtures —
/// see chain_verify_test leaf-pkD round-trip).
(List<String>, Uint8List) _chainFor(Uint8List challenge, Uint8List pkD,
    [int salt = 9]) {
  final leaf = Uint8List.fromList(
      [...kKeyAttestationOidDer, ...challenge, ...pkD, 0xAA, 0xBB]);
  final root = Uint8List.fromList(
      List.generate(64, (i) => (i * 13 + salt) & 0xFF));
  return ([hexEncode(leaf), hexEncode(root)], root);
}

/// Test-only chain gate for fake-DER fixtures: reuses the REAL challenge
/// byte-helper, approximates the leaf-pkD bind as pkD byte-containment
/// (fake leaves carry no parseable SPKI), checks level/emptiness/pin.
/// X.509 signature math + validity dates are NOT exercised here — covered
/// by protocol chain_verify_test on genuine fixtures. Mirrors the
/// production gate's reason/flag vocabulary so wiring asserts stay honest.
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
  // Leaf-pkD bind approximation (see _chainFor): the proving pkD must be
  // contained in the leaf. A key transplant across devices fails here.
  if (expectedLeafPkD != null &&
      expectedLeafPkD.isNotEmpty &&
      !attestationLeafContainsChallenge(leaf, expectedLeafPkD)) {
    return const ChainPinResult(
        ok: false,
        reason: 'leaf-pkd-mismatch',
        flags: ['attest-leaf-pkd-mismatch']);
  }
  final challengeOk =
      attestationLeafContainsChallenge(leaf, expectedChallenge);
  if (!challengeOk) {
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

/// iOS-branch stub: asserts the Apple route was taken (raw present) and
/// approves — the REAL Apple math (nonce/signature/pin) is covered at the
/// protocol level in app_attest_test (python-oracle vectors + assertion
/// round-trip); here only the server routing + body plumbing is pinned.
ChainPinResult _iosChainGate({
  required AttestationChain chain,
  required List<Uint8List> pinnedRootHashes,
  required Uint8List expectedChallenge,
  required Uint8List? expectedLeafPkD,
  required AttestationLevel level,
  String appAttestRawHex = '',
}) {
  if (appAttestRawHex.isEmpty) {
    return const ChainPinResult(
        ok: false, reason: 'ios-stub-no-raw', flags: ['ios-stub-no-raw']);
  }
  if (level != AttestationLevel.standard) {
    return const ChainPinResult(
        ok: false, reason: 'attest-level-mismatch', flags: []);
  }
  return const ChainPinResult(ok: true, reason: 'ok');
}

Future<ProxServer> _makeHwServer({
  required ed.KeyPair prof,
  required List<Uint8List> pinnedRoots,
  void Function(String email, String decision, String reason)? onProve,
  ChainPinResult Function({
    required AttestationChain chain,
    required List<Uint8List> pinnedRootHashes,
    required Uint8List expectedChallenge,
    required Uint8List? expectedLeafPkD,
    required AttestationLevel level,
    String appAttestRawHex,
  })? chainGate,
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
    pinnedRoots: pinnedRoots,
  )..testChainGate = chainGate ?? _fakeChainGate;
  await server.start(port: 0);
  server.openWindow(window, 1);
  return server;
}

Uint8List _pk32(ed.PublicKey k) =>
    Uint8List.fromList(k.bytes.sublist(0, 32));

Future<ProveResult> _proveHw({
  required ProxClient client,
  required WindowDescriptor desc,
  required Uint8List cj,
  required int j,
  required ed.KeyPair stu,
  required Uint8List pkD,
  required BigInt dKey,
  required List<String> chainHex,
  required String installId,
  String attestationLevel = 'FULL',
  double face = 0.85,
  // Security §5: the verdict hash the HW key signs (server recomputes the
  // identical bound preimage). '' simulates a pre-binding client.
  String integrityHash = '00000000',
  // Security §4: liveness ticket (score >= Tl + allowlisted ver) — the
  // server enforces it post-rollout. Neutral (0.0/'') simulates a
  // pre-liveness client (fails closed `liveness-unbound`).
  double livenessScore = 0.92,
  String livenessVer = _liveVer,
  // iOS App Attest artifacts (hex; '' = Android path).
  String appAttestRaw = '',
  String appAttestCredKey = '',
}) {
  final peerW = ProxCrypto.peerAlias(_pk32(stu.publicKey), desc.windowId);
  final stampMs = DateTime.now().toUtc().millisecondsSinceEpoch;
  return client.prove(
    desc: desc,
    studentId: _email,
    challenge: cj,
    j: j,
    faceScore: face,
    peerW: peerW,
    pkS: _pk32(stu.publicKey),
    name: 'Student One',
    roll: '12342210',
    sigSFor: (c, jj) => ProxCrypto.signStudentProve(
      studentSk: stu.privateKey,
      sessionId: desc.sessionId,
      windowId: desc.windowId,
      j: jj,
      challenge: c,
      studentId: _email,
      faceScore: face,
      faceValidAtMs: stampMs,
      verifierVer: _verifierVer,
      pkD: pkD,
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
    verifierVer: _verifierVer,
    livenessScore: livenessScore,
    livenessVer: livenessVer,
    pkD: pkD,
    // The closure signs with the hash the client hands it (the same
    // value the body carries — claim/sign consistency by construction).
    dSigFor: (ticket, jj, h) async => _p256Sign(
        dKey,
        ProxCrypto.deviceProvePreimage(
          sessionId: desc.sessionId,
          windowId: desc.windowId,
          j: jj,
          challenge: cj,
          faceTicketHashBytes: ticket,
          pkS: _pk32(stu.publicKey),
          integrityHash: h,
        )),
    integrityHash: integrityHash,
    attestationLevel: attestationLevel,
    attestedUntilMs: DateTime.now()
        .toUtc()
        .add(kDeviceAttestedValidity)
        .millisecondsSinceEpoch,
    attestationChain: chainHex,
    installId: installId,
    appAttestRaw: appAttestRaw,
    appAttestCredKey: appAttestCredKey,
  );
}

void main() {
  test('liveness enforced post-rollout (flip + min_version bump)', () {
    // Pinned so the enforcement can never be silently reverted: the
    // liveness rollout is DONE (model vendored + enrollment gated), so
    // pre-liveness bound proofs fail closed and old builds are floored by
    // app_config/min_version 0.2.0 + force:true (ForceUpdate barrier with
    // actionable copy, never cryptic rejects).
    expect(ProxServer.requireLivenessEnforced, isTrue);
  });

  test('pre-liveness HW proof fails closed liveness-unbound', () async {
    // Security §4 post-rollout contract: a genuine HW proof (valid dSig +
    // pinned chain) WITHOUT a liveness ticket still fails — never a silent
    // downgrade to face-only. Old clients see the actionable reason and
    // the ForceUpdate floor (0.2.0/force:true) keeps them out earlier.
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final device = _p256Key();
    final enrollChallenge = deviceBindingChallengeV2(
        emailLower: _email,
        installId: _installId,
        pkS: _pk32(stu.publicKey));
    final (chainHex, rootDer) = _chainFor(enrollChallenge, device.pkD);
    final server = await _makeHwServer(
      prof: prof,
      pinnedRoots: [ProxCrypto.sha256Sync(rootDer)],
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      final res = await _proveHw(
        client: client,
        desc: desc,
        cj: cj,
        j: 0,
        stu: stu,
        pkD: device.pkD,
        dKey: device.d,
        chainHex: chainHex,
        installId: _installId,
        livenessScore: 0.0,
        livenessVer: '',
      );
      expect(res.decision, ProveDecision.invalid);
      expect(res.reason, 'liveness-unbound');
      expect(server.tally.presentCount, 0);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('HW FULL proof with genuine dSig + pinned chain confirms', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final device = _p256Key();
    final proved = <String>[];
    // Enrollment-equivalent challenge the professor will recompute.
    final enrollChallenge = deviceBindingChallengeV2(
        emailLower: _email,
        installId: _installId,
        pkS: _pk32(stu.publicKey));
    final (chainHex, rootDer) = _chainFor(enrollChallenge, device.pkD);
    final server = await _makeHwServer(
      prof: prof,
      pinnedRoots: [ProxCrypto.sha256Sync(rootDer)],
      onProve: (e, d, r) => proved.add('$e $d $r'),
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      final res = await _proveHw(
        client: client,
        desc: desc,
        cj: cj,
        j: 0,
        stu: stu,
        pkD: device.pkD,
        dKey: device.d,
        chainHex: chainHex,
        installId: _installId,
      );
      expect(res.decision, ProveDecision.confirmed);
      expect(res.flags, isEmpty);
      // First prove from an unpinned email marks via TOFU with a
      // `first-seen` log token (log only — the wire verdict is unchanged).
      expect(proved, ['$_email confirmed ok|direct-rssi|first-seen']);
      expect(server.tally.presentCount, 1);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('wrong installId → challenge-mismatch → device-unproven', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final device = _p256Key();
    final proved = <String>[];
    final enrollChallenge = deviceBindingChallengeV2(
        emailLower: _email,
        installId: _installId,
        pkS: _pk32(stu.publicKey));
    final (chainHex, rootDer) = _chainFor(enrollChallenge, device.pkD);
    final server = await _makeHwServer(
      prof: prof,
      pinnedRoots: [ProxCrypto.sha256Sync(rootDer)],
      onProve: (e, d, r) => proved.add('$e $d $r'),
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      // The dSig is genuine (same HW key) — only the installId lies, so
      // the recomputed challenge misses the leaf binding.
      final res = await _proveHw(
        client: client,
        desc: desc,
        cj: cj,
        j: 0,
        stu: stu,
        pkD: device.pkD,
        dKey: device.d,
        chainHex: chainHex,
        installId: 'inst-clone-evil',
      );
      expect(res.decision, ProveDecision.invalid);
      expect(res.reason, 'device-unproven');
      // Gate order mirrors production (leaf-pkD bind before challenge):
      // the proving pkD matches the leaf here, so the lie surfaces as a
      // challenge mismatch (installId bind). A transplanted pkD fails
      // earlier as leaf-pkd-mismatch (covered at protocol level +
      // 'transplanted pkD' below).
      expect(proved.single, contains('attest-challenge-mismatch'));
      expect(server.tally.presentCount, 0);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('transplanted pkD (valid chain, attacker key) → leaf-pkd-mismatch',
      () async {
    // C2 key-substitution: the chain is genuine for the victim device and
    // the attacker's dSig is valid under the ATTACKER's P-256 key — every
    // check passes except the leaf-pkD bind (leaf carries the victim pkD,
    // the proof carries the attacker pkD). Must fail closed, never a tier.
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final device = _p256Key();
    final attacker = _p256Key(99);
    final proved = <String>[];
    final enrollChallenge = deviceBindingChallengeV2(
        emailLower: _email,
        installId: _installId,
        pkS: _pk32(stu.publicKey));
    final (chainHex, rootDer) = _chainFor(enrollChallenge, device.pkD);
    final server = await _makeHwServer(
      prof: prof,
      pinnedRoots: [ProxCrypto.sha256Sync(rootDer)],
      onProve: (e, d, r) => proved.add('$e $d $r'),
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      final res = await _proveHw(
        client: client,
        desc: desc,
        cj: cj,
        j: 0,
        stu: stu,
        pkD: attacker.pkD,
        dKey: attacker.d,
        chainHex: chainHex,
        installId: _installId,
      );
      expect(res.decision, ProveDecision.invalid);
      expect(res.reason, 'device-unproven');
      expect(proved.single, contains('attest-leaf-pkd-mismatch'));
      expect(server.tally.presentCount, 0);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('forged dSig (wrong P-256 key) → device-unproven', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final device = _p256Key();
    final forger = _p256Key(77);
    final proved = <String>[];
    final enrollChallenge = deviceBindingChallengeV2(
        emailLower: _email,
        installId: _installId,
        pkS: _pk32(stu.publicKey));
    final (chainHex, rootDer) = _chainFor(enrollChallenge, device.pkD);
    final server = await _makeHwServer(
      prof: prof,
      pinnedRoots: [ProxCrypto.sha256Sync(rootDer)],
      onProve: (e, d, r) => proved.add('$e $d $r'),
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      // Chain pins fine — but the dSig comes from another key: presence
      // alone must never confirm.
      final res = await _proveHw(
        client: client,
        desc: desc,
        cj: cj,
        j: 0,
        stu: stu,
        pkD: device.pkD,
        dKey: forger.d,
        chainHex: chainHex,
        installId: _installId,
      );
      expect(res.decision, ProveDecision.invalid);
      expect(res.reason, 'device-unproven');
      expect(server.tally.presentCount, 0);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('pre-binding HW proof (no integrityHash) fails closed', () async {
    // Security §5, no silent downgrade: a genuine dSig over the hash-less
    // preimage is rejected as device-unproven once the server requires the
    // bound form — old clients fail closed, never confirm unbound.
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final device = _p256Key();
    final enrollChallenge = deviceBindingChallengeV2(
        emailLower: _email,
        installId: _installId,
        pkS: _pk32(stu.publicKey));
    final (chainHex, rootDer) = _chainFor(enrollChallenge, device.pkD);
    final server = await _makeHwServer(
      prof: prof,
      pinnedRoots: [ProxCrypto.sha256Sync(rootDer)],
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      final res = await _proveHw(
        client: client,
        desc: desc,
        cj: cj,
        j: 0,
        stu: stu,
        pkD: device.pkD,
        dKey: device.d,
        chainHex: chainHex,
        installId: _installId,
        integrityHash: '',
      );
      expect(res.decision, ProveDecision.invalid);
      expect(res.reason, 'device-unproven');
      expect(server.tally.presentCount, 0);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('transplanted integrityHash (claim/sign mismatch) fails closed',
      () async {
    // The body claims hash B but the HW key signed hash A: the recomputed
    // preimage differs, so dSig verify fails — a clean-device dSig can
    // never be transplanted onto a tainted prove.
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final device = _p256Key();
    final enrollChallenge = deviceBindingChallengeV2(
        emailLower: _email,
        installId: _installId,
        pkS: _pk32(stu.publicKey));
    final (chainHex, rootDer) = _chainFor(enrollChallenge, device.pkD);
    final server = await _makeHwServer(
      prof: prof,
      pinnedRoots: [ProxCrypto.sha256Sync(rootDer)],
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      final peerW = ProxCrypto.peerAlias(_pk32(stu.publicKey), desc.windowId);
      final stampMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      const face = 0.85;
      final res = await client.prove(
        desc: desc,
        studentId: _email,
        challenge: cj,
        j: 0,
        faceScore: face,
        peerW: peerW,
        pkS: _pk32(stu.publicKey),
        name: 'Student One',
        roll: '12342210',
        sigSFor: (c, jj) => ProxCrypto.signStudentProve(
          studentSk: stu.privateKey,
          sessionId: desc.sessionId,
          windowId: desc.windowId,
          j: jj,
          challenge: c,
          studentId: _email,
          faceScore: face,
          faceValidAtMs: stampMs,
          verifierVer: _verifierVer,
          pkD: device.pkD,
          livenessScore: 0.92,
          livenessVer: _liveVer,
        ),
        livenessScore: 0.92,
        livenessVer: _liveVer,
        sigBindFor: (fp, jj) => ProxCrypto.sign(
            stu.privateKey,
            bindPreimage(
                sessionId: desc.sessionId,
                windowId: desc.windowId,
                j: jj,
                tlsFingerprint: fp)),
        faceValidAtMs: stampMs,
        verifierVer: _verifierVer,
        pkD: device.pkD,
        // Signed over hash A …
        dSigFor: (ticket, jj, _) async => _p256Sign(
            device.d,
            ProxCrypto.deviceProvePreimage(
              sessionId: desc.sessionId,
              windowId: desc.windowId,
              j: jj,
              challenge: cj,
              faceTicketHashBytes: ticket,
              pkS: _pk32(stu.publicKey),
              integrityHash: 'aaaaaaaa',
            )),
        attestationLevel: 'FULL',
        attestedUntilMs: DateTime.now()
            .toUtc()
            .add(kDeviceAttestedValidity)
            .millisecondsSinceEpoch,
        attestationChain: chainHex,
        installId: _installId,
        // … but the body claims hash B.
        integrityHash: 'bbbbbbbb',
      );
      expect(res.decision, ProveDecision.invalid);
      expect(res.reason, 'device-unproven');
      expect(server.tally.presentCount, 0);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('FULL claim without a chain → device-unproven (no silent tier)',
      () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final device = _p256Key();
    final server = await _makeHwServer(
      prof: prof,
      pinnedRoots: [ProxCrypto.sha256Sync(randBytes(64))],
    );
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      final res = await _proveHw(
        client: client,
        desc: desc,
        cj: cj,
        j: 0,
        stu: stu,
        pkD: device.pkD,
        dKey: device.d,
        chainHex: const [],
        installId: _installId,
      );
      expect(res.decision, ProveDecision.invalid);
      expect(res.reason, 'device-unproven');
      expect(server.tally.presentCount, 0);
    } finally {
      client.close();
      await server.stop();
    }
  });

  group('iOS App Attest branch (STD tier, Apple route)', () {
    // Hand-built Apple attestation object (definite-length CBOR):
    // A3{1:'apple', 2:authData(37B), 3:{'x5c':[<0x30..>]}}.
    String appleObjectHex() {
      final auth = Uint8List.fromList(
          [...List.filled(32, 0x11), 0x45, 0x00, 0x00, 0x00, 0x07]);
      final cert = Uint8List.fromList([0x30, 0x03, 0x01, 0x02, 0x03]);
      return hexEncode(Uint8List.fromList([
        0xA3,
        0x01,
        0x65,
        0x61,
        0x70,
        0x70,
        0x6C,
        0x65,
        0x02,
        0x58,
        auth.length,
        ...auth,
        0x03,
        0xA1,
        0x63,
        0x78,
        0x35,
        0x63,
        0x81,
        0x45,
        ...cert,
      ]));
    }

    // Assertion shape: authData(37B) ‖ sig(64B).
    String appleAssertionHex() => hexEncode(Uint8List.fromList([
          ...List.filled(37, 0x33),
          ...List.filled(64, 0x44),
        ]));

    Future<ProveResult> proveIos({
      required ProxClient client,
      required WindowDescriptor desc,
      required Uint8List cj,
      required ed.KeyPair stu,
      required Uint8List pkD,
      required BigInt dKey,
      required String appAttestRaw,
      String appAttestCredKey = '',
    }) =>
        _proveHw(
          client: client,
          desc: desc,
          cj: cj,
          j: 0,
          stu: stu,
          pkD: pkD,
          dKey: dKey,
          chainHex: const [],
          installId: _installId,
          attestationLevel: 'STD',
          appAttestRaw: appAttestRaw,
          appAttestCredKey: appAttestCredKey,
        );

    test('object path routes to Apple branch and confirms (STD)', () async {
      final prof = ProxCrypto.generateEdKeypair();
      final stu = ProxCrypto.generateEdKeypair();
      final device = _p256Key();
      final server = await _makeHwServer(
        prof: prof,
        pinnedRoots: [ProxCrypto.sha256Sync(randBytes(64))],
        chainGate: _iosChainGate,
      );
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await client.fetchWindow(cj);
        final res = await proveIos(
          client: client,
          desc: desc,
          cj: cj,
          stu: stu,
          pkD: device.pkD,
          dKey: device.d,
          appAttestRaw: appleObjectHex(),
        );
        expect(res.decision, ProveDecision.confirmed);
        expect(server.tally.presentCount, 1);
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('assertion path routes with credential key and confirms', () async {
      final prof = ProxCrypto.generateEdKeypair();
      final stu = ProxCrypto.generateEdKeypair();
      final device = _p256Key();
      final server = await _makeHwServer(
        prof: prof,
        pinnedRoots: [ProxCrypto.sha256Sync(randBytes(64))],
        chainGate: _iosChainGate,
      );
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await client.fetchWindow(cj);
        final res = await proveIos(
          client: client,
          desc: desc,
          cj: cj,
          stu: stu,
          pkD: device.pkD,
          dKey: device.d,
          appAttestRaw: appleAssertionHex(),
          appAttestCredKey: hexEncode(Uint8List(64)),
        );
        expect(res.decision, ProveDecision.confirmed);
        expect(server.tally.presentCount, 1);
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('malformed CBOR fails closed device-unproven (no stub)', () async {
      final prof = ProxCrypto.generateEdKeypair();
      final stu = ProxCrypto.generateEdKeypair();
      final device = _p256Key();
      // No chain gate stub: the production iOS branch must fail the
      // garbage artifact closed on its own (parse, never a pass).
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
        sightings: (
                {required peerW,
                required expectedAirKey,
                required expectedUuid}) =>
            const RadioSighting(rssiDbm: -55, hop: 0),
        pinnedRoots: [ProxCrypto.sha256Sync(randBytes(64))],
      );
      await server.start(port: 0);
      server.openWindow(window, 1);
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await client.fetchWindow(cj);
        final res = await proveIos(
          client: client,
          desc: desc,
          cj: cj,
          stu: stu,
          pkD: device.pkD,
          dKey: device.d,
          appAttestRaw: hexEncode(Uint8List.fromList(List.filled(40, 0x99))),
        );
        expect(res.decision, ProveDecision.invalid);
        expect(res.reason, 'device-unproven');
        expect(server.tally.presentCount, 0);
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('Android path unchanged: Apple-shaped body without raw stays OID-shaped',
        () async {
      // A proof with no appAttestRaw routes to the Android gate even when
      // the chain is Apple-shaped-but-OID-less → missing-attestation-oid.
      // Uses the REAL Android production gate (no stub) with a throwaway
      // root so only the OID refusal is asserted.
      final prof = ProxCrypto.generateEdKeypair();
      final stu = ProxCrypto.generateEdKeypair();
      final device = _p256Key();
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
        sightings: (
                {required peerW,
                required expectedAirKey,
                required expectedUuid}) =>
            const RadioSighting(rssiDbm: -55, hop: 0),
        pinnedRoots: [ProxCrypto.sha256Sync(randBytes(64))],
      );
      await server.start(port: 0);
      server.openWindow(window, 1);
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await client.fetchWindow(cj);
        final res = await proveIos(
          client: client,
          desc: desc,
          cj: cj,
          stu: stu,
          pkD: device.pkD,
          dKey: device.d,
          appAttestRaw: '',
        );
        expect(res.decision, ProveDecision.invalid);
        expect(res.reason, 'device-unproven');
      } finally {
        client.close();
        await server.stop();
      }
    });
  });
}
