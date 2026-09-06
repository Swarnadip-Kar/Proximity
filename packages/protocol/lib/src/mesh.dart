// Mesh relay: BitChat controlled flood reduced to lecture-hall minimum. §6.2, §10.
//
// Rules:
//  - Only professor challenge PDUs are broadcast-relayed.
//  - Relay iff TTL>0, unseen (LRU), RSSI > -80 dBm.
//  - Wait jitter 10–220ms (wider when dense), re-advertise same UUID_P TTL-1,
//    never back to ingress link (split horizon).
//  - Originate TTL=3, dense graphs cap at 2.
//  - Response relay: directed GATT write only, hop<2, TTL-1, tight jitter,
//    never broadcast-flood.
//  - LRU dedup 1000/5min keyed sender+ts+type+digest (BitChat parity).
//
// PDU framing (§5.2):
//   ver(1) | type(1) | TTL(1) | ts(4 BE unix-s) | flags(1) | sender8 | payload | sig64
// Signatures EXCLUDE the TTL byte (relays decrement without invalidating).
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';

/// LRU seen-set with 5-min expiry. Key: sender+ts+type+digest.
class LruDedup {
  final int capacity;
  final Duration expiry;
  final Map<String, DateTime> _map = {};
  final List<String> _order = [];

  LruDedup({this.capacity = kDedupCapacity, this.expiry = kDedupExpiry});

  static String keyOf({
    required List<int> sender8,
    required int ts,
    required int type,
    required List<int> digest16,
  }) =>
      '${hexEncode(sender8)}|$ts|$type|${hexEncode(digest16)}';

  static Uint8List digestOf(List<int> payloadSig) =>
      ProxCrypto.sha256Sync(payloadSig).sublist(0, 16);

  bool _isExpired(String k, DateTime now) {
    final t = _map[k];
    if (t == null) return true;
    return now.difference(t) > expiry;
  }

  void _evictExpired(DateTime now) {
    _order.removeWhere((k) {
      if (_isExpired(k, now)) {
        _map.remove(k);
        return true;
      }
      return false;
    });
  }

  /// Returns true if unseen (and records). False if duplicate.
  bool observe(String key, {DateTime? now}) {
    final n = (now ?? DateTime.now()).toUtc();
    _evictExpired(n);
    if (_map.containsKey(key) && !_isExpired(key, n)) {
      // refresh LRU position
      _order.remove(key);
      _order.add(key);
      return false;
    }
    _map[key] = n;
    _order.add(key);
    while (_order.length > capacity) {
      final old = _order.removeAt(0);
      _map.remove(old);
    }
    return true;
  }

  bool contains(String key, {DateTime? now}) {
    final n = (now ?? DateTime.now()).toUtc();
    final t = _map[key];
    if (t == null) return false;
    if (n.difference(t) > expiry) {
      _map.remove(key);
      _order.remove(key);
      return false;
    }
    return true;
  }

  int get size => _map.length;
}

/// Mesh PDU with TTL-excluded Ed25519 signature.
class MeshPdu {
  final int ver;
  final int type;
  final int ttl;
  final int ts; // unix seconds BE32
  final int flags;
  final Uint8List sender8;
  final Uint8List payload;
  final Uint8List sig64;

  MeshPdu({
    this.ver = kPduVersion,
    required this.type,
    required this.ttl,
    required this.ts,
    this.flags = 0,
    required this.sender8,
    required this.payload,
    required this.sig64,
  })  : assert(sender8.length == 8),
        assert(sig64.length == 64);

  /// Bytes covered by signature (everything except TTL).
  Uint8List signedBytes() {
    final h = ByteData(4)..setUint32(0, ts, Endian.big);
    return concat([
      [ver, type],
      h.buffer.asUint8List(),
      [flags],
      sender8,
      payload,
    ]);
  }

  Uint8List encode() {
    final h = ByteData(4)..setUint32(0, ts, Endian.big);
    return concat([
      [ver, type, ttl],
      h.buffer.asUint8List(),
      [flags],
      sender8,
      payload,
      sig64,
    ]);
  }

  static MeshPdu decode(Uint8List raw) {
    if (raw.length < 1 + 1 + 1 + 4 + 1 + 8 + 64) {
      throw FormatException('PDU too short: ${raw.length}');
    }
    final ver = raw[0], type = raw[1], ttl = raw[2];
    final ts = ByteData.sublistView(raw, 3, 7).getUint32(0, Endian.big);
    final flags = raw[7];
    final sender8 = Uint8List.fromList(raw.sublist(8, 16));
    final sig64 = Uint8List.fromList(raw.sublist(raw.length - 64));
    final payload = Uint8List.fromList(raw.sublist(16, raw.length - 64));
    return MeshPdu(
        ver: ver,
        type: type,
        ttl: ttl,
        ts: ts,
        flags: flags,
        sender8: sender8,
        payload: payload,
        sig64: sig64);
  }

  /// Sign + build (TTL excluded from sig).
  static MeshPdu sign({
    required int type,
    required int ttl,
    required int ts,
    int flags = 0,
    required Uint8List sender8,
    required Uint8List payload,
    required ed.PrivateKey sk,
  }) {
    final tmp = MeshPdu(
        type: type,
        ttl: ttl,
        ts: ts,
        flags: flags,
        sender8: sender8,
        payload: payload,
        sig64: Uint8List(64));
    final sig = ProxCrypto.sign(sk, tmp.signedBytes());
    return MeshPdu(
        type: type,
        ttl: ttl,
        ts: ts,
        flags: flags,
        sender8: sender8,
        payload: payload,
        sig64: sig);
  }

  bool verifySig(ed.PublicKey pk) => ProxCrypto.verify(pk, signedBytes(), sig64);

  /// Relay copy with TTL-1 (signature stays valid — TTL excluded).
  MeshPdu relayed() {
    if (ttl <= 0) throw StateError('TTL exhausted');
    return MeshPdu(
        ver: ver,
        type: type,
        ttl: ttl - 1,
        ts: ts,
        flags: flags,
        sender8: sender8,
        payload: payload,
        sig64: sig64);
  }

  String dedupKey() => LruDedup.keyOf(
      sender8: sender8,
      ts: ts,
      type: type,
      digest16: LruDedup.digestOf(concat([payload, sig64])));
}

/// Flood admission + jitter + split-horizon. §6.2.
///
/// NOTE: the live relay path is ProxBleEngine._maybeRelay (packages/ble),
/// which implements its own admission inline. The MeshPdu/LruDedup policy
/// helpers below are the tested spec reference — only [relayJitter] and
/// [postJitter] are called in production.
class FloodController {
  final LruDedup dedup;
  FloodController({LruDedup? dedup}) : dedup = dedup ?? LruDedup();

  /// Jitter 10–220ms; wider (upper half) when dense. Deterministic under [rng].
  static Duration relayJitter({required bool dense, Random? rng}) {
    final r = rng ?? Random.secure();
    if (!dense) {
      return Duration(
          milliseconds: kJitterMinMs +
              r.nextInt(kJitterMaxMs - kJitterMinMs + 1));
    }
    // dense: bias to upper half to desynchronize herd
    const mid = (kJitterMinMs + kJitterMaxMs) ~/ 2;
    return Duration(
        milliseconds: mid + r.nextInt(kJitterMaxMs - mid + 1));
  }

  /// POST herd-spread jitter 0–2s. §9.
  static Duration postJitter({Random? rng}) {
    final r = rng ?? Random.secure();
    return Duration(milliseconds: r.nextInt(2001));
  }
}
