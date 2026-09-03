// UUID-only over-air encoding per §5.2 (universal: Android/iOS/macOS/Windows/Linux).
//
//   UUID_P(j)    = BaseP64 || C_j            (professor challenge, 5s rotation)
//   UUID_S(ID,j) = BaseS64 || R_IDj          (student response, 5s rotation)
//
// Fixed PROX_SVC always advertised alongside for scan filtering.
// Scan-response carries peerW(ID) 8 bytes (no stable MAC, no cross-lecture link).
library;

import 'dart:typed_data';

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

  /// Unpack canonical UUID string into 16 bytes.
  static Uint8List unpack(String uuid) => hexDecode(uuid);

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
