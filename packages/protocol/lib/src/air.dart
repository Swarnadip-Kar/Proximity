// Proximity over-the-air packet (v2): identical bytes on EVERY platform.
//
// History: v1 advertised a rotating 128-bit service UUID (challenge in the
// UUID) with the server IP optionally attached in scan-response
// manufacturer data. That split proved fragile: Apple stacks displace
// payload out of the 31B primary packet (Android then hears nothing), and
// scan responses additionally require active scanning. v2 puts everything
// in the PRIMARY advertisement packet, which every platform delivers:
//
//   Flags(3) | Complete-16-bit-SVC(4) | Mfg(2+2+18)
//
//   mfg payload v2 (18B, FROZEN byte-for-byte): 'P' 'X' ver(0x02) type(1B)
//     token(8B) ipv4(4B) portBE(2B)
//   mfg payload v3 (19B, opt-in): v2 layout + flags(1B) appended — token
//     bytes are NEVER reused for flags:
//     b0 = relayed (set by a relay re-airing a heard packet),
//     b1 = dense-hint (originator signals a dense graph),
//     b2..b7 = reserved, must be zero on transmit (non-zero drops).
//   type: 0x01 professor challenge (token=C_j, ip=HTTPS server)
//         0x02 student response   (token=R_IDj, ip echoed from heard challenge)
//
// Total v2 29B / v3 30B <= 31B. Crypto is untouched: C_j/R_IDj derivation,
// Sig_p/Sig_s verification, TTL/jitter/dedup/relay rules all stay as-is;
// only the byte transport changed (token+IP move from UUID-lo into mfg).
library;

import 'dart:typed_data';

import 'air/ipv4.dart';

/// Fixed 16-bit air service UUID (development ID — request a SIG member
/// ID before production). Full form for stack APIs:
/// 0000fcd2-0000-1000-8000-00805f9b34fb.
const int kAirSvc16 = 0xFCD2;
const String kAirSvc =
    '0000fcd2-0000-1000-8000-00805f9b34fb';

const int kAirVer = 0x02;

/// Opt-in v3 version byte (same 18B layout + 1 flags byte appended).
const int kAirVerV3 = 0x03;
const int kAirTypeChallenge = 0x01;
const int kAirTypeResponse = 0x02;

/// Sighting type for a legacy v1 IP-hint UUID (server address companion
/// to the v1 challenge — never transmitted as a v2 mfg type, only used
/// to label parsed sightings).
const int kAirTypeIpHint = 0x03;

/// Manufacturer company ID (internal use) for the air payload.
const int kAirCompanyId = 0xFFFF;

/// Manufacturer payload length v2 (magic+ver+type+token+ip+port). FROZEN.
const int kAirPayloadLen = 18;

/// Manufacturer payload length v3 (v2 + trailing flags byte). FROZEN.
const int kAirV3PayloadLen = 19;

/// v3 flag bits (trailing flags byte only — never token bytes).
const int kAirFlagRelayed = 0x01; // b0: re-aired by a relay
const int kAirFlagDenseHint = 0x02; // b1: originator signals dense graph
const int kAirFlagReservedMask = 0xFC; // b2..b7: must be zero

class AirPdu {
  final int version; // kAirVer | kAirVerV3
  final int type;
  final Uint8List token8;
  final String host;
  final int port;
  /// v3 flags (false on v2 sightings — v2 has no flags byte).
  final bool relayed;
  final bool denseHint;
  const AirPdu({
    this.version = kAirVer,
    required this.type,
    required this.token8,
    required this.host,
    required this.port,
    this.relayed = false,
    this.denseHint = false,
  }) : assert(token8.length == 8);

  bool get isChallenge => type == kAirTypeChallenge;
  bool get isResponse => type == kAirTypeResponse;
  /// Token-keyed identity (version/flags EXCLUDED on purpose): the same
  /// rotation token heard as v2-direct and v3-relayed is ONE packet for
  /// relay-dedup — otherwise each re-air format would relay again
  /// (hall-wide storm). See tokenRelayGuard (engine) vs LruDedup
  /// (sender-keyed mesh PDU dedup): two dedup domains, different keys.
  String get key =>
      '$type:${_hex(token8)}';

  static String _hex(List<int> b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
}

/// Packs a v2 air manufacturer payload, or null when host/port unusable.
/// Byte layout FROZEN — do not change field order or widths.
Uint8List? packAir({
  required int type,
  required Uint8List token8,
  required String host,
  required int port,
}) {
  if (type != kAirTypeChallenge && type != kAirTypeResponse) return null;
  if (token8.length != 8) return null;
  if (port < 1 || port > 65535) return null;
  final ip = parseIpv4(host);
  if (ip == null || host.startsWith('127.')) return null;
  final out = Uint8List(kAirPayloadLen);
  out[0] = 0x50; // 'P'
  out[1] = 0x58; // 'X'
  out[2] = kAirVer;
  out[3] = type;
  out.setRange(4, 12, token8);
  out.setRange(12, 16, ip);
  out[16] = (port >> 8) & 0xFF;
  out[17] = port & 0xFF;
  return out;
}

/// Packs a v3 air manufacturer payload (v2 layout + flags byte), or null
/// when host/port/flags unusable. Opt-in: originators stay v2 unless they
/// explicitly need the relayed/dense-hint signals; relays preserve the
/// heard version and set [relayed] on re-air.
Uint8List? packAirV3({
  required int type,
  required Uint8List token8,
  required String host,
  required int port,
  bool relayed = false,
  bool denseHint = false,
}) {
  if (type != kAirTypeChallenge && type != kAirTypeResponse) return null;
  if (token8.length != 8) return null;
  if (port < 1 || port > 65535) return null;
  final ip = parseIpv4(host);
  if (ip == null || host.startsWith('127.')) return null;
  final out = Uint8List(kAirV3PayloadLen);
  out[0] = 0x50; // 'P'
  out[1] = 0x58; // 'X'
  out[2] = kAirVerV3;
  out[3] = type;
  out.setRange(4, 12, token8);
  out.setRange(12, 16, ip);
  out[16] = (port >> 8) & 0xFF;
  out[17] = port & 0xFF;
  out[18] = (relayed ? kAirFlagRelayed : 0) |
      (denseHint ? kAirFlagDenseHint : 0);
  return out;
}

/// Strict-length parse result: exactly one of [pdu] (accepted) or [drop]
/// (machine-readable cause for the counted visible log) is set.
({AirPdu? pdu, String? drop}) unpackAirDetailed(List<int> payload) {
  if (payload.length < kAirPayloadLen) {
    return (pdu: null, drop: 'short:${payload.length}');
  }
  if (payload[0] != 0x50 || payload[1] != 0x58) {
    return (pdu: null, drop: 'bad-magic');
  }
  final ver = payload[2];
  if (ver != kAirVer && ver != kAirVerV3) {
    return (pdu: null, drop: 'unknown-ver:$ver');
  }
  final wantLen = ver == kAirVerV3 ? kAirV3PayloadLen : kAirPayloadLen;
  if (payload.length != wantLen) {
    return (pdu: null, drop: 'bad-len:$ver:${payload.length}');
  }
  final type = payload[3];
  if (type != kAirTypeChallenge && type != kAirTypeResponse) {
    return (pdu: null, drop: 'unknown-type:$type');
  }
  final host =
      '${payload[12]}.${payload[13]}.${payload[14]}.${payload[15]}';
  final port = (payload[16] << 8) | payload[17];
  if (port < 1 || port > 65535) return (pdu: null, drop: 'bad-port:$port');
  var relayed = false;
  var denseHint = false;
  if (ver == kAirVerV3) {
    final flags = payload[18];
    if ((flags & kAirFlagReservedMask) != 0) {
      return (pdu: null, drop: 'v3-reserved:$flags');
    }
    relayed = (flags & kAirFlagRelayed) != 0;
    denseHint = (flags & kAirFlagDenseHint) != 0;
  }
  return (
    pdu: AirPdu(
      version: ver,
      type: type,
      token8: Uint8List.fromList(payload.sublist(4, 12)),
      host: host,
      port: port,
      relayed: relayed,
      denseHint: denseHint,
    ),
    drop: null,
  );
}

/// Machine-readable drop cause for [payload], or null when it parses.
/// Pure (no counting here — the scan path in AirParser counts + logs).
String? airDropCause(List<int> payload) =>
    unpackAirDetailed(payload).drop;

/// Unpacks an air manufacturer payload (v2 18B or v3 19B, strict length),
/// or null (wrong magic/ver/length/type/port, v3 reserved bits).
AirPdu? unpackAir(List<int> payload) =>
    unpackAirDetailed(payload).pdu;
