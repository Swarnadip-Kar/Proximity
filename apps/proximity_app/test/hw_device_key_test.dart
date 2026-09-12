// sec(hwkey): HwDeviceKey units — challenge binding, HW levels,
// sealed envelope clone-detection, desktop fail-closed.
import 'dart:convert';

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
    chain = [Uint8List.fromList([...serverNonce, 0x06, 0x09])];
    return [for (final c in chain) Uint8List.fromList(c)];
  }

  @override
  Future<void> deleteKey({required String alias}) async {
    lastChallenge = null;
    chain = const [];
  }
}

void main() {
  group('HwDeviceKey challenge binding (M1-gap canonical)', () {
    test('enrollmentChallenge == deviceBindingChallenge, lowercases email',
        () {
      final pkS = Uint8List.fromList(List.filled(32, 9));
      final a = HwDeviceKey.enrollmentChallenge(
          email: 'Student@Example.COM', installId: 'inst-1', pkS: pkS);
      final b = deviceBindingChallenge(
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

  group('HwDeviceKey bind/ensure/level', () {
    test('bind caches pkD64 + chain + 90d window + challenge', () async {
      final backend = _FakeHwBackend();
      final d = HwDeviceKey(backend: backend);
      final pkS = Uint8List.fromList(List.filled(32, 5));
      await d.bindEnrollment(
          email: 's@x.in', installId: 'inst-1', pkS: pkS);
      expect(d.pkD.length, 64);
      expect(d.pkDHex.length, 128);
      expect(d.level, AttestationLevel.full);
      expect(d.chainDER, hasLength(1));
      expect(d.chainDERHex, hasLength(1));
      expect(d.lastChallenge,
          deviceBindingChallenge(emailLower: 's@x.in', installId: 'inst-1', pkS: pkS));
      expect(backend.attestCalls, 1);
      final window = d.attestedUntil.difference(d.attestedAt);
      expect(window, kDeviceAttestedValidity);
      expect(await d.heartbeat(), isTrue);
      // ensure() passes once bound.
      await d.ensure();
    });

    test('ensure without bind → Software-no-enroll', () async {
      final d = HwDeviceKey(backend: _FakeHwBackend());
      expect(() => d.ensure(), throwsA(isStateError.having(
          (e) => e.message, 'message', contains('Software-no-enroll'))));
      expect(() => d.pkD, throwsStateError);
    });

    test('software level → Software-no-enroll (no silent downgrade)',
        () async {
      final d = HwDeviceKey(
          backend: _FakeHwBackend(level: AttestationLevel.none));
      expect(
          () => d.bindEnrollment(
              email: 's@x.in', installId: 'i', pkS: Uint8List(32)),
          throwsA(isStateError.having(
              (e) => e.message, 'message', contains('Software-no-enroll'))));
    });
  });

  group('HwDeviceKey seal/unseal (HW-bound envelope)', () {
    test('roundtrip; tamper/clone → restore detected', () async {
      final backend = _FakeHwBackend();
      final d = HwDeviceKey(backend: backend);
      await d.bindEnrollment(
          email: 's@x.in',
          installId: 'inst-1',
          pkS: Uint8List.fromList(List.filled(32, 5)));
      final seed = Uint8List.fromList(List.generate(32, (i) => i));
      final sealed = await d.seal(seed);
      expect(sealed.length, 4 + 12 + 32 + 16);
      expect(await d.unseal(sealed), seed);

      // Tampered body fails closed.
      final bad = Uint8List.fromList(sealed);
      bad[20] ^= 0xFF;
      expect(() => d.unseal(bad),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));

      // Clone: same ciphertext, different HW key (different pkD) fails.
      final cloneBackend = _FakeHwBackend(
          pkD: Uint8List.fromList(List.generate(64, (i) => (i * 5 + 1) & 0xFF)));
      final clone = HwDeviceKey(backend: cloneBackend);
      await clone.bindEnrollment(
          email: 's@x.in',
          installId: 'inst-CLONE',
          pkS: Uint8List.fromList(List.filled(32, 5)));
      expect(() => clone.unseal(sealed),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));

      // Deleted HW key (biometric invalidation) fails closed.
      await backend.deleteKey(alias: kHwDeviceKeyAlias);
      expect(() => d.unseal(sealed),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));
    });

    test('sign returns 64B ES256 raw R||S', () async {
      final d = HwDeviceKey(backend: _FakeHwBackend());
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
      final d = HwDeviceKey(backend: _FakeHwBackend());
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
