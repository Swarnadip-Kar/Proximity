// Device-binding + local-trust goldens (Tracks 2+3 + security §4 liveness).
//
// Covers the reconciled 2/3 interface: extended Sig_s preimage binding
// (score/faceValidAt/verifierVer/livenessScore/livenessVer/pkD/ticket),
// verifyProve bound-ticket gates (tampered score, tampered timestamp,
// replay, unknown verifier, liveness-unbound/unknown-liveness/
// below-threshold), device-proof tiers (FULL/STD fresh→confirmed, STALE
// grace→confirmed+ banner, NONE→fallback-flagged confirm at verifyProve),
// and attestation anomaly flags (score==1.000 repeats, future/reused
// faceValidAt, verifierVer flapping).
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

const _ver = 'face_verification/0.3.9+b45ab893';
// Security §4 liveness fixtures (sec-protocol 1A): passive classifier
// output + pipeline pin. All bound happy-paths use these; gate tests vary
// them to hit each reject.
const _livScore = 0.92;
const _livVer = 'liveness/minifasnet-v2+a1b2c3d4';

({Uint8List sess, Uint8List wid, dynamic stu, Uint8List cj}) _setup(int j) {
  final stu = ProxCrypto.generateEdKeypair();
  final sess = randBytes(16);
  final wid = randBytes(6);
  final cj = ProxCrypto.challengeForSubEpoch(randBytes(32), wid, j);
  return (sess: sess, wid: wid, stu: stu, cj: cj);
}

VerifyRequest _boundReq({
  required String id,
  required Uint8List wid,
  required int j,
  required Uint8List cj,
  required Uint8List sigS,
  required double score,
  required DateTime faceValidAt,
  required String verifierVer,
  required Uint8List pkD,
  required Uint8List ticket,
  required DateTime now,
  AttestationLevel level = AttestationLevel.full,
  bool dSigValid = true,
  DateTime? attestedUntil,
  Set<int> seen = const {},
  List<double> prior = const [],
  String lastVer = '',
  double livenessScore = _livScore,
  String livenessVer = _livVer,
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
      verifierVer: verifierVer,
      faceValidAtMs: faceValidAt.millisecondsSinceEpoch,
      pkD: pkD,
      faceTicketHashBytes: ticket,
      livenessScore: livenessScore,
      livenessVer: livenessVer,
      attestationLevel: level,
      attestedAt: now.subtract(const Duration(days: 1)),
      attestedUntil:
          attestedUntil ?? now.add(const Duration(days: 89)),
      dSigValid: dSigValid,
      seenFaceValidAtMs: seen,
      priorScores: prior,
      lastVerifierVer: lastVer,
    );



void main() {
  group('extended Sig_s ticket binding', () {
    test('ticket fields are inside Sig_s: score tamper fails verify', () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      const score = 0.85;
      final ticket = ProxCrypto.faceTicketHash(
          faceScore: score,
          faceValidAtMs: now.millisecondsSinceEpoch,
          verifierVer: _ver,
          livenessScore: _livScore,
          livenessVer: _livVer);
      final pkD = randBytes(32);
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: score,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        pkD: pkD,
        faceTicketHashBytes: ticket,
      );
      // Same bytes verify…
      expect(
          ProxCrypto.verifyStudentProve(
            studentPk: s.stu.publicKey,
            sessionId: s.sess,
            windowId: s.wid,
            j: 1,
            challenge: s.cj,
            studentId: 'a@x.in',
            faceScore: score,
            sig: sig,
            faceValidAtMs: now.millisecondsSinceEpoch,
            verifierVer: _ver,
            pkD: pkD,
            faceTicketHashBytes: ticket,
          ),
          isTrue);
      // …a transplanted score does not (host re-verifies with the POSTed
      // ticket score, so inflating faceScore breaks the signature).
      expect(
          ProxCrypto.verifyStudentProve(
            studentPk: s.stu.publicKey,
            sessionId: s.sess,
            windowId: s.wid,
            j: 1,
            challenge: s.cj,
            studentId: 'a@x.in',
            faceScore: 0.99,
            sig: sig,
            faceValidAtMs: now.millisecondsSinceEpoch,
            verifierVer: _ver,
            pkD: pkD,
            faceTicketHashBytes: ticket,
          ),
          isFalse);
    });

    test('timestamp tamper fails: faceValidAt is bound', () {
      final s = _setup(2);
      final now = DateTime.now().toUtc();
      const score = 0.8;
      final ticket = ProxCrypto.faceTicketHash(
          faceScore: score,
          faceValidAtMs: now.millisecondsSinceEpoch,
          verifierVer: _ver,
          livenessScore: _livScore,
          livenessVer: _livVer);
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 2,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: score,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        faceTicketHashBytes: ticket,
      );
      final later = now.add(const Duration(minutes: 2));
      expect(
          ProxCrypto.verifyStudentProve(
            studentPk: s.stu.publicKey,
            sessionId: s.sess,
            windowId: s.wid,
            j: 2,
            challenge: s.cj,
            studentId: 'a@x.in',
            faceScore: score,
            sig: sig,
            faceValidAtMs: later.millisecondsSinceEpoch,
            verifierVer: _ver,
            faceTicketHashBytes: ProxCrypto.faceTicketHash(
                faceScore: score,
                faceValidAtMs: later.millisecondsSinceEpoch,
                verifierVer: _ver,
                livenessScore: _livScore,
                livenessVer: _livVer),
          ),
          isFalse);
    });

    test('legacy 6-field signatures never verify as bound tickets', () {
      // A pre-Tracks-2+3 signature (old preimage) checked against the
      // extended preimage fails — no downgrade path.
      final s = _setup(0);
      final legacy = ProxCrypto.sign(
          s.stu.privateKey,
          concat([
            s.sess,
            s.wid,
            ProxCrypto.j32(0),
            s.cj,
            'a@x.in'.codeUnits,
            ProxCrypto.faceMilliBe(0.9),
          ]));
      expect(
          ProxCrypto.verifyStudentProve(
            studentPk: s.stu.publicKey,
            sessionId: s.sess,
            windowId: s.wid,
            j: 0,
            challenge: s.cj,
            studentId: 'a@x.in',
            faceScore: 0.9,
            sig: legacy,
            faceValidAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
            verifierVer: _ver,
          ),
          isFalse);
    });
  });

  group('verifyProve bound-ticket gates', () {
    test('happy bound path confirms (FULL, fresh)', () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      const score = 0.85;
      final ticket = ProxCrypto.faceTicketHash(
          faceScore: score,
          faceValidAtMs: now.millisecondsSinceEpoch,
          verifierVer: _ver,
          livenessScore: _livScore,
          livenessVer: _livVer);
      final pkD = randBytes(32);
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: score,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        pkD: pkD,
        faceTicketHashBytes: ticket,
      );
      final out = verifyProve(
        req: _boundReq(
            id: 'a@x.in',
            wid: s.wid,
            j: 1,
            cj: s.cj,
            sigS: sig,
            score: score,
            faceValidAt: now,
            verifierVer: _ver,
            pkD: pkD,
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
      expect(out.attestationFlags, isEmpty);
    });

    test('tampered score in POST body fails closed (bad-sig)', () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      const signedScore = 0.85;
      final ticket = ProxCrypto.faceTicketHash(
          faceScore: signedScore,
          faceValidAtMs: now.millisecondsSinceEpoch,
          verifierVer: _ver,
          livenessScore: _livScore,
          livenessVer: _livVer);
      final pkD = randBytes(32);
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: signedScore,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        pkD: pkD,
        faceTicketHashBytes: ticket,
      );
      // Attacker inflates the POSTed score without re-signing.
      final out = verifyProve(
        req: _boundReq(
            id: 'a@x.in',
            wid: s.wid,
            j: 1,
            cj: s.cj,
            sigS: sig,
            score: 0.99,
            faceValidAt: now,
            verifierVer: _ver,
            pkD: pkD,
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
      expect(out.decision, ProveDecision.invalid);
      expect(out.reason, 'bad-sig');
    });

    test('replayed (ID,j) still rejected on the bound path', () {
      final s = _setup(3);
      final now = DateTime.now().toUtc();
      const score = 0.8;
      final ticket = ProxCrypto.faceTicketHash(
          faceScore: score,
          faceValidAtMs: now.millisecondsSinceEpoch,
          verifierVer: _ver,
          livenessScore: _livScore,
          livenessVer: _livVer);
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 3,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: score,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        faceTicketHashBytes: ticket,
      );
      final out = verifyProve(
        req: _boundReq(
            id: 'a@x.in',
            wid: s.wid,
            j: 3,
            cj: s.cj,
            sigS: sig,
            score: score,
            faceValidAt: now,
            verifierVer: _ver,
            pkD: Uint8List(0),
            ticket: ticket,
            now: now),
        expectedCj: s.cj,
        sessionId: s.sess,
        windowIdExpected: s.wid,
        studentPk: s.stu.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: false,
      );
      expect(out.decision, ProveDecision.invalid);
      expect(out.reason, 'replay-id-j');
    });

    test('unknown verifier version fails closed', () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      const score = 0.85;
      const evilVer = 'evil_plugin/9.9+zdeadbee';
      final ticket = ProxCrypto.faceTicketHash(
          faceScore: score,
          faceValidAtMs: now.millisecondsSinceEpoch,
          verifierVer: evilVer,
          livenessScore: _livScore,
          livenessVer: _livVer);
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: score,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: evilVer,
        faceTicketHashBytes: ticket,
      );
      final out = verifyProve(
        req: _boundReq(
            id: 'a@x.in',
            wid: s.wid,
            j: 1,
            cj: s.cj,
            sigS: sig,
            score: score,
            faceValidAt: now,
            verifierVer: evilVer,
            pkD: Uint8List(0),
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
      expect(out.decision, ProveDecision.invalid);
      expect(out.reason, 'unknown-verifier');
    });

    test('unbound legacy ticket fails closed when bound required', () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: 0.9,
      );
      final out = verifyProve(
        req: VerifyRequest(
            id: 'a@x.in',
            windowId: s.wid,
            j: 1,
            cClaimed: s.cj,
            sigS: sig,
            faceScore: 0.9,
            faceValidAt: now,
            peerW: Uint8List(8),
            rssiDbm: -55,
            relayHop: 0,
            now: now),
        expectedCj: s.cj,
        sessionId: s.sess,
        windowIdExpected: s.wid,
        studentPk: s.stu.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: true,
        requireBoundTicket: true,
      );
      expect(out.decision, ProveDecision.invalid);
      expect(out.reason, 'face-unbound');
    });
  });

  group('device-proof tiers', () {
    test('STD fresh confirms', () {
      final r = evaluateDeviceProof(
        level: AttestationLevel.standard,
        attestedAt: DateTime.utc(2026, 8, 1),
        attestedUntil: DateTime.utc(2026, 10, 30),
        dSigValid: true,
        now: DateTime.utc(2026, 9, 7),
      );
      expect(r.tier, DeviceTier.fresh);
      expect(r.confirms, isTrue);
    });

    test('STALE within 14d grace confirms with banner flag', () {
      final r = evaluateDeviceProof(
        level: AttestationLevel.full,
        attestedAt: DateTime.utc(2026, 5, 1),
        attestedUntil: DateTime.utc(2026, 9, 1),
        dSigValid: true,
        now: DateTime.utc(2026, 9, 7),
      );
      expect(r.tier, DeviceTier.stale);
      expect(r.confirms, isTrue);
      expect(r.auditFlags, contains('device-stale'));
    });

    test('past grace is unproven', () {
      final r = evaluateDeviceProof(
        level: AttestationLevel.full,
        attestedAt: DateTime.utc(2026, 4, 1),
        attestedUntil: DateTime.utc(2026, 9, 1),
        dSigValid: true,
        now: DateTime.utc(2026, 9, 20),
      );
      expect(r.tier, DeviceTier.unproven);
      expect(r.confirms, isFalse);
      expect(r.reason, 'device-unproven');
    });

    test('NONE never confirms → manual path', () {
      final r = evaluateDeviceProof(
        level: AttestationLevel.none,
        attestedAt: DateTime.utc(2026, 9, 1),
        attestedUntil: DateTime.utc(2026, 12, 1),
        dSigValid: true,
        now: DateTime.utc(2026, 9, 7),
      );
      expect(r.confirms, isFalse);
      expect(r.reason, 'device-unproven');
    });

    test('bad dSig never confirms even when FULL+fresh', () {
      final r = evaluateDeviceProof(
        level: AttestationLevel.full,
        attestedAt: DateTime.utc(2026, 9, 1),
        attestedUntil: DateTime.utc(2026, 12, 1),
        dSigValid: false,
        now: DateTime.utc(2026, 9, 7),
      );
      expect(r.confirms, isFalse);
    });

    test('NONE at verifyProve falls back to legacy-equivalent confirm', () {
      // C3(a) explicit fallback: bound fields present but level NONE
      // verifies like the legacy unbound proof ONLY with
      // allowNoneFallback:true — same ticket-bound Sig_s + sighting
      // checks, no tier claimed. Logged via the fallback flag, never
      // silent. Default (no flag) fails device-none-requires-approval.
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      const score = 0.85;
      final ticket = ProxCrypto.faceTicketHash(
          faceScore: score,
          faceValidAtMs: now.millisecondsSinceEpoch,
          verifierVer: _ver,
          livenessScore: _livScore,
          livenessVer: _livVer);
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: score,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        faceTicketHashBytes: ticket,
      );
      final out = verifyProve(
        req: _boundReq(
            id: 'a@x.in',
            wid: s.wid,
            j: 1,
            cj: s.cj,
            sigS: sig,
            score: score,
            faceValidAt: now,
            verifierVer: _ver,
            pkD: Uint8List(0),
            ticket: ticket,
            now: now,
            level: AttestationLevel.none,
            dSigValid: false),
        expectedCj: s.cj,
        sessionId: s.sess,
        windowIdExpected: s.wid,
        studentPk: s.stu.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: true,
        allowNoneFallback: true,
      );
      expect(out.decision, ProveDecision.confirmed);
      expect(out.reason, 'ok');
      expect(out.attestationFlags, contains('device-none-fallback'));
    });

    test('NONE fallback still rejects a tampered binding (bad-sig)', () {
      // Transplant the ticket score without re-signing: the Sig_s bind
      // must fail even though no tier is claimed.
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      const signedScore = 0.85;
      final ticket = ProxCrypto.faceTicketHash(
          faceScore: signedScore,
          faceValidAtMs: now.millisecondsSinceEpoch,
          verifierVer: _ver,
          livenessScore: _livScore,
          livenessVer: _livVer);
      final pkD = randBytes(32);
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: signedScore,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        pkD: pkD,
        faceTicketHashBytes: ticket,
      );
      final out = verifyProve(
        req: _boundReq(
            id: 'a@x.in',
            wid: s.wid,
            j: 1,
            cj: s.cj,
            sigS: sig,
            score: 0.99, // inflated POST body, signature unchanged
            faceValidAt: now,
            verifierVer: _ver,
            pkD: pkD,
            ticket: ticket,
            now: now,
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
      expect(out.decision, ProveDecision.invalid);
      expect(out.reason, 'bad-sig');
    });

    test('NONE fallback still gates sighting + face like legacy', () {
      final s = _setup(1);
      final now = DateTime.now().toUtc();
      const score = 0.85;
      final ticket = ProxCrypto.faceTicketHash(
          faceScore: score,
          faceValidAtMs: now.millisecondsSinceEpoch,
          verifierVer: _ver,
          livenessScore: _livScore,
          livenessVer: _livVer);
      final sig = ProxCrypto.signStudentProve(
        studentSk: s.stu.privateKey,
        sessionId: s.sess,
        windowId: s.wid,
        j: 1,
        challenge: s.cj,
        studentId: 'a@x.in',
        faceScore: score,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: _ver,
        faceTicketHashBytes: ticket,
      );
      VerifyOutcome v({required int hop, required int rssi}) => verifyProve(
            req: VerifyRequest(
              id: 'a@x.in',
              windowId: s.wid,
              j: 1,
              cClaimed: s.cj,
              sigS: sig,
              faceScore: score,
              faceValidAt: now,
              peerW: Uint8List(8),
              rssiDbm: rssi,
              relayHop: hop,
              now: now,
              verifierVer: _ver,
              faceValidAtMs: now.millisecondsSinceEpoch,
              faceTicketHashBytes: ticket,
              livenessScore: _livScore,
              livenessVer: _livVer,
              attestationLevel: AttestationLevel.none,
            ),
            expectedCj: s.cj,
            sessionId: s.sess,
            windowIdExpected: s.wid,
            studentPk: s.stu.publicKey,
            revoked: false,
            freshWindow: true,
            singleUseOk: true,
            allowNoneFallback: true,
          );
      expect(v(hop: 0, rssi: -55).decision, ProveDecision.confirmed);
      expect(v(hop: 99, rssi: -127).reason, 'no-ble-sighting');
    });
  });

  group('attestation anomaly flags', () {
    test('score==1.000 repeat flags saturated', () {
      final flags = detectFaceAnomalies(
        score: 1.0,
        faceValidAtMs: DateTime.utc(2026, 9, 7, 10).millisecondsSinceEpoch,
        verifierVer: _ver,
        now: DateTime.utc(2026, 9, 7, 10, 0, 30),
        priorScores: const [0.85, 1.0],
      );
      expect(flags, contains('attest-score-saturated'));
    });

    test('lone 1.000 without history does not flag', () {
      final flags = detectFaceAnomalies(
        score: 1.0,
        faceValidAtMs: DateTime.utc(2026, 9, 7, 10).millisecondsSinceEpoch,
        verifierVer: _ver,
        now: DateTime.utc(2026, 9, 7, 10, 0, 30),
      );
      expect(flags, isNot(contains('attest-score-saturated')));
    });

    test('future faceValidAt flags', () {
      final flags = detectFaceAnomalies(
        score: 0.8,
        faceValidAtMs: DateTime.utc(2026, 9, 7, 12).millisecondsSinceEpoch,
        verifierVer: _ver,
        now: DateTime.utc(2026, 9, 7, 10),
      );
      expect(flags, contains('attest-future-face'));
    });

    test('reused faceValidAt flags', () {
      final stamp = DateTime.utc(2026, 9, 7, 10).millisecondsSinceEpoch;
      final flags = detectFaceAnomalies(
        score: 0.8,
        faceValidAtMs: stamp,
        verifierVer: _ver,
        now: DateTime.utc(2026, 9, 7, 10, 0, 30),
        seenFaceValidAtMs: {stamp},
      );
      expect(flags, contains('attest-reused-face'));
    });

    test('verifierVer flapping flags (advisory)', () {
      final flags = detectFaceAnomalies(
        score: 0.8,
        faceValidAtMs: DateTime.utc(2026, 9, 7, 10).millisecondsSinceEpoch,
        verifierVer: 'face_verification/0.3.10+c0ffee12',
        now: DateTime.utc(2026, 9, 7, 10, 0, 30),
        lastVerifierVer: _ver,
      );
      expect(flags, contains('verifier-flapping'));
    });
  });

  group('enrollment challenge binding', () {
    test('challenge is deterministic and binds all three inputs', () {
      final pkS = randBytes(32);
      final a = deviceBindingChallengeV2(
          emailLower: 'A@x.in', installId: 'inst-1', pkS: pkS);
      final b = deviceBindingChallengeV2(
          emailLower: 'a@x.in', installId: 'inst-1', pkS: pkS);
      expect(a, b); // email lowercased
      expect(a.length, 32);
      expect(
          deviceBindingChallengeV2(
              emailLower: 'b@x.in', installId: 'inst-1', pkS: pkS),
          isNot(a));
      expect(
          deviceBindingChallengeV2(
              emailLower: 'a@x.in', installId: 'inst-2', pkS: pkS),
          isNot(a));
      expect(
          deviceBindingChallengeV2(
              emailLower: 'a@x.in',
              installId: 'inst-1',
              pkS: randBytes(32)),
          isNot(a));
    });

    test('deviceProvePreimage binds ticket + pkS', () {
      final sess = randBytes(16), wid = randBytes(6);
      final cj = randBytes(8);
      final t1 = randBytes(8), t2 = randBytes(8);
      final pkS = randBytes(32);
      expect(
          ProxCrypto.deviceProvePreimage(
              sessionId: sess,
              windowId: wid,
              j: 1,
              challenge: cj,
              faceTicketHashBytes: t1,
              pkS: pkS),
          isNot(ProxCrypto.deviceProvePreimage(
              sessionId: sess,
              windowId: wid,
              j: 1,
              challenge: cj,
              faceTicketHashBytes: t2,
              pkS: pkS)));
    });

    test('deviceProvePreimage binds integrityHash (no silent downgrade)',
        () {
      // Security §5: the verdict hash is part of the SIGNED dSig bytes —
      // clean-device and tainted-device preimages differ, and a pre-binding
      // (hash-less) preimage never equals a bound one.
      final sess = randBytes(16), wid = randBytes(6);
      final cj = randBytes(8);
      final t = randBytes(8);
      final pkS = randBytes(32);
      Uint8List pre(String h) => ProxCrypto.deviceProvePreimage(
          sessionId: sess,
          windowId: wid,
          j: 1,
          challenge: cj,
          faceTicketHashBytes: t,
          pkS: pkS,
          integrityHash: h);
      expect(pre('00000000'), equals(pre('00000000')));
      expect(pre('00000000'), isNot(pre('deadbeef')));
      expect(pre(''), isNot(pre('00000000')));
    });
  });
}
