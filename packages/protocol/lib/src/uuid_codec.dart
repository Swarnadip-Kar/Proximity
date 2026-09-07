// UUID-only over-air encoding per §5.2 (universal: Android/iOS/macOS/Windows/Linux).
//
//   UUID_P(j)    = BaseP64 || C_j            (professor challenge, 5s rotation)
//   UUID_S(ID,j) = BaseS64 || R_IDj          (student response, 5s rotation)
//
// Fixed PROX_SVC always advertised alongside for scan filtering.
// Scan-response carries peerW(ID) 8 bytes (no stable MAC, no cross-lecture link).
library;

import 'dart:typed_data';

import 'air/ipv4.dart';
import 'bytes.dart';
import 'constants.dart';

class UuidCodec {
  UuidCodec._();

  /// Pack 16 bytes (hi64 || lo64) into canonical UUID string 8-4-4-4-12.
  static String pack(int hi64, Uint8List lo8) {
    assert(lo8.length == 8);
    final b = Uint8List(16);
    final bd = ByteData.sublistView(b);
    bd.setUint64(0, hi64, Endian.big);
    b.setRange(8, 16, lo8);
    final h = hexEncode(b);
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20, 32)}';
  }

  /// Unpack canonical UUID string into 16 bytes. Dashes are the UUID
  /// layer's own separators — stripped explicitly HERE, never by the
  /// strict hex decoder (which rejects anything but [0-9a-fA-F]).
  static Uint8List unpack(String uuid) =>
      hexDecode(uuid.replaceAll('-', ''));

  static int hi64Of(String uuid) => u64beDecode(unpack(uuid), 0);
  static Uint8List lo8Of(String uuid) =>
      Uint8List.fromList(unpack(uuid).sublist(8, 16));

  /// Professor rotating challenge UUID.
  static String packChallenge(Uint8List challenge8) {
    assert(challenge8.length == 8);
    return pack(kBaseP64, challenge8);
  }

  /// Student rotating response UUID.
  static String packResponse(Uint8List response8) {
    assert(response8.length == 8);
    return pack(kBaseS64, response8);
  }

  /// Server-address hint UUID (legacy v1 companion to the challenge).
  /// Same Apple-safe single-UUID layout: hi64 = [kBaseI64], lo =
  /// IPv4(4B) + port BE16 + 2 reserved bytes. Lets Apple-originated hosts
  /// (whose attached manufacturer data never survives the air) publish
  /// their HTTPS address through the mesh: originators alternate
  /// challenge / IP-hint ticks, students treat the hint like a BLE IP
  /// hint (unverified routability, join gates unchanged), relays preserve
  /// it verbatim. Returns null when host/port unusable.
  static String? packIpHint(String host, int port) {
    if (port < 1 || port > 65535) return null;
    final ip = parseIpv4(host);
    if (ip == null) return null;
    final lo = Uint8List(8);
    lo.setRange(0, 4, ip);
    if (lo[0] == 0 || lo[0] == 127) return null;
    lo[4] = (port >> 8) & 0xFF;
    lo[5] = port & 0xFF;
    return pack(kBaseI64, lo);
  }

  static bool isIpHintUuid(String uuid) {
    try {
      return hi64Of(uuid) == kBaseI64;
    } catch (_) {
      return false;
    }
  }

  /// Unpacks an IP-hint UUID to host/port, or null (wrong prefix, bad
  /// port, unusable address).
  static ({String host, int port})? unpackIpHint(String uuid) {
    try {
      if (!isIpHintUuid(uuid)) return null;
      final lo = lo8Of(uuid);
      final port = (lo[4] << 8) | lo[5];
      if (port < 1 || port > 65535) return null;
      if (lo[0] == 0 || lo[0] == 127) return null;
      return (host: '${lo[0]}.${lo[1]}.${lo[2]}.${lo[3]}', port: port);
    } catch (_) {
      return null;
    }
  }

  static bool isChallengeUuid(String uuid) {
    try {
      return hi64Of(uuid) == kBaseP64;
    } catch (_) {
      return false;
    }
  }

  static bool isResponseUuid(String uuid) {
    try {
      return hi64Of(uuid) == kBaseS64;
    } catch (_) {
      return false;
    }
  }

  /// Normalize for comparison (lowercase, no braces).
  static String normalize(String uuid) =>
      uuid.trim().toLowerCase().replaceAll(RegExp(r'[{}]'), '');
}
