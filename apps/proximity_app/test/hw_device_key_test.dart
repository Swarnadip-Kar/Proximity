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
  Future<List<Uint8List>> attest(
      {required String alias, required Uint8List serverNonce}) async {
    attestCalls++;
    if (throwAttest) throw StateError('no attestation (test)');
    if (emptyChain) return const [];
    chain = [Uint8List.fromList([...serverNonce, 0x06, 0x09])];
    return [for (final c in chain) Uint8List.fromList(c)];
  }

  @override
  Future<void> deleteKey({required String alias}) async {
    lastChallenge = null;
    chain = const [];
  }
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
      // 32B x=0x11.., 32B y=0x22.. → known 64B.
      String b64u(Uint8List b) =>
          base64Url.encode(b).replaceAll('=', '');
      // ignore: avoid_redundant_argument_values
      final x = Uint8List.fromList(List.filled(32, 0x11));
      final y = Uint8List.fromList(List.filled(32, 0x22));
      final pkD = HwDeviceKey.pkDFromXY(b64u(x), b64u(y));
      expect(pkD, [...x, ...y]);
      expect(() => HwDeviceKey.pkDFromXY('!!!', b64u(y)),
          throwsA(isA<Exception>()));
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
