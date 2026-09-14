// Offline KeyDescription boot-state flags (flag-only telemetry, fail-open).
//
// Parses the Android Key Attestation extension (OID
// 1.3.6.1.4.1.11129.2.1.17) inside the leaf certificate to read
// `attestationSecurityLevel / keyMintSecurityLevel /
// RootOfTrust{deviceLocked, verifiedBootState}` without trusting any
// client-asserted level string.
//
// Flag-only contract (attendance posture — see PROXIMITY_SECURITY.md
// follow-up A):
//   - clean locked+Verified+HW returns [] (no new log noise, existing
//     tests byte-identical);
//   - unlocked / unverified-boot / software-level returns advisory
//     `attest-*` flags but NEVER changes the pin-gate verdict here —
//     callers (transport server, app self-check) append these to the
//     existing flag list while keeping `ok`/`decision` unchanged;
//   - unparseable (fake test chains, iOS App Attest leaves, future KeyMint
//     versions, truncated DER) returns [] — fail-open, never a new refusal.
//     Enforcement (ok:false) is a later one-line flip at the call sites,
//     not here.
//
// Structure-only parse (lengths + tags + enums, no decryption): sealed /
// attestation bytes are never decrypted or interpreted beyond the
// lengths/tags/bindings the offline professor gate already checks.
// Pure Dart, no platform code, no network.
library;

import 'dart:typed_data';

/// Key Attestation extension OID value bytes (content of the OID TLV, not
/// the TLV itself): 1.3.6.1.4.1.11129.2.1.17.
const List<int> kAttestationOidValue = [
  0x2B,
  0x06,
  0x01,
  0x04,
  0x01,
  0xD6,
  0x79,
  0x02,
  0x01,
  0x11,
];

/// AuthorizationList tag for RootOfTrust (KeyMint, all versions).
const int kTagRootOfTrust = 704;

/// VerifiedBootState values (KeyMint RootOfTrust).
const int kBootVerified = 0;
const int kBootSelfSigned = 1;
const int kBootUnverified = 2;
const int kBootFailed = 3;

/// Parsed boot posture of one leaf (null = unparseable, fail-open).
class AttestationBootInfo {
  /// SecurityLevel of the attestation itself (0=Software,1=TEE,2=StrongBox).
  final int attestationSecurityLevel;

  /// SecurityLevel of the KeyMint that holds the key (same enum).
  final int keyMintSecurityLevel;

  /// RootOfTrust.deviceLocked.
  final bool deviceLocked;

  /// RootOfTrust.verifiedBootState (0..3, future values pass through).
  final int verifiedBootState;

  const AttestationBootInfo({
    required this.attestationSecurityLevel,
    required this.keyMintSecurityLevel,
    required this.deviceLocked,
    required this.verifiedBootState,
  });
}

/// Flag-only mapper over a parsed [AttestationBootInfo].
///
/// Clean (HW + locked + Verified) returns []. Anything else returns one or
/// more advisory flags; callers keep the underlying verdict unchanged.
List<String> bootInfoFlags(AttestationBootInfo info) {
  final flags = <String>[];
  if (info.attestationSecurityLevel == 0 ||
      info.keyMintSecurityLevel == 0) {
    flags.add('attest-sw-level');
  }
  if (!info.deviceLocked) {
    flags.add('attest-unlocked');
  }
  if (info.verifiedBootState != kBootVerified) {
    flags.add('attest-unverified-boot');
    switch (info.verifiedBootState) {
      case kBootSelfSigned:
        flags.add('attest-boot-self-signed');
      case kBootUnverified:
        flags.add('attest-boot-unverified');
      case kBootFailed:
        flags.add('attest-boot-failed');
      default:
        flags.add('attest-boot-unknown');
    }
  }
  return flags;
}

/// Flag-only entry point over a full leaf DER.
///
/// Returns [] when the leaf carries no parseable Android attestation
/// extension (fake units, iOS leaves, future versions, malformed DER) —
/// fail-open by design. Never throws.
List<String> bootFlagsOf(Uint8List leafDer) {
  try {
    final info = parseLeafBoot(leafDer);
    if (info == null) return const [];
    return bootInfoFlags(info);
  } catch (_) {
    return const [];
  }
}

/// Parses one leaf DER into [AttestationBootInfo], or null when there is no
/// parseable Android attestation extension. Never throws (null on any
/// malformation — fail-open, callers map null to no flags).
AttestationBootInfo? parseLeafBoot(Uint8List leafDer) {
  try {
    if (leafDer.length < 2 || leafDer[0] != 0x30) return null;
    final top = _readTlv(leafDer, 0);
    if (top.tagClass != 0 || !top.constructed || top.tagNumber != 16) {
      return null;
    }
    if (top.nextOffset != leafDer.length) return null;
    final topKids = _parseChildren(top.value);
    if (topKids.isEmpty) return null;
    final tbs = topKids[0];
    if (tbs.tagClass != 0 || !tbs.constructed || tbs.tagNumber != 16) {
      return null;
    }
    final tbsKids = _parseChildren(tbs.value);
    _Tlv? extWrap;
    for (final c in tbsKids) {
      if (c.tagClass == 2 && c.constructed && c.tagNumber == 3) {
        extWrap = c;
        break;
      }
    }
    if (extWrap == null) return null;
    if (extWrap.value.isEmpty || extWrap.value[0] != 0x30) return null;
    final extsSeq = _readTlv(extWrap.value, 0);
    if (extsSeq.tagClass != 0 ||
        !extsSeq.constructed ||
        extsSeq.tagNumber != 16) {
      return null;
    }
    if (extsSeq.nextOffset != extWrap.value.length) return null;
    final extList = _parseChildren(extsSeq.value);
    for (final ext in extList) {
      if (ext.tagClass != 0 || !ext.constructed || ext.tagNumber != 16) {
        continue;
      }
      late final List<_Tlv> extKids;
      try {
        extKids = _parseChildren(ext.value);
      } catch (_) {
        continue;
      }
      if (extKids.isEmpty) continue;
      final oidNode = extKids[0];
      if (oidNode.tagClass != 0 || oidNode.tagNumber != 6) continue;
      if (!_oidEquals(oidNode.value, kAttestationOidValue)) continue;
      if (extKids.length < 2) continue;
      final octetNode = extKids.last;
      if (octetNode.tagClass != 0 || octetNode.tagNumber != 4) continue;
      var keyDescBytes = octetNode.value;
      // Single OCTET unwrap: some encoders double-wrap the extension value.
      if (keyDescBytes.isNotEmpty && keyDescBytes[0] == 0x04) {
        try {
          final inner = _readTlv(keyDescBytes, 0);
          if (inner.tagClass == 0 &&
              inner.tagNumber == 4 &&
              inner.nextOffset == keyDescBytes.length) {
            keyDescBytes = inner.value;
          }
        } catch (_) {}
      }
      final info = parseKeyDescription(keyDescBytes);
      if (info != null) return info;
      return null;
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Parses a raw KeyDescription SEQUENCE into [AttestationBootInfo], or null
/// on any malformation. Exposed for unit tests (production callers use
/// [parseLeafBoot]/[bootFlagsOf]).
///
/// KeyDescription ::= SEQ{version INT, attLevel ENUM, keyMintVersion INT,
///   keyMintLevel ENUM, challenge OCTET, uniqueId OCTET,
///   softwareEnforced SEQ, teeEnforced SEQ}.
AttestationBootInfo? parseKeyDescription(Uint8List der) {
  try {
    if (der.isEmpty || der[0] != 0x30) return null;
    final seq = _readTlv(der, 0);
    if (seq.tagClass != 0 || !seq.constructed || seq.tagNumber != 16) {
      return null;
    }
    if (seq.nextOffset != der.length) return null;
    final kids = _parseChildren(seq.value);
    if (kids.length < 8) return null;
    final attLevel = _asUnsigned(kids[1], 10);
    final kmLevel = _asUnsigned(kids[3], 10);
    if (attLevel == null || kmLevel == null) return null;
    final sw = kids[6];
    final tee = kids[7];
    if (sw.tagClass != 0 || !sw.constructed || sw.tagNumber != 16) {
      return null;
    }
    if (tee.tagClass != 0 || !tee.constructed || tee.tagNumber != 16) {
      return null;
    }
    // Tee wins; fall back to software list (defensive — RootOfTrust lives
    // in tee on every shipping version).
    final rotTlv =
        _findContextTag(tee.value, kTagRootOfTrust) ??
            _findContextTag(sw.value, kTagRootOfTrust);
    if (rotTlv == null) return null;
    if (rotTlv.value.isEmpty || rotTlv.value[0] != 0x30) return null;
    final rotSeq = _readTlv(rotTlv.value, 0);
    if (rotSeq.tagClass != 0 ||
        !rotSeq.constructed ||
        rotSeq.tagNumber != 16) {
      return null;
    }
    if (rotSeq.nextOffset != rotTlv.value.length) return null;
    final rotKids = _parseChildren(rotSeq.value);
    if (rotKids.length < 3) return null;
    if (rotKids[0].tagClass != 0 || rotKids[0].tagNumber != 4) return null;
    if (rotKids[1].tagClass != 0 || rotKids[1].tagNumber != 1) return null;
    if (rotKids[2].tagClass != 0 || rotKids[2].tagNumber != 10) return null;
    if (rotKids[1].value.length != 1) return null;
    final locked = rotKids[1].value[0] != 0;
    final bootState = _asUnsigned(rotKids[2], 10);
    if (bootState == null) return null;
    return AttestationBootInfo(
      attestationSecurityLevel: attLevel,
      keyMintSecurityLevel: kmLevel,
      deviceLocked: locked,
      verifiedBootState: bootState,
    );
  } catch (_) {
    return null;
  }
}

// -- Minimal DER reader (tag + length + value, high-tag aware) -------------

class _Tlv {
  final int tagClass;
  final bool constructed;
  final int tagNumber;
  final Uint8List value;
  final int nextOffset;
  const _Tlv({
    required this.tagClass,
    required this.constructed,
    required this.tagNumber,
    required this.value,
    required this.nextOffset,
  });
}

_Tlv _readTlv(Uint8List data, int offset) {
  if (offset < 0 || offset >= data.length) {
    throw const FormatException('tlv oob');
  }
  final b0 = data[offset++];
  final tagClass = (b0 >> 6) & 0x03;
  final constructed = (b0 & 0x20) != 0;
  var tagNumber = b0 & 0x1F;
  if (tagNumber == 0x1F) {
    tagNumber = 0;
    var count = 0;
    while (true) {
      if (offset >= data.length) throw const FormatException('tag oob');
      if (count++ > 5) throw const FormatException('tag too long');
      final b = data[offset++];
      tagNumber = (tagNumber << 7) | (b & 0x7F);
      if ((b & 0x80) == 0) break;
    }
  }
  if (offset >= data.length) throw const FormatException('len oob');
  final lb = data[offset++];
  int len;
  if (lb < 0x80) {
    len = lb;
  } else if (lb == 0x80) {
    throw const FormatException('indefinite length');
  } else {
    final n = lb & 0x7F;
    if (n == 0 || n > 4) throw const FormatException('bad length');
    if (offset + n > data.length) {
      throw const FormatException('len oob');
    }
    var acc = 0;
    for (var i = 0; i < n; i++) {
      acc = (acc << 8) | data[offset++];
    }
    len = acc;
  }
  if (len < 0 || offset + len > data.length) {
    throw const FormatException('value oob');
  }
  final value = Uint8List.fromList(data.sublist(offset, offset + len));
  return _Tlv(
    tagClass: tagClass,
    constructed: constructed,
    tagNumber: tagNumber,
    value: value,
    nextOffset: offset + len,
  );
}

List<_Tlv> _parseChildren(Uint8List content) {
  final out = <_Tlv>[];
  var off = 0;
  while (off < content.length) {
    final t = _readTlv(content, off);
    out.add(t);
    if (t.nextOffset <= off) throw const FormatException('no progress');
    off = t.nextOffset;
  }
  if (off != content.length) throw const FormatException('trailing');
  return out;
}

_Tlv? _findContextTag(Uint8List authListContent, int tag) {
  late final List<_Tlv> kids;
  try {
    kids = _parseChildren(authListContent);
  } catch (_) {
    return null;
  }
  for (final k in kids) {
    if (k.tagClass == 2 && k.tagNumber == tag) return k;
  }
  return null;
}

/// Unsigned big-endian int for INTEGER/ENUMERATED content. Null on empty,
/// oversized, or negative (high bit set — our values are 0..300).
int? _asUnsigned(_Tlv t, int expectedUniversalTag) {
  if (t.tagClass != 0 || t.tagNumber != expectedUniversalTag) return null;
  final v = t.value;
  if (v.isEmpty || v.length > 4) return null;
  if ((v[0] & 0x80) != 0) return null;
  var acc = 0;
  for (final b in v) {
    acc = (acc << 8) | b;
  }
  return acc;
}

bool _oidEquals(Uint8List a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
