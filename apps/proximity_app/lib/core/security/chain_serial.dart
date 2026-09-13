// Offline X.509 serial extraction from attestation-chain DER
// (PROXIMITY_SECURITY.md §2 residual; sec-revoke).
//
// Closes the gap noted in `revocation_cache.dart`: serials no longer "stay
// with the platform adapter" — they are parsed here, pure-Dart and fully
// offline via `asn1lib` (the same line `proximity_protocol` pins for
// `chain_verify.dart`), with no network, no backend, no Firestore.
//
// Shape assumed (RFC 5280):
//   Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm,
//                              signatureValue }
//   tbsCertificate ::= SEQUENCE { [0] version EXPLICIT OPTIONAL,
//                                serialNumber INTEGER, ... }
// Only the serial is read — no signature math (sec-protocol owns that in
// `chain_verify.dart`), no validity/policy checks. The result feeds the
// advisory CRL review flags (`RevocationCache.reviewFlagsForChain[Hex]`),
// never a marking verdict.
//
// Fail-open contract: every function here is total — malformed, truncated,
// empty, or oversized input yields null/[] (never throws, never accuses).
// Parse failure is a review-signal absence, not a verdict.
library;

import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';

/// Refuse to parse absurd inputs (genuine certs are < 4KB; the bound only
/// guards pathological heap/time on hostile bytes, offline).
const kMaxCertDerBytes = 65536;

/// Extracts the leaf certificate's serial as lowercase hex (no `0x` prefix,
/// leading zeros trimmed, e.g. DER `02 02 00 AB` → `'ab'`, `02 01 01` →
/// `'1'`). Returns null when [leafDer] does not parse as a DER Certificate
/// or the serial is missing/malformed. Never throws.
String? leafSerialHex(Uint8List leafDer) {
  try {
    if (leafDer.isEmpty || leafDer.length > kMaxCertDerBytes) return null;
    final top = ASN1Parser(leafDer).nextObject();
    if (top is! ASN1Sequence || top.elements.isEmpty) return null;
    final tbs = top.elements[0];
    if (tbs is! ASN1Sequence || tbs.elements.isEmpty) return null;
    final els = tbs.elements;
    // Optional `[0] version EXPLICIT` shifts the serial by one.
    final base = els.first.tag == 0xa0 ? 1 : 0;
    if (els.length <= base) return null;
    final serialObj = els[base];
    if (serialObj is! ASN1Integer) return null;
    final v = serialObj.valueAsBigInteger;
    // Negative serials are malformed per RFC 5280 (MUST be positive) —
    // fail open, never accuse from them.
    if (v.sign < 0) return null;
    // BigInt hex carries no leading zeros by construction; the explicit
    // trim below pins the contract (DER pad `00` for high-bit serials).
    var hex = v.toRadixString(16).toLowerCase();
    hex = hex.replaceFirst(RegExp(r'^0+(?=[0-9a-f])'), '');
    return hex.isEmpty ? '0' : hex;
  } catch (_) {
    return null;
  }
}

/// Extracts every parseable serial from a leaf-first DER chain, in order;
/// unparseable entries are skipped (fail-open). Never throws.
List<String> allSerialsHex(List<Uint8List> certsDer) {
  final out = <String>[];
  for (final c in certsDer) {
    try {
      final s = leafSerialHex(c);
      if (s != null && s.isNotEmpty) out.add(s);
    } catch (_) {
      // leafSerialHex already fails open; belt-and-braces.
    }
  }
  return out;
}

/// Lenient hex-list → DER decoder for the stored wire form (`chainDERHex` /
/// `attestationChain`: leaf-first DER hex strings). Trims whitespace,
/// accepts an optional `0x` prefix, skips empty/invalid/odd-length entries.
/// Never throws.
List<Uint8List> certsDerFromHexList(List<String> chainHex) {
  final out = <Uint8List>[];
  for (final h in chainHex) {
    final der = tryHexDecode(h);
    if (der != null && der.isNotEmpty) out.add(der);
  }
  return out;
}

/// Strict-but-total hex decode: null on any malformation (never throws).
Uint8List? tryHexDecode(String hex) {
  try {
    var s = hex.trim().toLowerCase();
    if (s.startsWith('0x')) s = s.substring(2);
    s = s.replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty || s.length.isOdd) return null;
    const digits = '0123456789abcdef';
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final hi = digits.indexOf(s[i * 2]);
      final lo = digits.indexOf(s[i * 2 + 1]);
      if (hi < 0 || lo < 0) return null;
      out[i] = (hi << 4) | lo;
    }
    return out;
  } catch (_) {
    return null;
  }
}
