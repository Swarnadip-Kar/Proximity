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

/// Leaf embeds the attestation OID + [challenge]; root is random bytes.
/// Returns (chainHex, rootDer) — the caller pins sha256(rootDer).
(List<String>, Uint8List) _chainFor(Uint8List challenge, [int salt = 9]) {
  final leaf = Uint8List.fromList(
      [...kKeyAttestationOidDer, ...challenge, 0xAA, 0xBB]);
  final root = Uint8List.fromList(
      List.generate(64, (i) => (i * 13 + salt) & 0xFF));
  return ([hexEncode(leaf), hexEncode(root)], root);
}

Future<ProxServer> _makeHwServer({
  required ed.KeyPair prof,
  required List<Uint8List> pinnedRoots,
  void Function(String email, String decision, String reason)? onProve,
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
  );
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
    pkD: pkD,
    dSigFor: (ticket, jj) async => _p256Sign(
        dKey,
        ProxCrypto.deviceProvePreimage(
          sessionId: desc.sessionId,
          windowId: desc.windowId,
          j: jj,
          challenge: cj,
          faceTicketHashBytes: ticket,
          pkS: _pk32(stu.publicKey),
        )),
    attestationLevel: attestationLevel,
    attestedUntilMs: DateTime.now()
        .toUtc()
        .add(kDeviceAttestedValidity)
        .millisecondsSinceEpoch,
    attestationChain: chainHex,
    installId: installId,
  );
}

void main() {
  test('migration default: liveness not yet enforced (one-line flip later)',
      () {
    // Pinned so the rollout flip (requireLivenessEnforced = true) plus
    // the liveness min_version bump cannot land silently — flip the const
    // AND update the bound proofs to carry liveness tickets.
    expect(ProxServer.requireLivenessEnforced, isFalse);
  });

  test('HW FULL proof with genuine dSig + pinned chain confirms', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final device = _p256Key();
    final proved = <String>[];
    // Enrollment-equivalent challenge the professor will recompute.
    final enrollChallenge = deviceBindingChallenge(
        emailLower: _email,
        installId: _installId,
        pkS: _pk32(stu.publicKey));
    final (chainHex, rootDer) = _chainFor(enrollChallenge);
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
      expect(proved, ['$_email confirmed ok|direct-rssi']);
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
    final enrollChallenge = deviceBindingChallenge(
        emailLower: _email,
        installId: _installId,
        pkS: _pk32(stu.publicKey));
    final (chainHex, rootDer) = _chainFor(enrollChallenge);
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
      expect(proved.single, contains('attest-challenge-mismatch'));
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
    final enrollChallenge = deviceBindingChallenge(
        emailLower: _email,
        installId: _installId,
        pkS: _pk32(stu.publicKey));
    final (chainHex, rootDer) = _chainFor(enrollChallenge);
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
}
