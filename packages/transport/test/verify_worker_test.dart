// VerifyWorker parity: the off-thread dSig gate + verifyProve must
// return EXACTLY what the synchronous path returns (same functions, same
// order — this pins the mirror). Plus lifecycle: dispose kills pending
// calls so server stop paths never leak isolates.
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:pointycastle/export.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';
import 'package:test/test.dart';

const _id = 'student@example.com';
const _verifierVer = 'face_verification/test+deadbeef';
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

/// Builds worker args for a bound FULL proof; [mutate] tampers after
/// signing (bad-sig case). Mirrors ProxServer._proveCryptoWorker's
/// assembly field-for-field.
Map<String, Object?> _boundArgs({
  Uint8List? sigS,
  Uint8List? cClaimed,
  required Uint8List sessionId,
  required Uint8List windowId,
  required Uint8List challenge,
  required ed.KeyPair stu,
  required Uint8List pkD,
  required BigInt devD,
  required int stampMs,
}) {
  final ticket = ProxCrypto.faceTicketHash(
    faceScore: 0.85,
    faceValidAtMs: stampMs,
    verifierVer: _verifierVer,
    livenessScore: 0.9,
    livenessVer: _liveVer,
  );
  const integrityHash = '00000000';
  final presentedPk = Uint8List.fromList(stu.publicKey.bytes);
  final dSig = _p256Sign(
      devD,
      ProxCrypto.deviceProvePreimage(
        sessionId: sessionId,
        windowId: windowId,
        j: 0,
        challenge: challenge,
        faceTicketHashBytes: ticket,
        pkS: presentedPk,
        integrityHash: integrityHash,
      ));
  final goodSig = ProxCrypto.signStudentProve(
    studentSk: stu.privateKey,
    sessionId: sessionId,
    windowId: windowId,
    j: 0,
    challenge: challenge,
    studentId: _id,
    faceScore: 0.85,
    faceValidAtMs: stampMs,
    verifierVer: _verifierVer,
    pkD: pkD,
    faceTicketHashBytes: ticket,
    livenessScore: 0.9,
    livenessVer: _liveVer,
  );
  return <String, Object?>{
    'id': _id,
    'windowId': windowId,
    'j': 0,
    'cClaimed': cClaimed ?? challenge,
    'sigS': sigS ?? goodSig,
    'bound': true,
    'ticket': ticket,
    'ticketScore': 0.85,
    'ticketStampMs': stampMs,
    'faceScore': 0.85,
    'peerW': Uint8List(8),
    'rssiDbm': -55,
    'relayHop': 0,
    'nowMillis': stampMs,
    'verifierVer': _verifierVer,
    'pkD': pkD,
    'dSig': dSig,
    'integrityHash': integrityHash,
    'livenessScore': 0.9,
    'livenessVer': _liveVer,
    'attLevel': 'FULL',
    'attUntilMillis':
        stampMs + const Duration(days: 90).inMilliseconds,
    'presentedPk': presentedPk,
    'expectedCj': challenge,
    'sessionId': sessionId,
    'windowIdExpected': windowId,
    'freshWindow': true,
    'singleUseOk': true,
    'priorScores': <double>[],
    'lastVerifierVer': '',
  };
}

/// Direct (synchronous) mirror of the worker assembly, built FROM the
/// same args map so any field drift fails loudly here first.
VerifyOutcome _directFromArgs(Map<String, Object?> a, ed.PublicKey stuPk) {
  Uint8List u8(Object? v) => Uint8List.fromList(List<int>.from(v as List));
  final bound = a['bound'] as bool;
  final stampMs = a['ticketStampMs'] as int;
  final ticket = u8(a['ticket']);
  final pkD = u8(a['pkD']);
  final dSig = u8(a['dSig']);
  final integrityHash = a['integrityHash'] as String;
  var dSigValidReal = false;
  if (bound && ticket.isNotEmpty) {
    final hwClaimed = pkD.isNotEmpty && dSig.isNotEmpty;
    final hashOk = RegExp(r'^[0-9a-f]{8}$').hasMatch(integrityHash);
    if (!hwClaimed || hashOk) {
      if (hwClaimed) {
        dSigValidReal = verifyDeviceSignature(
          pkDRaw64: pkD,
          preimage: ProxCrypto.deviceProvePreimage(
            sessionId: u8(a['sessionId']),
            windowId: u8(a['windowId']),
            j: a['j'] as int,
            challenge: u8(a['expectedCj']),
            faceTicketHashBytes: ticket,
            pkS: u8(a['presentedPk']),
            integrityHash: hashOk ? integrityHash : '',
          ),
          sig64: dSig,
        );
      }
    }
  }
  return verifyProve(
    req: VerifyRequest(
      id: a['id'] as String,
      windowId: u8(a['windowId']),
      j: a['j'] as int,
      cClaimed: u8(a['cClaimed']),
      sigS: u8(a['sigS']),
      faceScore:
          bound ? (a['ticketScore'] as double) : (a['faceScore'] as double),
      faceValidAt: DateTime.fromMillisecondsSinceEpoch(stampMs, isUtc: true),
      peerW: u8(a['peerW']),
      rssiDbm: a['rssiDbm'] as int,
      relayHop: a['relayHop'] as int,
      now: DateTime.fromMillisecondsSinceEpoch(a['nowMillis'] as int,
          isUtc: true),
      verifierVer: a['verifierVer'] as String,
      faceValidAtMs: stampMs,
      pkD: pkD,
      faceTicketHashBytes: ticket,
      livenessScore: a['livenessScore'] as double,
      livenessVer: a['livenessVer'] as String,
      attestationLevel: attestationLevelOf(a['attLevel'] as String),
      attestedUntil: DateTime.fromMillisecondsSinceEpoch(
          a['attUntilMillis'] as int,
          isUtc: true),
      dSigValid: bound && dSigValidReal,
    ),
    expectedCj: u8(a['expectedCj']),
    sessionId: u8(a['sessionId']),
    windowIdExpected: u8(a['windowId']),
    studentPk: stuPk,
    revoked: false,
    freshWindow: a['freshWindow'] as bool,
    singleUseOk: a['singleUseOk'] as bool,
    requireBoundTicket: bound,
  );
}

void main() {
  Uint8List bytes(List<int> l) => Uint8List.fromList(l);
  late ed.KeyPair stu;
  late Uint8List pkD;
  late BigInt devD;
  late Uint8List sessionId;
  late Uint8List windowId;
  late Uint8List challenge;

  setUp(() {
    stu = ProxCrypto.generateEdKeypair();
    final dev = _p256Key();
    pkD = dev.pkD;
    devD = dev.d;
    sessionId = bytes(List.generate(16, (i) => i + 1));
    windowId = bytes(List.generate(6, (i) => i + 11));
    challenge = bytes(List.generate(8, (i) => i + 21));
  });

  test('worker matches direct: bound FULL confirms', () async {
    final stampMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final args = _boundArgs(
      sessionId: sessionId,
      windowId: windowId,
      challenge: challenge,
      stu: stu,
      pkD: pkD,
      devD: devD,
      stampMs: stampMs,
    );
    final worker = VerifyWorker();
    try {
      final res = await worker.proveCrypto(args);
      final direct = _directFromArgs(args, stu.publicKey);
      expect(ProveDecision.values[res['decision'] as int], direct.decision);
      expect(res['reason'], direct.reason);
      expect(res['dSigValid'], isTrue);
      expect(List<String>.from(res['flags'] as List),
          direct.attestationFlags);
      expect(direct.decision, ProveDecision.confirmed);
    } finally {
      worker.dispose();
    }
  });

  test('worker matches direct: bad challenge + bad sig', () async {
    final stampMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final worker = VerifyWorker();
    try {
      final badChallenge = _boundArgs(
        sessionId: sessionId,
        windowId: windowId,
        challenge: challenge,
        stu: stu,
        pkD: pkD,
        devD: devD,
        stampMs: stampMs,
        cClaimed: bytes(List.generate(8, (i) => i + 99)),
      );
      final r1 = await worker.proveCrypto(badChallenge);
      expect(ProveDecision.values[r1['decision'] as int],
          _directFromArgs(badChallenge, stu.publicKey).decision);

      final badSig = _boundArgs(
        sessionId: sessionId,
        windowId: windowId,
        challenge: challenge,
        stu: stu,
        pkD: pkD,
        devD: devD,
        stampMs: stampMs,
        sigS: bytes(List.filled(64, 7)),
      );
      final r2 = await worker.proveCrypto(badSig);
      final d2 = _directFromArgs(badSig, stu.publicKey);
      expect(ProveDecision.values[r2['decision'] as int], d2.decision);
      expect(r2['reason'], d2.reason);
    } finally {
      worker.dispose();
    }
  });

  test('worker matches direct: window-mismatch on retake', () async {
    // Retake guard: claimed window != current window must refuse as
    // window-mismatch (never fall through to bad-challenge). Regression
    // pin: the worker once echoed the claimed id as expected.
    final stampMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final args = _boundArgs(
      sessionId: sessionId,
      windowId: windowId,
      challenge: challenge,
      stu: stu,
      pkD: pkD,
      devD: devD,
      stampMs: stampMs,
    );
    args['windowIdExpected'] = Uint8List.fromList(
        List.generate(6, (i) => 200 + i));
    final worker = VerifyWorker();
    try {
      final res = await worker.proveCrypto(args);
      expect(ProveDecision.values[res['decision'] as int],
          ProveDecision.invalid);
      expect(res['reason'], 'window-mismatch');
    } finally {
      worker.dispose();
    }
  });

  test('concurrent calls share one isolate and all resolve', () async {
    final stampMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final worker = VerifyWorker();
    try {
      final args = [
        for (var i = 0; i < 5; i++)
          _boundArgs(
            sessionId: sessionId,
            windowId: windowId,
            challenge: challenge,
            stu: stu,
            pkD: pkD,
            devD: devD,
            stampMs: stampMs,
          ),
      ];
      final results = await Future.wait(args.map(worker.proveCrypto));
      expect(results, hasLength(5));
      for (final r in results) {
        expect(
            ProveDecision.values[r['decision'] as int], ProveDecision.confirmed);
      }
    } finally {
      worker.dispose();
    }
  });

  test('dispose fails pending calls and the next call throws', () async {
    final worker = VerifyWorker();
    worker.dispose();
    expect(
        worker.proveCrypto(<String, Object?>{}),
        throwsA(isA<StateError>()));
  });
}
