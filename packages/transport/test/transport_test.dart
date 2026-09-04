// Real HTTPS loop over localhost: shelf server + TLS client + binding.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';
import 'package:test/test.dart';

const _email = 'aarav@institute.ac.in';

Future<ProxServer> makeServer({
  required ed.KeyPair prof,
  required ed.KeyPair stu,
  int windowNo = 1,
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
    studentKeys: {_email: stu.publicKey},
    revokedPkHex: const {},
    sightings: ({required peerW, required expectedResponseUuid}) =>
        const RadioSighting(rssiDbm: -55, hop: 0),
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
    final server = await makeServer(prof: prof, stu: stu);
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
        name: 'Aarav S',
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

  test('replay of (ID,j) rejected; /window rate-limited; bearer enforced',
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
      final replay = await once();
      expect(replay.decision, ProveDecision.invalid);
      expect(replay.reason, 'replay-id-j');

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
}
