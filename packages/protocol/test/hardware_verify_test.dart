// sec(hwkey): P-256 ES256 verify + AES-GCM seal envelope + pinned roots.
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

SecureRandom _testRandom([int salt = 3]) {
  final r = SecureRandom('Fortuna');
  r.seed(KeyParameter(Uint8List.fromList(
      List.generate(32, (i) => (i * 11 + salt) & 0xFF))));
  return r;
}

(Uint8List, Uint8List, Uint8List) _signFixture([int salt = 3]) {
  final domain = ECDomainParameters('prime256v1');
  final gen = ECKeyGenerator()
    ..init(ParametersWithRandom(
        ECKeyGeneratorParameters(domain), _testRandom(salt)));
  final pair = gen.generateKeyPair();
  final ECPublicKey pub = pair.publicKey;
  // Uncompressed point 0x04||x||y → raw x||y 64B (the pkD wire form).
  final uncompressed = pub.Q!.getEncoded(false);
  final pkD = Uint8List.fromList(uncompressed.sublist(1));
  final preimage = Uint8List.fromList(List.generate(48, (i) => i));
  final signer = ECDSASigner(SHA256Digest())
    ..init(
        true,
        ParametersWithRandom(
            PrivateKeyParameter<ECPrivateKey>(pair.privateKey),
            _testRandom(salt)));
  final ECSignature sig = signer.generateSignature(preimage) as ECSignature;
  Uint8List be(BigInt v) {
    final hex = v.toRadixString(16).padLeft(64, '0');
    return hexDecode(hex);
  }

  return (pkD, preimage, Uint8List.fromList([...be(sig.r), ...be(sig.s)]));
}

void main() {
  group('verifyDeviceSignature (P-256 ES256)', () {
    test('genuine signature verifies', () {
      final (pkD, preimage, sig) = _signFixture();
      expect(pkD.length, 64);
      expect(sig.length, 64);
      expect(
          verifyDeviceSignature(
              pkDRaw64: pkD, preimage: preimage, sig64: sig),
          isTrue);
    });

    test('tampered sig / preimage / key fail closed (false, never throw)',
        () {
      final (pkD, preimage, sig) = _signFixture();
      final badSig = Uint8List.fromList(sig)..[0] ^= 0xFF;
      final badPre = Uint8List.fromList(preimage)..[0] ^= 0xFF;
      final (otherPkD, _, _) = _signFixture(99);
      expect(
          verifyDeviceSignature(
              pkDRaw64: pkD, preimage: preimage, sig64: badSig),
          isFalse);
      expect(
          verifyDeviceSignature(
              pkDRaw64: pkD, preimage: badPre, sig64: sig),
          isFalse);
      expect(
          verifyDeviceSignature(
              pkDRaw64: otherPkD, preimage: preimage, sig64: sig),
          isFalse);
    });

    test('malformed lengths fail closed', () {
      final (pkD, preimage, sig) = _signFixture();
      expect(
          verifyDeviceSignature(
              pkDRaw64: Uint8List(32),
              preimage: preimage,
              sig64: sig),
          isFalse);
      expect(
          verifyDeviceSignature(
              pkDRaw64: pkD, preimage: preimage, sig64: Uint8List(10)),
          isFalse);
    });
  });

  group('AES-GCM seal envelope (PXK2)', () {
    final dek = Uint8List.fromList(List.generate(32, (i) => (i * 7 + 1) & 0xFF));
    final seed = Uint8List.fromList(List.generate(32, (i) => i));

    test('roundtrip is 64B with fresh nonces', () {
      final a = sealWithDek(dek32: dek, seed32: seed);
      final b = sealWithDek(dek32: dek, seed32: seed);
      expect(a.length, kHwSealEnvelopeBytes);
      expect(a.sublist(0, 4), kHwSealMagic);
      // Fresh CSPRNG nonce per seal: same seed seals differently.
      expect(a, isNot(b));
      expect(unsealWithDek(dek32: dek, sealed: a), seed);
      expect(unsealWithDek(dek32: dek, sealed: b), seed);
    });

    test('tamper / wrong DEK / bad shape → restore detected', () {
      final sealed = sealWithDek(dek32: dek, seed32: seed);
      final badBody = Uint8List.fromList(sealed)..[20] ^= 0xFF;
      final badTag = Uint8List.fromList(sealed)..[60] ^= 0xFF;
      final badMagic = Uint8List.fromList(sealed)..[0] ^= 0xFF;
      final otherDek =
          Uint8List.fromList(List.generate(32, (i) => (i * 13 + 5) & 0xFF));
      for (final bad in [badBody, badTag, badMagic, Uint8List(10)]) {
        expect(
            () => unsealWithDek(dek32: dek, sealed: bad),
            throwsA(isStateError.having((e) => e.message, 'message',
                contains('restore detected — re-enroll'))));
      }
      // Clone: ciphertext under a different device DEK fails.
      expect(
          () => unsealWithDek(dek32: otherDek, sealed: sealed),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));
    });
  });

  group('pinned Google roots', () {
    test('two 32B pins (RSA + EC)', () {
      final pins = defaultPinnedAttestationRoots();
      expect(pins, hasLength(2));
      for (final p in pins) {
        expect(p.length, 32);
      }
      expect(hexEncode(pins[0]), kGoogleHwAttestationRootRsaSha256Hex);
      expect(hexEncode(pins[1]), kGoogleHwAttestationRootEcSha256Hex);
    });

    test('unknown root still fails closed against the real pins', () {
      final challenge = Uint8List.fromList(List.filled(32, 1));
      final leaf = Uint8List.fromList(
          [...kKeyAttestationOidDer, ...challenge, 0xAA]);
      final root = Uint8List.fromList(List.filled(64, 0xBB));
      final r = verifyAttestationChainPin(
        chain: AttestationChain([leaf, root]),
        pinnedRootHashes: defaultPinnedAttestationRoots(),
        expectedChallenge: challenge,
        level: AttestationLevel.full,
      );
      expect(r.ok, isFalse);
      expect(r.reason, 'unknown-root');
    });
  });
}
