import 'dart:math';
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('LRU dedup (1000 / 5min, sender+ts+type+digest)', () {
    test('unseen once, duplicate suppressed', () {
      final d = LruDedup(capacity: 10, expiry: const Duration(minutes: 5));
      final now = DateTime.utc(2026, 9, 3, 10, 0, 0);
      expect(d.observe('a', now: now), isTrue);
      expect(d.observe('a', now: now), isFalse);
      expect(d.observe('b', now: now), isTrue);
      expect(d.size, 2);
    });

    test('expiry after 5 min allows re-observe', () {
      final d = LruDedup(capacity: 10, expiry: const Duration(minutes: 5));
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      expect(d.observe('k', now: t0), isTrue);
      expect(d.observe('k', now: t0.add(const Duration(minutes: 6))), isTrue);
    });

    test('capacity evicts oldest', () {
      final d = LruDedup(capacity: 3, expiry: const Duration(minutes: 5));
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      for (final k in ['a', 'b', 'c']) {
        expect(d.observe(k, now: t0), isTrue);
      }
      expect(d.observe('d', now: t0), isTrue);
      expect(d.size, 3);
      // 'a' evicted → unseen again
      expect(d.observe('a', now: t0), isTrue);
    });

    test('dedup key differs by sender/ts/type', () {
      final s1 = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final s2 = Uint8List.fromList([8, 7, 6, 5, 4, 3, 2, 1]);
      final dg = Uint8List.fromList(List.filled(16, 9));
      final k1 = LruDedup.keyOf(sender8: s1, ts: 100, type: 1, digest16: dg);
      final k2 = LruDedup.keyOf(sender8: s2, ts: 100, type: 1, digest16: dg);
      final k3 = LruDedup.keyOf(sender8: s1, ts: 101, type: 1, digest16: dg);
      final k4 = LruDedup.keyOf(sender8: s1, ts: 100, type: 2, digest16: dg);
      expect({k1, k2, k3, k4}.length, 4);
    });
  });

  group('mesh PDU: TTL-excluded signatures', () {
    test('encode/decode roundtrip + verify', () {
      final kp = ProxCrypto.generateEdKeypair();
      final sender = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final pdu = MeshPdu.sign(
          type: kPduTypeChallenge,
          ttl: 3,
          ts: 1756900000,
          sender8: sender,
          payload: Uint8List.fromList([9, 9, 9]),
          sk: kp.privateKey);
      final raw = pdu.encode();
      final back = MeshPdu.decode(raw);
      expect(back.ver, kPduVersion);
      expect(back.ttl, 3);
      expect(back.verifySig(kp.publicKey), isTrue);
    });

    test('relay TTL-1 keeps signature valid', () {
      final kp = ProxCrypto.generateEdKeypair();
      final pdu = MeshPdu.sign(
          type: kPduTypeChallenge,
          ttl: 3,
          ts: 1756900000,
          sender8: Uint8List.fromList(List.filled(8, 7)),
          payload: Uint8List.fromList([1, 2, 3]),
          sk: kp.privateKey);
      final r1 = pdu.relayed();
      expect(r1.ttl, 2);
      expect(r1.verifySig(kp.publicKey), isTrue);
      final r2 = r1.relayed();
      expect(r2.ttl, 1);
      expect(r2.verifySig(kp.publicKey), isTrue);
      final r3 = r2.relayed();
      expect(r3.ttl, 0);
      expect(r3.verifySig(kp.publicKey), isTrue);
      expect(() => r3.relayed(), throwsStateError);
    });

    test('tampered payload fails verify', () {
      final kp = ProxCrypto.generateEdKeypair();
      final pdu = MeshPdu.sign(
          type: kPduTypeChallenge,
          ttl: 3,
          ts: 1,
          sender8: Uint8List(8),
          payload: Uint8List.fromList([5]),
          sk: kp.privateKey);
      final raw = pdu.encode();
      raw[16] ^= 0xFF; // flip first payload byte
      final bad = MeshPdu.decode(Uint8List.fromList(raw));
      expect(bad.verifySig(kp.publicKey), isFalse);
    });
  });

  // NOTE: FloodController.shouldRelayBroadcast / shouldForwardResponse /
  // effectiveOriginateTtl / forwardJitter were deleted — the live relay
  // path is ProxBleEngine._maybeRelay with inline admission, and these
  // tested a parallel unwired design. Only relayJitter/postJitter ship.
  group('flood jitter (production path)', () {
    test('jitter ranges: 10–220ms, dense upper-half, deterministic rng', () {
      final rng = Random(42);
      for (var i = 0; i < 200; i++) {
        final j = FloodController.relayJitter(dense: false, rng: rng);
        expect(j.inMilliseconds, inInclusiveRange(10, 220));
      }
      final rng2 = Random(7);
      for (var i = 0; i < 200; i++) {
        final j = FloodController.relayJitter(dense: true, rng: rng2);
        expect(j.inMilliseconds, inInclusiveRange(115, 220));
      }
      final p = FloodController.postJitter(rng: Random(1));
      expect(p.inMilliseconds, inInclusiveRange(0, 2000));
    });

    test('multi-hop chain reaches back row (TTL 3 → 3 hops)', () {
      final kp = ProxCrypto.generateEdKeypair();
      var pdu = MeshPdu.sign(
          type: kPduTypeChallenge,
          ttl: kTtlOriginate,
          ts: 100,
          sender8: Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 1]),
          payload: Uint8List.fromList([7, 7, 7]),
          sk: kp.privateKey);
      // simulate 3 relays (front → mid → back)
      for (var hop = 0; hop < 3; hop++) {
        expect(pdu.ttl, 3 - hop);
        expect(pdu.verifySig(kp.publicKey), isTrue);
        if (hop < 3) pdu = pdu.relayed();
      }
      expect(pdu.ttl, 0);
      expect(pdu.verifySig(kp.publicKey), isTrue);
    });
  });
}
