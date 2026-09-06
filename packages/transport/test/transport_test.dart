// Real HTTPS loop over localhost: shelf server + TLS client + binding.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';
import 'package:test/test.dart';

const _email = 'student@example.com';

Future<ProxServer> makeServer({
  required ed.KeyPair prof,
  required ed.KeyPair stu,
  int windowNo = 1,
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
  );
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

  test('full loop: window -> prove -> confirmed -> ACK verifies', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
    final proved = <String>[];
    final server =
        await makeServer(prof: prof, stu: stu, onProve: (e, d, r) {
      proved.add('$e $d $r');
    });
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      // Radio: student heard UUID_P(0) over BLE (fake radio in test).
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      expect(desc.display, server.window!.displayCode);

      final peerW = ProxCrypto.peerAlias(pk32(stu.publicKey), desc.windowId);
      const face = 0.85;
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
      expect(res.decision, ProveDecision.confirmed);
      expect(proved, ['$_email confirmed ok']);
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

  Future<ProveResult> proveOnce(
    ProxClient client,
    WindowDescriptor desc,
    Uint8List cj,
    int j,
    ed.KeyPair stu, {
    double face = 0.85,
  }) {
    final peerW = ProxCrypto.peerAlias(pk32(stu.publicKey), desc.windowId);
    return client.prove(
      desc: desc,
      studentId: _email,
      challenge: cj,
      j: j,
      faceScore: face,
      peerW: peerW,
      pkS: pk32(stu.publicKey),
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
      ),
      sigBindFor: (fp, jj) => ProxCrypto.sign(
          stu.privateKey,
          bindPreimage(
              sessionId: desc.sessionId,
              windowId: desc.windowId,
              j: jj,
              tlsFingerprint: fp)),
    );
  }

  test('late radio sighting still confirms within grace', () async {
    // The POST routinely beats the host BLE scan: a crypto-valid POST
    // with no sighting yet waits for the radio instead of instantly
    // failing (observed live: valid POST -> no-ble-sighting, response
    // heard 43ms later).
    final prof = ProxCrypto.generateEdKeypair();
    final stu = ProxCrypto.generateEdKeypair();
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
    )..sightingGrace = const Duration(seconds: 2);
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
      final res = await proveOnce(client, desc, cj, desc.jNow, stu);
      expect(res.decision, ProveDecision.confirmed);
      expect(server.tally.presentCount, 1);
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('absent sighting still invalid after grace', () async {
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
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) => null,
    )..sightingGrace = const Duration(milliseconds: 300);
    await server.start(port: 0);
    server.openWindow(window, 1);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = window.challengeFor(window.jForTime(DateTime.now().toUtc()));
      final desc = await client.fetchWindow(cj);
      final res = await proveOnce(client, desc, cj, desc.jNow, stu);
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
      // Simulate the fetch landing one 5s tick after the hear: the radio
      // copy is C_0 but /window already signs C_1.
      server.openWindow(
        WindowParams(
          sessionId: server.window!.sessionId,
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc().subtract(const Duration(seconds: 6)),
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
    final server = await makeServer(prof: prof, stu: stu);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      final peerW = ProxCrypto.peerAlias(pk32(stu.publicKey), desc.windowId);
      const face = 0.9;
      Future<ProveResult> once() => client.prove(
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
    final server = ProxServer(
      classLabel: 'CS201-Room301',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: (
              {required peerW,
              required expectedAirKey,
              required expectedUuid}) =>
          const RadioSighting(rssiDbm: -55, hop: 0),
    );
    await server.start(port: 0);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    Future<ProveResult> proveAt(int j) async {
      final cj = server.window!.challengeFor(j);
      final desc = await client.fetchWindow(cj);
      final peerW = ProxCrypto.peerAlias(pk32(stu.publicKey), desc.windowId);
      const face = 0.9;
      return client.prove(
        desc: desc,
        studentId: _email,
        challenge: cj,
        j: j,
        faceScore: face,
        peerW: peerW,
        pkS: pk32(stu.publicKey),
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
        ),
        sigBindFor: (fp, jj) => ProxCrypto.sign(
            stu.privateKey,
            bindPreimage(
                sessionId: desc.sessionId,
                windowId: desc.windowId,
                j: jj,
                tlsFingerprint: fp)),
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
          t0: DateTime.now().toUtc().subtract(const Duration(seconds: 6)),
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
    final server = await makeServer(prof: prof, stu: stu);
    try {
      // Attacker runs their own server; student is tricked into binding the
      // ATTACKER's fingerprint, but the POST goes to the real professor.
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
        ),
        faceScore: face,
        peerW: peerW,
        pkS: pk32(stu.publicKey),
        tlsFp: evilFp, // what the victim saw through the relay
        sigBind: ProxCrypto.sign(
            stu.privateKey,
            bindPreimage(
                sessionId: server.window!.sessionId,
                windowId: server.window!.windowId,
                j: 0,
                tlsFingerprint: evilFp)),
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
    final server = await makeServer(prof: prof, stu: stu);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      final peerW = ProxCrypto.peerAlias(pk32(stu.publicKey), desc.windowId);
      Future<ProveResult> once() => client.prove(
            desc: desc,
            studentId: _email,
            challenge: cj,
            j: 0,
            faceScore: 0.9,
            peerW: peerW,
        pkS: pk32(stu.publicKey),
            sigSFor: (c, j) => ProxCrypto.signStudentProve(
              studentSk: stu.privateKey,
              sessionId: desc.sessionId,
              windowId: desc.windowId,
              j: j,
              challenge: c,
              studentId: _email,
              faceScore: 0.9,
            ),
            sigBindFor: (fp, j) => ProxCrypto.sign(
                stu.privateKey,
                bindPreimage(
                    sessionId: desc.sessionId,
                    windowId: desc.windowId,
                    j: j,
                    tlsFingerprint: fp)),
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
    final server = await makeServer(prof: prof, stu: stu);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    Future<ProveResult> proveOnce(int j) async {
      final cj = server.window!.challengeFor(j);
      final desc = await client.fetchWindow(cj);
      final peerW = ProxCrypto.peerAlias(pk32(stu.publicKey), desc.windowId);
      return client.prove(
        desc: desc,
        studentId: _email,
        challenge: cj,
        j: j,
        faceScore: 0.9,
        peerW: peerW,
        pkS: pk32(stu.publicKey),
        sigSFor: (c, jj) => ProxCrypto.signStudentProve(
          studentSk: stu.privateKey,
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
      await client.postWaiting(
          email: _email, name: 'Student One', roll: '12342210');
      await client.postWaiting(
          email: 'student2@example.com', name: 'Student Two');
      expect(server.waitingCount, 2);
      await client.postLeave(email: _email);
      expect(server.waitingCount, 1);
      expect(server.waitingRows.single.email, 'student2@example.com');
      // Leaving twice / unknown email is a no-op, never an error.
      await client.postLeave(email: _email);
      await client.postLeave(email: 'ghost@institute.ac.in');
      expect(server.waitingCount, 1);
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
      expect(j, greaterThan(30)); // long past the old 30s expiry
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
      double faceScore = 0.9,
    }) {
      final peerW = ProxCrypto.peerAlias(pk32(stu.publicKey), desc.windowId);
      return client.prove(
        desc: desc,
        studentId: _email,
        challenge: challenge,
        j: j,
        faceScore: faceScore,
        peerW: peerW,
        pkS: pk32(stu.publicKey),
        sigSFor: (c, jj) => ProxCrypto.signStudentProve(
          studentSk: stu.privateKey,
          sessionId: desc.sessionId,
          windowId: desc.windowId,
          j: jj,
          challenge: c,
          studentId: _email,
          faceScore: faceScore,
        ),
        sigBindFor: (fp, jj) => ProxCrypto.sign(
            stu.privateKey,
            bindPreimage(
                sessionId: desc.sessionId,
                windowId: desc.windowId,
                j: jj,
                tlsFingerprint: fp)),
      );
    }

    test('retake: same (ID,j) provable again under a new windowId', () async {
      // The single-use scope is (windowId, ID, j): a stale-window POST
      // that fails window-mismatch must not burn the new window's slot.
      final prof = ProxCrypto.generateEdKeypair();
      final stu = ProxCrypto.generateEdKeypair();
      final server = await makeServer(prof: prof, stu: stu);
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj1 = server.window!.challengeFor(0);
        final desc1 = await client.fetchWindow(cj1);
        expect(
            (await proveAs(client,
                    desc: desc1, stu: stu, challenge: cj1, j: 0))
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
            desc: desc2, stu: stu, challenge: cj2, j: 0);
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
      final server = await makeServer(prof: prof, stu: stu);
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
            desc: descLive, stu: stu, challenge: cj0, j: 0);
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
      final server = await makeServer(prof: prof, stu: stu);
      try {
        // Round 1 marked, round 2 opened and closed empty, round 3 live.
        final cj = server.window!.challengeFor(0);
        final client = ProxClient(host: '127.0.0.1', port: server.port);
        final desc = await client.fetchWindow(cj);
        await proveAs(client, desc: desc, stu: stu, challenge: cj, j: 0);
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
      final server = await makeServer(prof: prof, stu: stu);
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await client.fetchWindow(cj);
        final res = await proveAs(client,
            desc: desc, stu: stu, challenge: cj, j: 0);
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
}
