// Single IPv4 dotted-quad parser shared by the v2 air codec (packAir)
// and the v1 UUID codec (UuidCodec.packIpHint).
//
// Both codecs previously inlined this same trim/split/tryParse/range body;
// they now both call [parseIpv4] and keep only their own address-policy
// lines (packAir rejects 127.* loopback, packIpHint rejects first-octet
// 0/127). Pure Dart, no platform code.
library;

/// Parses a dotted-quad IPv4 host into 4 octets, or null when malformed
/// (not 4 parts, non-numeric, or any octet outside 0..255).
List<int>? parseIpv4(String host) {
  final parts = host.trim().split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}
