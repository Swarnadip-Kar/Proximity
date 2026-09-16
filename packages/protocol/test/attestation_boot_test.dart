// Flag-only KeyDescription boot parser units (fail-open telemetry).
//
// Builds minimal DER certs + KeyDescriptions with a tiny in-test encoder
// (no fixtures, no network) and pins the flag-only contract:
//   clean locked+Verified+HW -> [] (no new noise),
//   unlocked / unverified-boot / software-level -> advisory attest-* flags,
//   fake / truncated / future / iOS-shaped -> [] (fail-open, never a refusal).
// Pure Dart.
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

// -- Minimal DER encoder (test-only) ---------------------------------------

Uint8List _concat(List<Uint8List> parts) {
  var len = 0;
  for (final p in parts) {
    len += p.length;
  }
  final out = Uint8List(len);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}

Uint8List _encLen(int len) {
  if (len < 0) throw ArgumentError('neg len');
  if (len < 128) return Uint8List.fromList([len]);
  final bytes = <int>[];
  var v = len;
  while (v > 0) {
    bytes.insert(0, v & 0xFF);
    v >>= 8;
  }
  return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
}

Uint8List _enc(int tagClass, bool constructed, int tagNumber, Uint8List v) {
  final tag = <int>[];
  if (tagNumber < 31) {
    tag.add((tagClass << 6) | (constructed ? 0x20 : 0) | tagNumber);
  } else {
    tag.add((tagClass << 6) | (constructed ? 0x20 : 0) | 0x1F);
    // Base-128 big-endian tag number.
    final stack = <int>[];
    var n = tagNumber;
    stack.insert(0, n & 0x7F);
    n >>= 7;
    while (n > 0) {
      stack.insert(0, (n & 0x7F) | 0x80);
      n >>= 7;
    }
    // All but last carry continuation.
    for (var i = 0; i < stack.length - 1; i++) {
      stack[i] |= 0x80;
    }
    tag.addAll(stack);
  }
  return _concat(
      [Uint8List.fromList(tag), _encLen(v.length), Uint8List.fromList(v)]);
}

Uint8List _seq(List<Uint8List> kids) =>
    _enc(0, true, 16, _concat(kids));
Uint8List _int(int v) {
  if (v < 0) throw ArgumentError('neg int');
  if (v < 128) return _enc(0, false, 2, Uint8List.fromList([v]));
  final bytes = <int>[];
  var n = v;
  while (n > 0) {
    bytes.insert(0, n & 0xFF);
    n >>= 8;
  }
  if (bytes[0] & 0x80 != 0) bytes.insert(0, 0x00);
  return _enc(0, false, 2, Uint8List.fromList(bytes));
}

Uint8List _enum(int v) {
  if (v < 0) throw ArgumentError('neg enum');
  if (v < 128) return _enc(0, false, 10, Uint8List.fromList([v]));
  final bytes = <int>[];
  var n = v;
  while (n > 0) {
    bytes.insert(0, n & 0xFF);
    n >>= 8;
  }
  if (bytes[0] & 0x80 != 0) bytes.insert(0, 0x00);
  return _enc(0, false, 10, Uint8List.fromList(bytes));
}

Uint8List _octet(List<int> b) =>
    _enc(0, false, 4, Uint8List.fromList(b));
Uint8List _bool(bool b) =>
    _enc(0, false, 1, Uint8List.fromList([b ? 0xFF : 0x00]));
Uint8List _oid(List<int> valueBytes) =>
    _enc(0, false, 6, Uint8List.fromList(valueBytes));
Uint8List _ctx(int tag, Uint8List innerDer) =>
    _enc(2, true, tag, innerDer);
Uint8List _bitString(List<int> b) =>
    _enc(0, false, 3, Uint8List.fromList(b));

// -- Builders ---------------------------------------------------------------

Uint8List _rot({required bool locked, required int bootState}) => _seq([
      _octet(List.filled(32, 0x01)),
      _bool(locked),
      _enum(bootState),
    ]);

Uint8List _keyDesc({
  required int attLevel,
  required int kmLevel,
  required bool locked,
  required int bootState,
}) {
  final rot = _rot(locked: locked, bootState: bootState);
  final tee = _seq([_ctx(704, rot)]);
  final sw = _seq([]);
  return _seq([
    _int(4),
    _enum(attLevel),
    _int(100),
    _enum(kmLevel),
    _octet(List.filled(32, 0x07)),
    _octet([]),
    sw,
    tee,
  ]);
}

Uint8List _leafCert(Uint8List keyDescDer, {bool doubleWrap = false}) {
  final extValue =
      doubleWrap ? _octet(keyDescDer) : Uint8List.fromList(keyDescDer);
  final ext = _seq([
    _oid(kAttestationOidValue),
    _octet(extValue),
  ]);
  final exts = _seq([ext]);
  final tbs = _seq([_ctx(3, exts)]);
  final sigAlg = _seq([_oid([0x2A, 0x03])]);
  final sig = _bitString([0x00]);
  return _seq([tbs, sigAlg, sig]);
}

void main() {
  group('parseKeyDescription (direct)', () {
    test('clean TEE locked Verified parses', () {
      final kd = _keyDesc(
          attLevel: 1, kmLevel: 1, locked: true, bootState: 0);
      final info = parseKeyDescription(kd);
      expect(info, isNotNull);
      expect(info!.attestationSecurityLevel, 1);
      expect(info.keyMintSecurityLevel, 1);
      expect(info.deviceLocked, isTrue);
      expect(info.verifiedBootState, 0);
      expect(bootInfoFlags(info), isEmpty);
    });

    test('StrongBox locked Verified is clean', () {
      final kd = _keyDesc(
          attLevel: 2, kmLevel: 2, locked: true, bootState: 0);
      expect(bootInfoFlags(parseKeyDescription(kd)!), isEmpty);
    });

    test('unlocked flags attest-unlocked only', () {
      final kd = _keyDesc(
          attLevel: 1, kmLevel: 1, locked: false, bootState: 0);
      final flags = bootInfoFlags(parseKeyDescription(kd)!);
      expect(flags, contains('attest-unlocked'));
      expect(flags, isNot(contains('attest-unverified-boot')));
    });

    test('self-signed / unverified / failed map distinctly', () {
      expect(
          bootInfoFlags(parseKeyDescription(
              _keyDesc(attLevel: 1, kmLevel: 1, locked: true, bootState: 1))!),
          containsAll(['attest-unverified-boot', 'attest-boot-self-signed']));
      expect(
          bootInfoFlags(parseKeyDescription(
              _keyDesc(attLevel: 1, kmLevel: 1, locked: true, bootState: 2))!),
          containsAll(['attest-unverified-boot', 'attest-boot-unverified']));
      expect(
          bootInfoFlags(parseKeyDescription(
              _keyDesc(attLevel: 1, kmLevel: 1, locked: true, bootState: 3))!),
          containsAll(['attest-unverified-boot', 'attest-boot-failed']));
    });

    test('future boot state flags unknown (fail-visible)', () {
      final flags = bootInfoFlags(parseKeyDescription(
          _keyDesc(attLevel: 1, kmLevel: 1, locked: true, bootState: 9))!);
      expect(flags,
          containsAll(['attest-unverified-boot', 'attest-boot-unknown']));
    });

    test('software level flags attest-sw-level', () {
      final a = bootInfoFlags(parseKeyDescription(
          _keyDesc(attLevel: 0, kmLevel: 1, locked: true, bootState: 0))!);
      expect(a, contains('attest-sw-level'));
      final b = bootInfoFlags(parseKeyDescription(
          _keyDesc(attLevel: 1, kmLevel: 0, locked: true, bootState: 0))!);
      expect(b, contains('attest-sw-level'));
    });

    test('malformed KeyDescription returns null (fail-open)', () {
      expect(parseKeyDescription(Uint8List(0)), isNull);
      expect(parseKeyDescription(Uint8List.fromList([0x30, 0x00])),
          isNull);
      expect(parseKeyDescription(Uint8List.fromList([0x01, 0x02, 0x03])),
          isNull);
    });
  });

  group('bootFlagsOf (leaf)', () {
    test('clean leaf emits no flags', () {
      final leaf = _leafCert(_keyDesc(
          attLevel: 1, kmLevel: 1, locked: true, bootState: 0));
      expect(parseLeafBoot(leaf), isNotNull);
      expect(bootFlagsOf(leaf), isEmpty);
    });

    test('unlocked genuine leaf flags but parses', () {
      final leaf = _leafCert(_keyDesc(
          attLevel: 1, kmLevel: 1, locked: false, bootState: 0));
      expect(parseLeafBoot(leaf)!.deviceLocked, isFalse);
      expect(bootFlagsOf(leaf), contains('attest-unlocked'));
    });

    test('unverified-boot leaf flags distinctly', () {
      final leaf = _leafCert(_keyDesc(
          attLevel: 1, kmLevel: 1, locked: true, bootState: 2));
      expect(bootFlagsOf(leaf),
          containsAll(['attest-unverified-boot', 'attest-boot-unverified']));
    });

    test('double-wrapped extension value still parses', () {
      final leaf = _leafCert(
          _keyDesc(attLevel: 1, kmLevel: 1, locked: false, bootState: 0),
          doubleWrap: true);
      expect(bootFlagsOf(leaf), contains('attest-unlocked'));
    });

    test('fake unit chains fail open to [] (never throws)', () {
      final fake = Uint8List.fromList(
          [...kKeyAttestationOidDer, 1, 2, 3, ...List.filled(8, 0xAB)]);
      expect(parseLeafBoot(fake), isNull);
      expect(bootFlagsOf(fake), isEmpty);
      expect(bootFlagsOf(Uint8List(0)), isEmpty);
      expect(bootFlagsOf(Uint8List.fromList([0x30, 0x00])), isEmpty);
    });

    test('truncated genuine leaf fails open to []', () {
      final leaf = _leafCert(_keyDesc(
          attLevel: 1, kmLevel: 1, locked: false, bootState: 0));
      final cut = Uint8List.fromList(leaf.sublist(0, leaf.length - 5));
      expect(bootFlagsOf(cut), isEmpty);
    });

    test('cert without attestation extension fails open', () {
      final tbs = _seq([_ctx(3, _seq([]))]);
      final leaf = _seq([tbs]);
      expect(bootFlagsOf(leaf), isEmpty);
    });
  });
}
