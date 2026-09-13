// sec-protocol 1A — liveness-bound ticket + chain-pinning goldens.
//
// Security §4 (F4 fix): faceTicketHash binds
// (scoreMilli||faceValidAt||verifierVerHash8||livenessMilli||livenessVerHash8);
// Sig_s + dSig bind the hash; VerifyRequest gates >=Tl + allowlist.
// Security §2-last-para (F2 fix): offline chain-vs-pinned-roots types +
// deviceBindingChallenge SHA256(email||installId||pkS).
//
// No-silent-downgrade rule: every pre-liveness / pre-1A preimage MUST fail
// against the extended contract (bad-sig / liveness-unbound /
// challenge-mismatch / unknown-root), never confirm.
//
// Pure Dart — no platform code, no IMEI.
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

const _ver = 'face_verification/0.3.9+b45ab893';
const _livVer = 'liveness/minifasnet-v2+a1b2c3d4';
const _faceMs = 1725628800000; // fixed stamp for goldens

({Uint8List sess, Uint8List wid, dynamic stu, Uint8List cj}) _setup(int j) {
  final stu = ProxCrypto.generateEdKeypair();
  final sess = randBytes(16);
  final wid = randBytes(6);
  final cj = ProxCrypto.challengeForSubEpoch(randBytes(32), wid, j);
  return (sess: sess, wid: wid, stu: stu, cj: cj);
}

VerifyRequest _liveReq({
  required String id,
  required Uint8List wid,
  required int j,
  required Uint8List cj,
  required Uint8List sigS,
  required double score,
  required DateTime faceValidAt,
  required Uint8List ticket,
  required DateTime now,
  double livenessScore = 0.92,
  String livenessVer = _livVer,
  AttestationLevel level = AttestationLevel.full,
  bool dSigValid = true,
  Uint8List? pkD,
}) =>
    VerifyRequest(
      id: id,
      windowId: wid,
      j: j,
      cClaimed: cj,
      sigS: sigS,
      faceScore: score,
      faceValidAt: faceValidAt,
      peerW: Uint8List(8),
      rssiDbm: -55,
      relayHop: 0,
      now: now,
      verifierVer: _ver,
      faceValidAtMs: faceValidAt.millisecondsSinceEpoch,
      // Default empty matches sign-time default (explicit ticket path):
      // callers that bind pkD must pass the SAME bytes to sign + request.
      pkD: pkD ?? Uint8List(0),
      faceTicketHashBytes: ticket,
      livenessScore: livenessScore,
      livenessVer: livenessVer,
      attestationLevel: level,
      attestedAt: now.subtract(const Duration(days: 1)),
      attestedUntil: now.add(const Duration(days: 89)),
      dSigValid: dSigValid,
    );

void main() {
  group('extended ticket golden (5-field)', () {
    test('canonical parts are byte-exact', () {
      expect(hexEncode(ProxCrypto.faceMilliBe(0.85)), '0352');
      expect(hexEncode(ProxCrypto.livenessMilliBe(0.92)), '0398');
      expect(hexEncode(ProxCrypto.verifierVerHash8(_ver)),
          '50daeebe40d2e967');
      expect(hexEncode(ProxCrypto.livenessVerHash8(_livVer)),
          'd4d86a6259a5d8e2');
    });

    test('extended ticket golden', () {
      final t = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: _faceMs,
        verifierVer: _ver,
        livenessScore: 0.92,
        livenessVer: _livVer,
      );
      expect(hexEncode(t), '7ec0455ffc9a7b55');
    });

    test('pre-liveness 3-field hash differs (no silent downgrade)', () {
      final old3 = Uint8List.fromList(ProxCrypto.sha256Sync(concat([
        ProxCrypto.faceMilliBe(0.85),
        ProxCrypto.faceValidAtBe(_faceMs),
        ProxCrypto.verifierVerHash8(_ver),
      ])).sublist(0, 8));
      expect(hexEncode(old3), '1c905e9b0af08d81');
      final extended = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: _faceMs,
        verifierVer: _ver,
        livenessScore: 0.92,
        livenessVer: _livVer,
      );
      expect(extended, isNot(old3));
      // Even the neutral-liveness extended hash differs from the old
      // 3-field hash (longer preimage) — old tickets never equal new ones.
      final neutral = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: _faceMs,
        verifierVer: _ver,
      );
      expect(neutral, isNot(old3));
    });

    test('liveness fields are inside the ticket: tamper changes hash', () {
      final base = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: _faceMs,
        verifierVer: _ver,
        livenessScore: 0.92,
        livenessVer: _livVer,
      );
      final scoreTampered = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: _faceMs,
        verifierVer: _ver,
        livenessScore: 0.31,
        livenessVer: _livVer,
      );
      final verTampered = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: _faceMs,
        verifierVer: _ver,
        livenessScore: 0.92,
        livenessVer: 'liveness/evil-v9+zdeadbee',
      );
      expect(scoreTampered, isNot(base));
      expect(verTampered, isNot(base));
    });

    test('old ticket sig fails against extended ticket (bad-sig path)', () {
      final s = _setup(1);
      // Attacker replays a pre-liveness ticket (neutral liveness) but the
      // host recomputes with real liveness — transplant fails.
      final oldTicket = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: _faceMs,
        verifierVer: _ver,
      );
      final sigOld = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: 0.85,
        faceValidAtMs: _faceMs,
        verifierVer: _ver,
        faceTicketHashBytes: oldTicket,
      );
      final newTicket = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: _faceMs,
        verifierVer: _ver,
        livenessScore: 0.92,
        livenessVer: _livVer,
      );
      expect(
          ProxCrypto.verifyStudentProve(
            studentPk: s.stu.publicKey,
            sessionId: s.sess,
            windowId: s.wid,
            j: 1,
            challenge: s.cj,
            studentId: 'a@x.in',
            faceScore: 0.85,
            sig: sigOld,
            faceValidAtMs: _faceMs,
            verifierVer: _ver,
            faceTicketHashBytes: newTicket,
          ),
          isFalse);
    });
  });

  group('dSig binds the extended ticket', () {
    test('liveness change changes the dSig preimage', () {
      final sess = randBytes(16), wid = randBytes(6), cj = randBytes(8);
      final pkS = randBytes(32);
      final t1 = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: _faceMs,
        verifierVer: _ver,
        livenessScore: 0.92,
        livenessVer: _livVer,
      );
      final t2 = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: _faceMs,
        verifierVer: _ver,
        livenessScore: 0.31,
        livenessVer: _livVer,
      );
      final p1 = ProxCrypto.deviceProvePreimage(
          sessionId: sess,
          windowId: wid,
          j: 1,
          challenge: cj,
          faceTicketHashBytes: t1,
          pkS: pkS);
      final p2 = ProxCrypto.deviceProvePreimage(
          sessionId: sess,
          windowId: wid,
          j: 1,
          challenge: cj,
          faceTicketHashBytes: t2,
          pkS: pkS);
      expect(p1, isNot(p2));
    });
  });

  group('verifyProve liveness gates', () {
    test('happy liveness path confirms (FULL fresh)', () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      final ticket = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        livenessScore: 0.92,
        livenessVer: _livVer,
      );
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        faceTicketHashBytes: ticket,
      );
      final out = verifyProve(
        req: _liveReq(
            id: 'a@x.in',
            wid: s.wid,
            j: 1,
            cj: s.cj,
            sigS: sig,
            score: 0.85,
            faceValidAt: now,
            ticket: ticket,
            now: now),
        expectedCj: s.cj,
        sessionId: s.sess,
        windowIdExpected: s.wid,
        studentPk: s.stu.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: true,
      );
      expect(out.decision, ProveDecision.confirmed);
      expect(out.reason, 'ok');
    });

    test('pre-liveness bound ticket fails liveness-unbound (post-rollout)',
        () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      // Signed WITHOUT liveness (neutral defaults) — the old bound shape.
      final ticket = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
      );
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        faceTicketHashBytes: ticket,
      );
      final out = verifyProve(
        req: _liveReq(
            id: 'a@x.in',
            wid: s.wid,
            j: 1,
            cj: s.cj,
            sigS: sig,
            score: 0.85,
            faceValidAt: now,
            ticket: ticket,
            now: now,
            livenessScore: 0.0,
            livenessVer: ''),
        expectedCj: s.cj,
        sessionId: s.sess,
        windowIdExpected: s.wid,
        studentPk: s.stu.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: true,
        // Post-rollout + min_version bump: liveness mandatory.
        requireLiveness: true,
      );
      expect(out.decision, ProveDecision.invalid);
      expect(out.reason, 'liveness-unbound');
    });

    test('pre-liveness bound ticket confirms during migration (default)',
        () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      final ticket = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
      );
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        faceTicketHashBytes: ticket,
      );
      final out = verifyProve(
        req: _liveReq(
            id: 'a@x.in',
            wid: s.wid,
            j: 1,
            cj: s.cj,
            sigS: sig,
            score: 0.85,
            faceValidAt: now,
            ticket: ticket,
            now: now,
            livenessScore: 0.0,
            livenessVer: ''),
        expectedCj: s.cj,
        sessionId: s.sess,
        windowIdExpected: s.wid,
        studentPk: s.stu.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: true,
      );
      expect(out.decision, ProveDecision.confirmed);
      expect(out.reason, 'ok');
    });

    test('unknown liveness pipeline fails closed', () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      const evilLiv = 'evil_liveness/9.9+zdeadbee';
      final ticket = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        livenessScore: 0.95,
        livenessVer: evilLiv,
      );
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        faceTicketHashBytes: ticket,
      );
      final out = verifyProve(
        req: _liveReq(
            id: 'a@x.in',
            wid: s.wid,
            j: 1,
            cj: s.cj,
            sigS: sig,
            score: 0.85,
            faceValidAt: now,
            ticket: ticket,
            now: now,
            livenessScore: 0.95,
            livenessVer: evilLiv),
        expectedCj: s.cj,
        sessionId: s.sess,
        windowIdExpected: s.wid,
        studentPk: s.stu.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: true,
      );
      expect(out.decision, ProveDecision.invalid);
      expect(out.reason, 'unknown-liveness-verifier');
    });

    test('weak liveness score fails (photo-spoof closed)', () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      final ticket = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        livenessScore: 0.31,
        livenessVer: _livVer,
      );
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        faceTicketHashBytes: ticket,
      );
      final out = verifyProve(
        req: _liveReq(
            id: 'a@x.in',
            wid: s.wid,
            j: 1,
            cj: s.cj,
            sigS: sig,
            score: 0.85,
            faceValidAt: now,
            ticket: ticket,
            now: now,
            livenessScore: 0.31),
        expectedCj: s.cj,
        sessionId: s.sess,
        windowIdExpected: s.wid,
        studentPk: s.stu.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: true,
      );
      expect(out.decision, ProveDecision.invalid);
      expect(out.reason, 'liveness-below-threshold');
    });

    test('transplanted liveness score fails bad-sig (sig binds ticket)', () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      final signedTicket = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        livenessScore: 0.31,
        livenessVer: _livVer,
      );
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        faceTicketHashBytes: signedTicket,
      );
      // Attacker inflates POSTed livenessScore without re-signing, but the
      // ticket bytes stay the weak ones — Sig_s was over the weak ticket,
      // so re-verifying with an inflated ticket breaks the sig. Either way
      // the proof cannot confirm: bad-sig here.
      final inflatedTicket = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        livenessScore: 0.95,
        livenessVer: _livVer,
      );
      final out = verifyProve(
        req: _liveReq(
            id: 'a@x.in',
            wid: s.wid,
            j: 1,
            cj: s.cj,
            sigS: sig,
            score: 0.85,
            faceValidAt: now,
            ticket: inflatedTicket,
            now: now,
            livenessScore: 0.95),
        expectedCj: s.cj,
        sessionId: s.sess,
        windowIdExpected: s.wid,
        studentPk: s.stu.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: true,
      );
      expect(out.decision, ProveDecision.invalid);
      expect(out.reason, 'bad-sig');
    });

    test('NONE fallback still gates liveness (no downgrade)', () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      Uint8List ticketFor(double liv) => ProxCrypto.faceTicketHash(
            faceScore: 0.85,
            faceValidAtMs: now.millisecondsSinceEpoch,
            verifierVer: _ver,
            livenessScore: liv,
            livenessVer: _livVer,
          );
      Uint8List sigFor(Uint8List t) => ProxCrypto.signStudentProve(
            studentSk: s.stu.privateKey,
            sessionId: s.sess,
            windowId: s.wid,
            j: 1,
            challenge: s.cj,
            studentId: 'a@x.in',
            faceScore: 0.85,
            faceValidAtMs: now.millisecondsSinceEpoch,
            verifierVer: _ver,
            faceTicketHashBytes: t,
          );
      VerifyOutcome run(double livScore, Uint8List t, Uint8List sig) =>
          verifyProve(
            req: _liveReq(
                id: 'a@x.in',
                wid: s.wid,
                j: 1,
                cj: s.cj,
                sigS: sig,
                score: 0.85,
                faceValidAt: now,
                ticket: t,
                now: now,
                livenessScore: livScore,
                level: AttestationLevel.none,
                dSigValid: false),
            expectedCj: s.cj,
            sessionId: s.sess,
            windowIdExpected: s.wid,
            studentPk: s.stu.publicKey,
            revoked: false,
            freshWindow: true,
            singleUseOk: true,
          );
      // Weak liveness on NONE still rejects.
      final weakT = ticketFor(0.2);
      expect(run(0.2, weakT, sigFor(weakT)).reason,
          'liveness-below-threshold');
      // Missing liveness on NONE still rejects.
      final missingT = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
      );
      final missingSig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: 0.85,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        faceTicketHashBytes: missingT,
      );
      expect(run(0.0, missingT, missingSig).reason, 'liveness-unbound');
      // Strong liveness on NONE confirms with the fallback flag.
      final goodT = ticketFor(0.92);
      final good = run(0.92, goodT, sigFor(goodT));
      expect(good.decision, ProveDecision.confirmed);
      expect(good.attestationFlags, contains('device-none-fallback'));
    });
  });

  group('deviceBindingChallenge SHA256(email||installId||pkS)', () {
    test('golden', () {
      final c = deviceBindingChallenge(
          emailLower: 'A@X.in',
          installId: 'inst-1',
          pkS: Uint8List.fromList(List.filled(32, 7)));
      expect(hexEncode(c),
          'f5848dc95cc4c45505cb41e93666f8cf4443becbec76b413e8b1049e9caca903');
    });

    test('deterministic, lowercases email, binds all inputs', () {
      final pkS = randBytes(32);
      final a = deviceBindingChallenge(
          emailLower: 'A@x.in', installId: 'inst-1', pkS: pkS);
      final b = deviceBindingChallenge(
          emailLower: 'a@x.in', installId: 'inst-1', pkS: pkS);
      expect(a, b);
      expect(
          deviceBindingChallenge(
              emailLower: 'b@x.in', installId: 'inst-1', pkS: pkS),
          isNot(a));
      expect(
          deviceBindingChallenge(
              emailLower: 'a@x.in', installId: 'inst-2', pkS: pkS),
          isNot(a));
      expect(
          deviceBindingChallenge(
              emailLower: 'a@x.in',
              installId: 'inst-1',
              pkS: randBytes(32)),
          isNot(a));
    });
  });

  group('AttestationChain + AttestationWindow types', () {
    test('hex roundtrip + strict reject', () {
      final raw = [randBytes(16), randBytes(24)];
      final chain = AttestationChain(raw);
      final hex = chain.toHexList();
      expect(AttestationChain.fromHexList(hex).certsDer, raw);
      expect(chain.leaf, raw.first);
      expect(chain.root, raw.last);
      expect(() => AttestationChain.fromHexList(['zz']), throwsFormatException);
      expect(() => AttestationChain.fromHexList(['abc']), throwsFormatException);
      expect(const AttestationChain().isEmpty, isTrue);
    });

    test('window contains/stale/expired', () {
      final w = AttestationWindow(
          attestedAt: DateTime.utc(2026, 5, 1),
          attestedUntil: DateTime.utc(2026, 9, 1));
      expect(w.contains(DateTime.utc(2026, 8, 1)), isTrue);
      expect(w.isStale(DateTime.utc(2026, 9, 7)), isTrue);
      expect(w.isExpired(DateTime.utc(2026, 9, 7)), isFalse);
      expect(w.isExpired(DateTime.utc(2026, 9, 20)), isTrue);
    });
  });

  group('chain-pinning units (offline professor check)', () {
    // Fake chain builder: leaf = OID_DER || challenge || filler, root = pin.
    (AttestationChain, Uint8List, Uint8List) fakeChain(
        Uint8List challenge) {
      final root = randBytes(64);
      final rootHash = ProxCrypto.sha256Sync(root);
      final leaf = Uint8List.fromList([
        ...kKeyAttestationOidDer,
        ...challenge,
        ...List.filled(16, 0xAB),
      ]);
      return (AttestationChain([leaf, root]), rootHash, leaf);
    }

    test('happy pin verifies', () {
      final challenge = deviceBindingChallenge(
          emailLower: 'a@x.in', installId: 'i1', pkS: randBytes(32));
      final (chain, rootHash, _) = fakeChain(challenge);
      // Pin-pre-gate unit (fake DER, not X.509): sig verification is
      // explicitly skipped here; full-chain sig coverage lives in
      // test/chain_verify_test.dart (genuine + forged fixtures).
      final r = verifyAttestationChainPin(
          chain: chain,
          pinnedRootHashes: [rootHash],
          expectedChallenge: challenge,
          level: AttestationLevel.full,
          verifySignatures: false);
      expect(r.ok, isTrue);
      expect(r.reason, 'ok');
    });

    test('level NONE never pins', () {
      final challenge = randBytes(32);
      final (chain, rootHash, _) = fakeChain(challenge);
      final r = verifyAttestationChainPin(
          chain: chain,
          pinnedRootHashes: [rootHash],
          expectedChallenge: challenge,
          level: AttestationLevel.none);
      expect(r.ok, isFalse);
      expect(r.reason, 'level-none');
    });

    test('empty chain / empty cert fails closed', () {
      expect(
          verifyAttestationChainPin(
              chain: const AttestationChain(),
              pinnedRootHashes: [randBytes(32)],
              expectedChallenge: randBytes(32),
              level: AttestationLevel.full)
              .reason,
          'empty-chain');
      expect(
          verifyAttestationChainPin(
              chain: AttestationChain([Uint8List(0)]),
              pinnedRootHashes: [randBytes(32)],
              expectedChallenge: randBytes(32),
              level: AttestationLevel.full)
              .reason,
          'empty-cert');
    });

    test('missing OID fails closed (Android shape)', () {
      final challenge = randBytes(16);
      final root = randBytes(32);
      final chain = AttestationChain([
        Uint8List.fromList([...challenge, ...List.filled(8, 1)]),
        root,
      ]);
      final r = verifyAttestationChainPin(
          chain: chain,
          pinnedRootHashes: [ProxCrypto.sha256Sync(root)],
          expectedChallenge: challenge,
          level: AttestationLevel.full);
      expect(r.ok, isFalse);
      expect(r.reason, 'missing-attestation-oid');
    });

    test('challenge mismatch fails (no transplant)', () {
      final challenge = randBytes(16);
      final other = randBytes(16);
      final (chain, rootHash, _) = fakeChain(challenge);
      final r = verifyAttestationChainPin(
          chain: chain,
          pinnedRootHashes: [rootHash],
          expectedChallenge: other,
          level: AttestationLevel.standard);
      expect(r.ok, isFalse);
      expect(r.reason, 'challenge-mismatch');
    });

    test('unknown root fails (TOFU pin mismatch)', () {
      final challenge = randBytes(16);
      final (chain, _, _) = fakeChain(challenge);
      final r = verifyAttestationChainPin(
          chain: chain,
          pinnedRootHashes: [randBytes(32)],
          expectedChallenge: challenge,
          level: AttestationLevel.full);
      expect(r.ok, isFalse);
      expect(r.reason, 'unknown-root');
    });

    test('iOS shape skips OID gate via requireKeyOid=false', () {
      final challenge = randBytes(16);
      final root = randBytes(32);
      final chain = AttestationChain([
        Uint8List.fromList([...challenge, ...List.filled(8, 2)]),
        root,
      ]);
      // Pin-pre-gate unit (fake DER): OID skip is what is under test;
      // sig verification is explicitly skipped (full iOS-chain sig
      // coverage lives in test/chain_verify_test.dart).
      final r = verifyAttestationChainPin(
          chain: chain,
          pinnedRootHashes: [ProxCrypto.sha256Sync(root)],
          expectedChallenge: challenge,
          level: AttestationLevel.standard,
          requireKeyOid: false,
          verifySignatures: false);
      expect(r.ok, isTrue);
    });

    test('leaf helpers are pure byte checks', () {
      final challenge = Uint8List.fromList([9, 8, 7]);
      final leaf = Uint8List.fromList(
          [...kKeyAttestationOidDer, 0x00, 9, 8, 7, 0x00]);
      expect(attestationLeafHasKeyOid(leaf), isTrue);
      expect(attestationLeafContainsChallenge(leaf, challenge), isTrue);
      expect(attestationLeafHasKeyOid(Uint8List.fromList([1, 2, 3])),
          isFalse);
      expect(
          attestationLeafContainsChallenge(
              Uint8List.fromList([1, 2, 3]), challenge),
          isFalse);
    });
  });
}
