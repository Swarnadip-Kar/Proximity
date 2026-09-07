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
//   mfg payload (18B): 'P' 'X' ver(0x02) type(1B) token(8B) ipv4(4B) portBE(2B)
//   type: 0x01 professor challenge (token=C_j, ip=HTTPS server)
//         0x02 student response   (token=R_IDj, ip echoed from heard challenge)
//
// Total 29B <= 31B. Crypto is untouched: C_j/R_IDj derivation,
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
const int kAirTypeChallenge = 0x01;
const int kAirTypeResponse = 0x02;

/// Sighting type for a legacy v1 IP-hint UUID (server address companion
/// to the v1 challenge — never transmitted as a v2 mfg type, only used
/// to label parsed sightings).
const int kAirTypeIpHint = 0x03;

/// Manufacturer company ID (internal use) for the air payload.
const int kAirCompanyId = 0xFFFF;

/// Manufacturer payload length (magic+ver+type+token+ip+port).
const int kAirPayloadLen = 18;

class AirPdu {
  final int type;
  final Uint8List token8;
  final String host;
  final int port;
  const AirPdu({
    required this.type,
    required this.token8,
    required this.host,
    required this.port,
  }) : assert(token8.length == 8);

  bool get isChallenge => type == kAirTypeChallenge;
  bool get isResponse => type == kAirTypeResponse;
  String get key =>
      '$type:${_hex(token8)}';

  static String _hex(List<int> b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
}

/// Packs an air manufacturer payload, or null when host/port unusable.
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

/// Unpacks an air manufacturer payload, or null (wrong magic/ver/length).
AirPdu? unpackAir(List<int> payload) {
  if (payload.length < kAirPayloadLen) return null;
  if (payload[0] != 0x50 || payload[1] != 0x58 || payload[2] != kAirVer) {
    return null;
  }
  final type = payload[3];
  if (type != kAirTypeChallenge && type != kAirTypeResponse) return null;
  final host =
      '${payload[12]}.${payload[13]}.${payload[14]}.${payload[15]}';
  final port = (payload[16] << 8) | payload[17];
  if (port < 1 || port > 65535) return null;
  return AirPdu(
    type: type,
    token8: Uint8List.fromList(payload.sublist(4, 12)),
    host: host,
    port: port,
  );
}
