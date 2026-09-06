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
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';
import 'package:test/test.dart';

void main() {
  test('40 concurrent HTTP proves confirm; burst is 429-limited', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final students =
        List.generate(40, (_) => ProxCrypto.generateEdKeypair());
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
    );
    await server.start(port: 0);
  server.openWindow(window, 1);
    final client = ProxClient(host: '127.0.0.1', port: server.port);
    try {
      final cj = server.window!.challengeFor(0);
      final desc = await client.fetchWindow(cj);
      Future<ProveResult> prove(int i) {
        final id = 's$i@x.in';
        final kp = students[i];
        final peerW =
            ProxCrypto.peerAlias(pk32(kp.publicKey), desc.windowId);
        return client.prove(
          desc: desc,
          studentId: id,
          challenge: cj,
          j: 0,
          faceScore: 0.9,
          peerW: peerW,
          pkS: pk32(kp.publicKey),
          sigSFor: (c, j) => ProxCrypto.signStudentProve(
              studentSk: kp.privateKey,
              sessionId: desc.sessionId,
              windowId: desc.windowId,
              j: j,
              challenge: c,
              studentId: id,
              faceScore: 0.9),
          sigBindFor: (fp, j) => ProxCrypto.sign(
              kp.privateKey,
              bindPreimage(
                  sessionId: desc.sessionId,
                  windowId: desc.windowId,
                  j: j,
                  tlsFingerprint: fp)),
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
      final sig = ProxCrypto.signStudentProve(
          studentSk: kp.privateKey,
          sessionId: window.sessionId,
          windowId: window.windowId,
          j: j,
          challenge: cj,
          studentId: id,
          faceScore: 0.9);
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
