// End-to-end mark + export verify + adversarial checks.
// Covers P0 acceptance: BLE heard → face (mocked) → signed POST → ACK → CSV+SIG.
import 'dart:convert';
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('verifyProve (professor per-POST + BLE sighting)', () {
    Future<(Uint8List, Uint8List, dynamic, dynamic)> setup() async {
      final prof = ProxCrypto.generateEdKeypair();
      final stu = ProxCrypto.generateEdKeypair();
      final sess = randBytes(16);
      final wid = randBytes(6);
      return (sess, wid, prof, stu);
    }

    // Fresh bound request (liveness + FULL tier): the only shape that
    // confirms. Sighting tests use it so the asserted reasons pin the
    // radio gate, not an earlier legacy reject.
    (Uint8List, VerifyRequest) freshSig(
      dynamic stu,
      Uint8List sess,
      Uint8List wid,
      int j,
      Uint8List cj,
      String id,
      double face, {
      int hop = 0,
      int rssi = -55,
    }) {
      final now = DateTime.now().toUtc();
      final ticket = ProxCrypto.faceTicketHash(
        faceScore: face,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: 'face_verification/test+deadbeef',
        livenessScore: 0.92,
        livenessVer: 'liveness/minifasnet-v2-test+a1b2c3d4',
      );
      final sig = ProxCrypto.signStudentProve(
        studentSk: stu.privateKey,
        sessionId: sess,
        windowId: wid,
        j: j,
        challenge: cj,
        studentId: id,
        faceScore: face,
        faceValidAtMs: now.millisecondsSinceEpoch,
        verifierVer: 'face_verification/test+deadbeef',
        livenessScore: 0.92,
        livenessVer: 'liveness/minifasnet-v2-test+a1b2c3d4',
      );
      return (
        cj,
        VerifyRequest(
          id: id,
          windowId: wid,
          j: j,
          cClaimed: cj,
          sigS: sig,
          faceScore: face,
          faceValidAt: now,
          peerW: Uint8List(8),
          rssiDbm: rssi,
          relayHop: hop,
          now: now,
          verifierVer: 'face_verification/test+deadbeef',
          faceValidAtMs: now.millisecondsSinceEpoch,
          faceTicketHashBytes: ticket,
          livenessScore: 0.92,
          livenessVer: 'liveness/minifasnet-v2-test+a1b2c3d4',
          attestationLevel: AttestationLevel.full,
          attestedAt: now.subtract(const Duration(days: 1)),
          attestedUntil: now.add(const Duration(days: 89)),
          dSigValid: true,
        ),
      );
    }

    test('happy path: direct sighting confirms', () async {
      final (sess, wid, _, stu) = await setup();
      final sw = randBytes(32);
      const j = 1;
      const id = '12342210';
      final cj = ProxCrypto.challengeForSubEpoch(sw, wid, j);
      const face = 0.82;
      final (_, req) = freshSig(stu, sess, wid, j, cj, id, face);
      final out = verifyProve(
        req: req,
        expectedCj: cj,
        sessionId: sess,
        windowIdExpected: wid,
        studentPk: stu.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: true,
      );
      expect(out.decision, ProveDecision.confirmed);
    });

    test('relayed hop<=2 confirms (flagged); hop>2 rejects', () async {
      final (sess, wid, _, stu) = await setup();
      final sw = randBytes(32);
      const j = 0;
      const id = '1';
      final cj = ProxCrypto.challengeForSubEpoch(sw, wid, j);
      const face = 0.9;
      VerifyOutcome v(int hop, int rssi) {
        final (_, req) = freshSig(stu, sess, wid, j, cj, id, face,
            hop: hop, rssi: rssi);
        return verifyProve(
          req: req,
          expectedCj: cj,
          sessionId: sess,
          windowIdExpected: wid,
          studentPk: stu.publicKey,
          revoked: false,
          freshWindow: true,
          singleUseOk: true,
        );
      }

      expect(v(1, -75).decision, ProveDecision.confirmed);
      expect(v(2, -78).decision, ProveDecision.confirmed);
      expect(v(3, -70).decision, ProveDecision.invalid);
      expect(v(0, -75).decision, ProveDecision.invalid,
          reason: 'direct needs RSSI > -70');
    });

    test('rate limits: /prove 40/10s, /window 5/10s', () {
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      final prove = proveLimiter();
      for (var i = 0; i < 40; i++) {
        expect(prove.allow('1.2.3.4', t0.add(Duration(milliseconds: i * 10))),
            isTrue);
      }
      expect(prove.allow('1.2.3.4', t0.add(const Duration(seconds: 1))), isFalse);
      // different IP unaffected
      expect(prove.allow('5.6.7.8', t0), isTrue);
      final win = windowLimiter();
      for (var i = 0; i < 5; i++) {
        expect(win.allow('1.2.3.4', t0), isTrue);
      }
      expect(win.allow('1.2.3.4', t0), isFalse);
    });

    test('rate limiter memory is bounded (evict oldest, prune empties)', () {
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      final lim = RateLimiter(maxHits: 40, window: const Duration(seconds: 10));
      for (var i = 0; i < RateLimiter.maxKeys + 100; i++) {
        expect(lim.allow('10.0.0.$i', t0), isTrue);
      }
      expect(lim.keyCount, RateLimiter.maxKeys);
      // The earliest buckets were evicted: re-admitted as fresh.
      expect(lim.allow('10.0.0.0', t0), isTrue);
      expect(lim.keyCount, RateLimiter.maxKeys);
      // Expired buckets never linger: after the window, a denied-then-
      // expired key re-admits without growing the map.
      final small = RateLimiter(maxHits: 1, window: const Duration(seconds: 10));
      expect(small.allow('a', t0), isTrue);
      expect(small.allow('a', t0.add(const Duration(seconds: 1))), isFalse);
      expect(small.allow('a', t0.add(const Duration(seconds: 11))), isTrue);
      expect(small.keyCount, 1);
    });

    test('CSV export + detached sig verifies; tamper fails', () async {
      final prof = ProxCrypto.generateEdKeypair();
      final csv = buildAttendanceCsv(
        classLabel: 'CS201-Room301',
        dateIso: '2026-09-03',
        w1: {
          'student@example.com': true,
          'student2@example.com': false
        },
        w2: {
          'student@example.com': true,
          'student2@example.com': true
        },
        names: {'student@example.com': 'Student One', 'student2@example.com': 'Student Two'},
        rolls: {'student@example.com': '12342210'},
      );
      expect(csv, contains('Name,ID Number,Email,W1,W2,Status'));
      expect(csv,
          contains('Student One,12342210,student@example.com,1,1,Present'));
      expect(csv,
          contains('Student Two,,student2@example.com,0,1,Partial'));
      final sig = signExport(prof.privateKey, csv);
      expect(verifyExport(prof.publicKey, csv, sig), isTrue);
      expect(verifyExport(prof.publicKey, '$csv\n', sig), isFalse);
      // lenient 1/2 mode
      final csvLenient = buildAttendanceCsv(
        classLabel: 'CS201',
        dateIso: '2026-09-03',
        w1: {'A': false},
        w2: {'A': true},
        names: {'A': 'A'},
        lenientOneOfTwo: true,
      );
      expect(csvLenient, contains('Present'));
    });
  });

  group('adversarial checks (must all reject)', () {
    test('stale code rejected (off-window replay)', () async {
      final stu = ProxCrypto.generateEdKeypair();
      final sess = randBytes(16), wid = randBytes(6), sw = randBytes(32);
      const j = 0;
      final cj = ProxCrypto.challengeForSubEpoch(sw, wid, j);
      final sig = ProxCrypto.signStudentProve(
          studentSk: stu.privateKey,
          sessionId: sess,
          windowId: wid,
          j: j,
          challenge: cj,
          studentId: 'S1',
          faceScore: 0.9);
      final now = DateTime.now().toUtc();
      final mk = (bool fresh, bool once) => verifyProve(
            req: VerifyRequest(
                id: 'S1',
                windowId: wid,
                j: j,
                cClaimed: cj,
                sigS: sig,
                faceScore: 0.9,
                faceValidAt: now,
                peerW: Uint8List(8),
                rssiDbm: -50,
                relayHop: 0,
                now: now),
            expectedCj: cj,
            sessionId: sess,
            windowIdExpected: wid,
            studentPk: stu.publicKey,
            revoked: false,
            freshWindow: fresh,
            singleUseOk: once,
          ).decision;
      expect(mk(false, true), ProveDecision.late); // stale sub-epoch
      expect(mk(true, false), ProveDecision.invalid); // (ID,j) replay
    });

    test('wrong-face no-sign (face below threshold)', () async {
      final stu = ProxCrypto.generateEdKeypair();
      final sess = randBytes(16), wid = randBytes(6), sw = randBytes(32);
      const j = 2;
      final cj = ProxCrypto.challengeForSubEpoch(sw, wid, j);
      final sig = ProxCrypto.signStudentProve(
          studentSk: stu.privateKey,
          sessionId: sess,
          windowId: wid,
          j: j,
          challenge: cj,
          studentId: 'S1',
          faceScore: 0.3);
      final now = DateTime.now().toUtc();
      final out = verifyProve(
        req: VerifyRequest(
            id: 'S1',
            windowId: wid,
            j: j,
            cClaimed: cj,
            sigS: sig,
            faceScore: 0.3,
            faceValidAt: now,
            peerW: Uint8List(8),
            rssiDbm: -50,
            relayHop: 0,
            now: now),
        expectedCj: cj,
        sessionId: sess,
        windowIdExpected: wid,
        studentPk: stu.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: true,
      );
      expect(out.decision, ProveDecision.invalid);
      expect(out.reason, 'face-below-threshold');
    });

    test('copied ID fails (wrong key)', () async {
      final stu = ProxCrypto.generateEdKeypair();
      final attacker = ProxCrypto.generateEdKeypair();
      final sess = randBytes(16), wid = randBytes(6), sw = randBytes(32);
      const j = 1;
      final cj = ProxCrypto.challengeForSubEpoch(sw, wid, j);
      // attacker signs with THEIR key but victim ID
      final sig = ProxCrypto.signStudentProve(
          studentSk: attacker.privateKey,
          sessionId: sess,
          windowId: wid,
          j: j,
          challenge: cj,
          studentId: 'VICTIM',
          faceScore: 0.9);
      final now = DateTime.now().toUtc();
      final out = verifyProve(
        req: VerifyRequest(
            id: 'VICTIM',
            windowId: wid,
            j: j,
            cClaimed: cj,
            sigS: sig,
            faceScore: 0.9,
            faceValidAt: now,
            peerW: Uint8List(8),
            rssiDbm: -50,
            relayHop: 0,
            now: now),
        expectedCj: cj,
        sessionId: sess,
        windowIdExpected: wid,
        studentPk: stu.publicKey, // enrolled victim key
        revoked: false,
        freshWindow: true,
        singleUseOk: true,
      );
      expect(out.decision, ProveDecision.invalid);
    });

    test('fake-prof rejected (student verifies Cert_p + Sig_p)', () {
      // Cert_p = Sign(SK_inst, PK_p || email); student checks against
      // pinned institute key before signing anything.
      Uint8List certFor(Uint8List pk32, String email) =>
          concat([pk32, utf8.encode(email)]);
      final inst = ProxCrypto.generateEdKeypair();
      final realProf = ProxCrypto.generateEdKeypair();
      final fakeProf = ProxCrypto.generateEdKeypair();
      final pkReal =
          Uint8List.fromList(realProf.publicKey.bytes.sublist(0, 32));
      final cert = ProxCrypto.sign(
          inst.privateKey, certFor(pkReal, 'prof@institute.ac.in'));
      final pkFake =
          Uint8List.fromList(fakeProf.publicKey.bytes.sublist(0, 32));
      expect(
          ProxCrypto.verify(inst.publicKey,
              certFor(pkFake, 'prof@institute.ac.in'), cert),
          isFalse);
      expect(
          ProxCrypto.verify(inst.publicKey,
              certFor(pkReal, 'prof@institute.ac.in'), cert),
          isTrue);
      expect(
          ProxCrypto.verify(inst.publicKey,
              certFor(pkReal, 'evil@evil.com'), cert),
          isFalse);
    });

    test('forwarded C_j from older sub-epoch fails (bad-challenge)', () async {
      final stu = ProxCrypto.generateEdKeypair();
      final sess = randBytes(16), wid = randBytes(6), sw = randBytes(32);
      final cOld = ProxCrypto.challengeForSubEpoch(sw, wid, 0);
      final cNow = ProxCrypto.challengeForSubEpoch(sw, wid, 4);
      final sig = ProxCrypto.signStudentProve(
          studentSk: stu.privateKey,
          sessionId: sess,
          windowId: wid,
          j: 4,
          challenge: cOld, // screenshot-forwarded stale secret, new j
          studentId: 'S1',
          faceScore: 0.9);
      final now = DateTime.now().toUtc();
      final out = verifyProve(
        req: VerifyRequest(
            id: 'S1',
            windowId: wid,
            j: 4,
            cClaimed: cOld,
            sigS: sig,
            faceScore: 0.9,
            faceValidAt: now,
            peerW: Uint8List(8),
            rssiDbm: -50,
            relayHop: 0,
            now: now),
        expectedCj: cNow,
        sessionId: sess,
        windowIdExpected: wid,
        studentPk: stu.publicKey,
        revoked: false,
        freshWindow: true,
        singleUseOk: true,
      );
      expect(out.decision, ProveDecision.invalid);
    });

    test('revoked key rejected even with valid sig', () async {
      final stu = ProxCrypto.generateEdKeypair();
      final sess = randBytes(16), wid = randBytes(6), sw = randBytes(32);
      const j = 0;
      final cj = ProxCrypto.challengeForSubEpoch(sw, wid, j);
      final sig = ProxCrypto.signStudentProve(
          studentSk: stu.privateKey,
          sessionId: sess,
          windowId: wid,
          j: j,
          challenge: cj,
          studentId: 'S1',
          faceScore: 0.9);
      final now = DateTime.now().toUtc();
      final out = verifyProve(
        req: VerifyRequest(
            id: 'S1',
            windowId: wid,
            j: j,
            cClaimed: cj,
            sigS: sig,
            faceScore: 0.9,
            faceValidAt: now,
            peerW: Uint8List(8),
            rssiDbm: -50,
            relayHop: 0,
            now: now),
        expectedCj: cj,
        sessionId: sess,
        windowIdExpected: wid,
        studentPk: stu.publicKey,
        revoked: true,
        freshWindow: true,
        singleUseOk: true,
      );
      expect(out.decision, ProveDecision.invalid);
      expect(out.reason, 'revoked');
    });
  });
}
