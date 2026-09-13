// sec(hwkey): HwDeviceKey units — challenge binding, HW levels,
// AES-GCM seal clone-detection, attest-must-throw, desktop fail-closed.
import 'dart:convert';

import 'package:attested_secure_keys/attested_secure_keys.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/device_identity/hw_device_key.dart';
import 'package:proximity_protocol/protocol.dart';

class _FakeHwBackend implements HwKeyBackend {
  final AttestationLevel level;
  final Uint8List pkD;
  List<Uint8List> chain = const [];
  Uint8List? lastChallenge;
  int attestCalls = 0;

  /// When true, attest() throws (models a device with no attestation).
  bool throwAttest = false;

  /// When true, attest() returns an empty chain (must still fail closed).
  bool emptyChain = false;

  _FakeHwBackend({this.level = AttestationLevel.full, Uint8List? pkD})
      : pkD = pkD ?? Uint8List.fromList(List.generate(64, (i) => (i * 3 + 7) & 0xFF));

  @override
  Future<HwKeyHandle> generateKey(
      {required String alias, required Uint8List attestationChallenge}) async {
    lastChallenge = Uint8List.fromList(attestationChallenge);
    return HwKeyHandle(pkDRaw: Uint8List.fromList(pkD), level: level);
  }

  @override
  Future<HwKeyHandle?> getKeyInfo({required String alias}) async {
    if (lastChallenge == null && chain.isEmpty) return null;
    // Bound at least once (or pre-seeded via generateKey in test).
    return HwKeyHandle(pkDRaw: Uint8List.fromList(pkD), level: level);
  }

  @override
  Future<bool> containsKey({required String alias}) async =>
      lastChallenge != null || chain.isNotEmpty;

  @override
  Future<Uint8List> sign(
      {required String alias, required Uint8List payload}) async {
    final h1 = ProxCrypto.sha256Sync([...payload, ...pkD]);
    final h2 = ProxCrypto.sha256Sync([...pkD, ...payload]);
    return Uint8List.fromList([...h1, ...h2]);
  }

  @override
  Future<HwAttestation> attest(
      {required String alias, required Uint8List serverNonce}) async {
    attestCalls++;
    if (throwAttest) throw StateError('no attestation (test)');
    if (emptyChain) return const HwAttestation();
    chain = [Uint8List.fromList([...serverNonce, 0x06, 0x09])];
    return HwAttestation(
        chainDER: [for (final c in chain) Uint8List.fromList(c)]);
  }

  @override
  Future<void> deleteKey({required String alias}) async {
    lastChallenge = null;
    chain = const [];
  }
}

/// Apple-shaped fake backend: generateKey reports STD (the iOS tier —
/// Secure Enclave + App Attest standard), attest returns the canned Apple
/// artifact (object with x5c, or assertion with an empty chain).
class _AppleBackend implements HwKeyBackend {
  final Uint8List raw;
  final List<Uint8List> chain;
  final Uint8List? credKey;
  final Uint8List pkD =
      Uint8List.fromList(List.generate(64, (i) => (i * 5 + 1) & 0xFF));

  _AppleBackend({required this.raw, required this.chain, this.credKey});

  @override
  Future<HwKeyHandle> generateKey(
          {required String alias,
          required Uint8List attestationChallenge}) async =>
      HwKeyHandle(
          pkDRaw: Uint8List.fromList(pkD),
          level: AttestationLevel.standard);

  @override
  Future<HwKeyHandle?> getKeyInfo({required String alias}) async =>
      HwKeyHandle(
          pkDRaw: Uint8List.fromList(pkD),
          level: AttestationLevel.standard);

  @override
  Future<bool> containsKey({required String alias}) async => true;

  @override
  Future<Uint8List> sign(
          {required String alias, required Uint8List payload}) async =>
      Uint8List(64);

  @override
  Future<HwAttestation> attest(
      {required String alias, required Uint8List serverNonce}) async {
    final parsed = AttestedSecureKeysBackend.attestApple(raw);
    return HwAttestation(
      chainDER: [for (final c in chain) Uint8List.fromList(c)],
      appAttestRaw: parsed.appAttestRaw,
      appAttestAuthData: parsed.appAttestAuthData,
      appAttestCredKey:
          credKey == null ? null : Uint8List.fromList(credKey!),
      isApple: true,
    );
  }

  @override
  Future<void> deleteKey({required String alias}) async {}
}

/// In-memory DEK store: one instance per device — a fresh instance models a
/// backup-restore clone whose Keystore/Keychain DEK never migrated.
class _MemorySealStore implements HwSealStore {
  final Map<String, Uint8List> _deks = {};

  @override
  Future<Uint8List?> readDek({required String alias}) async =>
      _deks[alias] == null ? null : Uint8List.fromList(_deks[alias]!);

  @override
  Future<void> writeDek(
      {required String alias, required Uint8List dek32}) async {
    _deks[alias] = Uint8List.fromList(dek32);
  }

  @override
  Future<void> deleteDek({required String alias}) async {
    _deks.remove(alias);
  }
}

Uint8List _hexBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

HwDeviceKey _device(
        {HwKeyBackend? backend, HwSealStore? sealStore, String? alias}) =>
    HwDeviceKey(
      backend: backend ?? _FakeHwBackend(),
      sealStore: sealStore ?? _MemorySealStore(),
      alias: alias ?? kHwDeviceKeyAlias,
    );

void main() {
  group('HwDeviceKey challenge binding (canonical V2)', () {
    test('enrollmentChallenge is V2-canonical, lowercases email', () {
      final pkS = Uint8List.fromList(List.filled(32, 9));
      final a = HwDeviceKey.enrollmentChallenge(
          email: 'Student@Example.COM', installId: 'inst-1', pkS: pkS);
      final b = deviceBindingChallengeV2(
          emailLower: 'student@example.com', installId: 'inst-1', pkS: pkS);
      expect(a, b);
      expect(a.length, 32);
      expect(
          HwDeviceKey.enrollmentChallenge(
              email: 'student@example.com', installId: 'inst-2', pkS: pkS),
          isNot(a));
    });

    test('pkDFromXY decodes unpadded base64url x||y', () {
      String b64u(Uint8List b) =>
          base64Url.encode(b).replaceAll('=', '');
      // P-256 generator G (on-curve) → known 64B.
      final gx = _hexBytes(
          '6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296');
      final gy = _hexBytes(
          '4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5');
      expect(HwDeviceKey.isOnP256Curve(gx, gy), isTrue);
      expect(HwDeviceKey.pkDFromXY(b64u(gx), b64u(gy)), [...gx, ...gy]);
      expect(() => HwDeviceKey.pkDFromXY('!!!', b64u(gy)),
          throwsA(isA<Exception>()));
    });

    test('pkDFromXY rejects off-curve / out-of-range points', () {
      String b64u(Uint8List b) =>
          base64Url.encode(b).replaceAll('=', '');
      // ignore: avoid_redundant_argument_values
      final x = Uint8List.fromList(List.filled(32, 0x11));
      final y = Uint8List.fromList(List.filled(32, 0x22));
      expect(HwDeviceKey.isOnP256Curve(x, y), isFalse);
      expect(() => HwDeviceKey.pkDFromXY(b64u(x), b64u(y)),
          throwsA(isA<FormatException>()));
      final zero = Uint8List(32);
      final gy = _hexBytes(
          '4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5');
      expect(HwDeviceKey.isOnP256Curve(zero, gy), isFalse);
      expect(() => HwDeviceKey.pkDFromXY(b64u(zero), b64u(gy)),
          throwsA(isA<FormatException>()));
    });

    test('decodeX5c rejects empty / non-DER bodies fail-closed', () {
      expect(
          () => AttestedSecureKeysBackend.decodeX5c(const []),
          throwsA(isA<StateError>()));
      expect(
          () => AttestedSecureKeysBackend.decodeX5c(const ['aGk=']),
          throwsA(isA<StateError>()));
      final der = Uint8List.fromList([0x30, 0x03, 0x02, 0x01, 0x05]);
      final back = AttestedSecureKeysBackend.decodeX5c(
          [base64.encode(der)]);
      expect(back, [der]);
    });
  });

  group('mapKeySecurityLevel (plugin → protocol)', () {
    test('strongBox/secureEnclave → FULL, TEE → STD, rest → NONE', () {
      expect(mapKeySecurityLevel(KeySecurityLevel.strongBox),
          AttestationLevel.full);
      expect(mapKeySecurityLevel(KeySecurityLevel.secureEnclave),
          AttestationLevel.full);
      expect(mapKeySecurityLevel(KeySecurityLevel.trustedEnvironment),
          AttestationLevel.standard);
      expect(mapKeySecurityLevel(KeySecurityLevel.software),
          AttestationLevel.none);
      expect(mapKeySecurityLevel(KeySecurityLevel.unknown),
          AttestationLevel.none);
    });
  });

  group('HwDeviceKey bind/ensure/level', () {
    test('bind caches pkD64 + chain + 90d window + challenge', () async {
      final backend = _FakeHwBackend();
      final d = _device(backend: backend);
      final pkS = Uint8List.fromList(List.filled(32, 5));
      await d.bindEnrollment(
          email: 's@x.in', installId: 'inst-1', pkS: pkS);
      expect(d.pkD.length, 64);
      expect(d.pkDHex.length, 128);
      expect(d.level, AttestationLevel.full);
      expect(d.chainDER, hasLength(1));
      expect(d.chainDERHex, hasLength(1));
      expect(d.lastChallenge,
          deviceBindingChallengeV2(emailLower: 's@x.in', installId: 'inst-1', pkS: pkS));
      expect(backend.attestCalls, 1);
      final window = d.attestedUntil.difference(d.attestedAt);
      expect(window, kDeviceAttestedValidity);
      expect(await d.heartbeat(), isTrue);
      // ensure() passes once bound.
      await d.ensure();
    });

    test('ensure without bind → Software-no-enroll', () async {
      final d = _device();
      expect(() => d.ensure(), throwsA(isStateError.having(
          (e) => e.message, 'message', contains('Software-no-enroll'))));
      expect(() => d.pkD, throwsStateError);
    });

    test('software level → Software-no-enroll (no silent downgrade)',
        () async {
      final d = _device(
          backend: _FakeHwBackend(level: AttestationLevel.none));
      expect(
          () => d.bindEnrollment(
              email: 's@x.in', installId: 'i', pkS: Uint8List(32)),
          throwsA(isStateError.having(
              (e) => e.message, 'message', contains('Software-no-enroll'))));
    });

    test('attest failure throws (never empty-chain proceed)', () async {
      final failing = _FakeHwBackend()..throwAttest = true;
      expect(
          () => _device(backend: failing).bindEnrollment(
              email: 's@x.in',
              installId: 'i',
              pkS: Uint8List.fromList(List.filled(32, 1))),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('attestation failed'))));

      final empty = _FakeHwBackend()..emptyChain = true;
      expect(
          () => _device(backend: empty).bindEnrollment(
              email: 's@x.in',
              installId: 'i',
              pkS: Uint8List.fromList(List.filled(32, 1))),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('attestation failed'))));
    });
  });

  group('HwDeviceKey seal/unseal (AES-GCM, HW-bound DEK)', () {
    test('roundtrip is PXK2 64B; tamper/clone → restore detected', () async {
      final backend = _FakeHwBackend();
      final store = _MemorySealStore();
      final d = _device(backend: backend, sealStore: store);
      await d.bindEnrollment(
          email: 's@x.in',
          installId: 'inst-1',
          pkS: Uint8List.fromList(List.filled(32, 5)));
      final seed = Uint8List.fromList(List.generate(32, (i) => i));
      final sealed = await d.seal(seed);
      expect(sealed.length, kHwSealEnvelopeBytes);
      expect(sealed.sublist(0, 4), kHwSealMagic);
      expect(await d.unseal(sealed), seed);

      // Same seed seals differently (fresh nonce), both open.
      final sealed2 = await d.seal(seed);
      expect(sealed2, isNot(sealed));
      expect(await d.unseal(sealed2), seed);

      // Tampered body fails closed.
      final bad = Uint8List.fromList(sealed);
      bad[20] ^= 0xFF;
      expect(() => d.unseal(bad),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));

      // Clone: same ciphertext, different device DEK store fails — even
      // with the same HW public key (no pkD-derived keystream to replay).
      final clone = HwDeviceKey(
          backend: backend, sealStore: _MemorySealStore());
      await clone.bindEnrollment(
          email: 's@x.in',
          installId: 'inst-CLONE',
          pkS: Uint8List.fromList(List.filled(32, 5)));
      expect(() => clone.unseal(sealed),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));

      // Wiped DEK (storage cleared under us) fails closed.
      await store.deleteDek(alias: kHwDeviceKeyAlias);
      expect(() => d.unseal(sealed),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));
    });

    test('deleted HW key (biometric invalidation) fails closed', () async {
      final backend = _FakeHwBackend();
      final d = _device(backend: backend);
      await d.bindEnrollment(
          email: 's@x.in',
          installId: 'inst-1',
          pkS: Uint8List.fromList(List.filled(32, 5)));
      final sealed =
          await d.seal(Uint8List.fromList(List.generate(32, (i) => i)));
      await backend.deleteKey(alias: kHwDeviceKeyAlias);
      expect(() => d.unseal(sealed),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));
    });

    test('unsealEnrollment opens AAD seals; legacy seals fail closed',
        () async {
      final pkS = Uint8List.fromList(List.filled(32, 5));
      final d = _device();
      await d.bindEnrollment(
          email: 's@x.in', installId: 'inst-1', pkS: pkS);
      final seed = Uint8List.fromList(List.generate(32, (i) => i));
      // AAD-bound envelope opens via unsealEnrollment with the same identity.
      final aadSealed = await d.sealWithAad(
        seed,
        aad: buildSealAad(
            emailLower: 's@x.in',
            installId: 'inst-1',
            pkS: pkS,
            pkD: d.pkD),
      );
      expect(
          await d.unsealEnrollment(
              sealed: aadSealed,
              email: 's@x.in',
              installId: 'inst-1',
              pkS: pkS),
          seed);
      // Wrong identity fails the AAD tag — never a raw fallback.
      expect(
          () => d.unsealEnrollment(
              sealed: aadSealed,
              email: 'evil@x.in',
              installId: 'inst-1',
              pkS: pkS),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));
      // Legacy (empty-AAD) envelopes fail closed (re-enroll, never open).
      final legacySealed = await d.seal(seed);
      expect(
          () => d.unsealEnrollment(
              sealed: legacySealed,
              email: 's@x.in',
              installId: 'inst-1',
              pkS: pkS),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));
    });

    test('sign returns 64B ES256 raw R||S', () async {
      final d = _device();
      await d.bindEnrollment(
          email: 's@x.in',
          installId: 'i',
          pkS: Uint8List.fromList(List.filled(32, 1)));
      final sig = await d.sign(Uint8List.fromList([1, 2, 3]));
      expect(sig.length, 64);
    });
  });

  group('Apple App Attest branch (iOS)', () {
    // Hand-built attestation object: A3{1:'apple',2:authData,3:{'x5c':[cert]}}
    // with authData carrying a COSE ES256 P-256 credential key.
    (Uint8List, Uint8List) appleObject() {
      final x = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final y = Uint8List.fromList(List.generate(32, (i) => i + 33));
      final auth = Uint8List.fromList([
        ...List.filled(32, 0xAA),
        0x45,
        0x00,
        0x00,
        0x00,
        0x01,
        ...List.filled(16, 0xBB),
        0x00,
        0x02,
        0xCC,
        0xDD,
        0xA5,
        0x01,
        0x02,
        0x03,
        0x26,
        0x20,
        0x01,
        0x21,
        0x58,
        0x20,
        ...x,
        0x22,
        0x58,
        0x20,
        ...y,
      ]);
      final cert = Uint8List.fromList([0x30, 0x03, 0x01, 0x02, 0x03]);
      final raw = Uint8List.fromList([
        0xA3,
        0x01,
        0x65,
        0x61,
        0x70,
        0x70,
        0x6C,
        0x65,
        0x02,
        0x58,
        auth.length,
        ...auth,
        0x03,
        0xA1,
        0x63,
        0x78,
        0x35,
        0x63,
        0x81,
        0x45,
        ...cert,
      ]);
      return (raw, Uint8List.fromList([...x, ...y]));
    }

    test('attestApple parses object (chain + authData + credKey)', () {
      final (raw, credKey) = appleObject();
      final att = AttestedSecureKeysBackend.attestApple(raw);
      expect(att.isApple, isTrue);
      expect(att.chainDER, hasLength(1));
      expect(att.chainDER.single[0], 0x30);
      expect(att.appAttestAuthData, isNotNull);
      expect(att.appAttestCredKey, credKey);
      expect(att.appAttestRaw, raw);
    });

    test('attestApple parses assertion (empty chain, authData kept)', () {
      final auth = Uint8List.fromList(List.filled(37, 0x11));
      final sig = Uint8List.fromList(List.filled(64, 0x22));
      final att = AttestedSecureKeysBackend.attestApple(
          Uint8List.fromList([...auth, ...sig]));
      expect(att.isApple, isTrue);
      expect(att.chainDER, isEmpty);
      expect(att.appAttestAuthData, auth);
      expect(att.appAttestCredKey, isNull);
    });

    test('attestApple fails closed on missing/malformed CBOR', () {
      expect(() => AttestedSecureKeysBackend.attestApple(null),
          throwsStateError);
      expect(() => AttestedSecureKeysBackend.attestApple(Uint8List(10)),
          throwsStateError);
    });

    test('bindEnrollment Apple object path binds STD + stash', () async {
      final (raw, credKey) = appleObject();
      final backend = _AppleBackend(
          raw: raw,
          chain: [Uint8List.fromList([0x30, 0x03, 0x01, 0x02, 0x03])],
          credKey: credKey);
      final d = _device(backend: backend);
      await d.bindEnrollment(
          email: 's@x.in', installId: 'inst-1', pkS: Uint8List(32));
      expect(d.level, AttestationLevel.standard);
      expect(d.chainDER, hasLength(1));
      expect(d.appAttestRawHex, hexEncode(raw));
      expect(d.appAttestCredKeyHex, hexEncode(credKey));
      expect(d.appAttestAuthDataHex.isNotEmpty, isTrue);
    });

    test('bindEnrollment assertion path needs prev credKey, else reinstall',
        () async {
      final auth = Uint8List.fromList(List.filled(37, 0x11));
      final sig = Uint8List.fromList(List.filled(64, 0x22));
      final backend = _AppleBackend(
          raw: Uint8List.fromList([...auth, ...sig]), chain: const []);
      final d = _device(backend: backend);
      // No previous credential -> clear reinstall pointer, never a bind.
      expect(
          () => d.bindEnrollment(
              email: 's@x.in', installId: 'inst-1', pkS: Uint8List(32)),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('reinstall'))));
      // Previous credential rides forward; chain stays empty (iOS only).
      final prev = hexEncode(Uint8List.fromList(List.filled(64, 0x07)));
      await d.bindEnrollment(
          email: 's@x.in',
          installId: 'inst-1',
          pkS: Uint8List(32),
          prevAppAttestCredKeyHex: prev);
      expect(d.level, AttestationLevel.standard);
      expect(d.chainDER, isEmpty);
      expect(d.appAttestCredKeyHex, prev);
      expect(d.appAttestRawHex.isNotEmpty, isTrue);
    });
  });

  group('HwDeviceKey desktop fail-closed', () {
    test('records-only devices throw before anything signs', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final d = _device();
      try {
        expect(() => d.ensure(), throwsStateError);
        expect(
            () => d.bindEnrollment(
                email: 's@x.in', installId: 'i', pkS: Uint8List(32)),
            throwsStateError);
        expect(() => d.pkD, throwsStateError);
        expect(() => d.sign(Uint8List.fromList([1])), throwsStateError);
        expect(
            () => d.seal(Uint8List.fromList(List.filled(32, 1))),
            throwsStateError);
        expect(
            () => d.unseal(Uint8List.fromList(List.filled(64, 0))),
            throwsStateError);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
