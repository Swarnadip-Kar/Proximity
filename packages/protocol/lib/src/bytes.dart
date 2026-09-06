// Byte helpers: hex, concat, CSPRNG.
library;

import 'dart:math';
import 'dart:typed_data';

String hexEncode(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Strict hex decode: rejects non-hex input and odd lengths instead of
/// silently stripping characters (which turned garbage into empty bytes
/// and surfaced as misleading `bad-challenge`/`bad-sig` verdicts).
Uint8List hexDecode(String hex) {
  if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) {
    throw FormatException('invalid hex string');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List concat(List<List<int>> parts) {
  final total = parts.fold<int>(0, (n, p) => n + p.length);
  final out = Uint8List(total);
  var o = 0;
  for (final p in parts) {
    out.setRange(o, o + p.length, p);
    o += p.length;
  }
  return out;
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var acc = 0;
  for (var i = 0; i < a.length; i++) {
    acc |= a[i] ^ b[i];
  }
  return acc == 0;
}

/// CSPRNG via [Random.secure] (backed by OS entropy; mirrors
/// `cryptography` CSPRNG semantics without async overhead).
Uint8List randBytes(int n, [Random? rng]) {
  final r = rng ?? Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}
