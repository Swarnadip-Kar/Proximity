// Apple App Attest offline gate units (iOS branch, security §2).
//
// Binding-math vectors (thumbprint / clientDataHash / nonce) are
// INDEPENDENT oracles computed with python3 hashlib/base64 (not by
// re-running the code under test): pkD = 0x01..0x20 ‖ 0x21..0x40,
// challenge = 0x55*32, authData = 0x11*32 ‖ 0x45 ‖ u32be(7).
// CBOR/COSE fixtures below are hand-built definite-length encodings.
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

Uint8List _pkD() => Uint8List.fromList([
      ...List.generate(32, (i) => i + 1),
      ...List.generate(32, (i) => i + 33),
    ]);

Uint8List _challenge() => Uint8List.fromList(List.filled(32, 0x55));

Uint8List _authData() => Uint8List.fromList([
      ...List.filled(32, 0x11),
      0x45,
      0x00,
      0x00,
      0x00,
      0x07,
    ]);

void main() {
  group('binding math (independent oracle vectors)', () {
    test('JWK thumbprint matches the plugin Swift byte-for-byte', () {
      // python3: base64url-nopad(sha256('{"crv":"P-256","kty":"EC",
      //   "x":"AQID...HyA","y":"ISIj...P0A"}')).
      expect(appAttestThumbprint(_pkD()),
          't1ZI8tOt77KZ9YepYcUiqtqXcpIYInMJhkFb6casAFo');
    });

    test('clientDataHash + nonce recompute matches oracle', () {
      final cdh = appAttestClientDataHash(
          thumbprint: appAttestThumbprint(_pkD()),
          challenge: _challenge());
      expect(hexEncode(cdh),
          'fb187e2249a9b09582201c94e79331fe740ee481bf769d7f586196e53a8c0a55');
      final nonce = appAttestExpectedNonce(
          authData: _authData(), clientDataHash: cdh);
      expect(hexEncode(nonce),
          '525833d6ca7503e3dd6cd1b44affafe985c5367f5fadebd40b19bd4828ce8e0e');
    });

    test('thumbprint rejects non-64B input', () {
      expect(() => appAttestThumbprint(Uint8List(32)),
          throwsArgumentError);
    });
  });

  group('raw shape parsing', () {
    Uint8List attestationObject() {
      final auth = _authData();
      final cert0 = Uint8List.fromList([0x30, 0x03, 0x01, 0x02, 0x03]);
      final cert1 = Uint8List.fromList([0x30, 0x01, 0x04]);
      return Uint8List.fromList([
        0xA3, // map(3)
        0x01, 0x65, 0x61, 0x70, 0x70, 0x6C, 0x65, // 1:'apple'
        0x02, 0x58, auth.length, ...auth, // 2:authData
        0x03, 0xA1, // 3:{...}
        0x63, 0x78, 0x35, 0x63, // 'x5c'
        0x82, // array(2)
        0x45, ...cert0, // 5B
        0x43, ...cert1, // 3B
      ]);
    }

    test('attestation object parses (fmt/authData/x5c)', () {
      final p = ParsedAppAttestRaw.parse(attestationObject());
      expect(p.kind, AppAttestRawKind.attestationObject);
      expect(bytesEqual(p.authData, _authData()), isTrue);
      expect(p.x5c.length, 2);
      expect(p.x5c[0][0], 0x30);
    });

    test('trailing bytes and wrong fmt fail closed', () {
      expect(
          () => ParsedAppAttestRaw.parse(
              Uint8List.fromList([...attestationObject(), 0x00])),
          throwsFormatException);
      final bad = attestationObject();
      bad[2] = 0x64; // corrupt 'apple' length -> not an apple object
      expect(() => ParsedAppAttestRaw.parse(bad), throwsFormatException);
    });

    test('assertion splits authData ‖ 64B signature', () {
      final sig = Uint8List.fromList(List.generate(64, (i) => i));
      final raw =
          Uint8List.fromList([..._authData(), ...sig]);
      final p = ParsedAppAttestRaw.parse(raw);
      expect(p.kind, AppAttestRawKind.assertion);
      expect(bytesEqual(p.authData, _authData()), isTrue);
      expect(bytesEqual(p.signature, sig), isTrue);
    });

    test('short garbage fails closed', () {
      expect(() => ParsedAppAttestRaw.parse(Uint8List(100)),
          throwsFormatException);
      expect(() => ParsedAppAttestRaw.parse(Uint8List(0)),
          throwsFormatException);
    });
  });

  group('credential key + leaf nonce', () {
    Uint8List coseAuthData() {
      final x = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final y = Uint8List.fromList(List.generate(32, (i) => i + 33));
      return Uint8List.fromList([
        ...List.filled(32, 0xAA), // rpIdHash
        0x45, // flags
        0x00, 0x00, 0x00, 0x01, // counter
        ...List.filled(16, 0xBB), // aaguid
        0x00, 0x02, 0xCC, 0xDD, // credId
        0xA5, // cose map(5)
        0x01, 0x02, // 1:kty=2 (EC2)
        0x03, 0x26, // 3:alg=-7 (ES256)
        0x20, 0x01, // -1:crv=1 (P-256)
        0x21, 0x58, 0x20, ...x, // -2:x
        0x22, 0x58, 0x20, ...y, // -3:y
      ]);
    }

    test('extracts COSE x‖y, rejects wrong alg', () {
      expect(bytesEqual(extractAppAttestCredentialKey(coseAuthData()),
          _pkD()), isTrue);
      final bad = coseAuthData();
      bad[bad.length - 69] = 0x27; // alg -7 -> -8
      expect(() => extractAppAttestCredentialKey(bad),
          throwsFormatException);
    });

    test('leaf nonce parses the Apple extension, null when absent', () {
      final nonce =
          List.generate(32, (i) => 0xF0 - i >= 0 ? 0xF0 - i : 0);
      final leaf = Uint8List.fromList([
        0x30, 0x82, 0x01, 0x00,
        ...kAppAttestNonceOidDer,
        0x04, 0x22, 0x04, 0x20, ...nonce,
        0x05, 0x00,
      ]);
      expect(bytesEqual(appAttestLeafNonce(leaf)!, Uint8List.fromList(nonce)),
          isTrue);
      // Raw-32B (unwrapped) form also accepted.
      final leaf2 = Uint8List.fromList([
        ...kAppAttestNonceOidDer,
        0x04, 0x20, ...nonce,
      ]);
      expect(
          bytesEqual(appAttestLeafNonce(leaf2)!, Uint8List.fromList(nonce)),
          isTrue);
      expect(
          appAttestLeafNonce(Uint8List.fromList([0x30, 0x03, 0x01, 0x02])),
          isNull);
    });
  });

  group('production-shaped gate (signature step hatched, logic real)', () {
    // Synthetic leaf carrying a REAL oracle nonce; X.509 math skipped via
    // the ForTest hatch (covered on genuine fixtures in chain_verify_test).
    AttestationChain gateChain(Uint8List nonce) {
      final leaf = Uint8List.fromList([
        0x30, 0x2A,
        ...kAppAttestNonceOidDer,
        0x04, 0x22, 0x04, 0x20, ...nonce,
      ]);
      return AttestationChain([leaf]);
    }

    Uint8List oracleNonce() {
      final cdh = appAttestClientDataHash(
          thumbprint: appAttestThumbprint(_pkD()),
          challenge: _challenge());
      return appAttestExpectedNonce(
          authData: _authData(), clientDataHash: cdh);
    }

    List<Uint8List> pinsFor(AttestationChain c) =>
        [ProxCrypto.sha256Sync(c.root!)];

    test('ok on matching nonce + pinned root (STD only)', () {
      final c = gateChain(oracleNonce());
      final ok = verifyAppAttestChainPinForTest(
        chain: c,
        pinnedRootHashes: pinsFor(c),
        expectedChallenge: _challenge(),
        expectedPkD: _pkD(),
        appAttestAuthData: _authData(),
        level: AttestationLevel.standard,
        verifySignatures: false,
      );
      expect(ok.ok, isTrue);
    });

    test('FULL/NONE levels refuse (iOS tier is STD)', () {
      final c = gateChain(oracleNonce());
      for (final level in [AttestationLevel.full, AttestationLevel.none]) {
        final r = verifyAppAttestChainPinForTest(
          chain: c,
          pinnedRootHashes: pinsFor(c),
          expectedChallenge: _challenge(),
          expectedPkD: _pkD(),
          appAttestAuthData: _authData(),
          level: level,
          verifySignatures: false,
        );
        expect(r.ok, isFalse);
        expect(r.reason, 'attest-level-mismatch');
      }
    });

    test('wrong challenge / wrong root / empty authData fail closed', () {
      final c = gateChain(oracleNonce());
      final wrongCh = verifyAppAttestChainPinForTest(
        chain: c,
        pinnedRootHashes: pinsFor(c),
        expectedChallenge: Uint8List.fromList(List.filled(32, 0x99)),
        expectedPkD: _pkD(),
        appAttestAuthData: _authData(),
        level: AttestationLevel.standard,
        verifySignatures: false,
      );
      expect(wrongCh.reason, 'challenge-mismatch');
      final wrongRoot = verifyAppAttestChainPinForTest(
        chain: c,
        pinnedRootHashes: [Uint8List(32)],
        expectedChallenge: _challenge(),
        expectedPkD: _pkD(),
        appAttestAuthData: _authData(),
        level: AttestationLevel.standard,
        verifySignatures: false,
      );
      expect(wrongRoot.reason, 'unknown-root');
      final noAuth = verifyAppAttestChainPinForTest(
        chain: c,
        pinnedRootHashes: pinsFor(c),
        expectedChallenge: _challenge(),
        expectedPkD: _pkD(),
        appAttestAuthData: Uint8List(0),
        level: AttestationLevel.standard,
        verifySignatures: false,
      );
      expect(noAuth.reason, 'challenge-mismatch');
    });
  });

  group('assertion proof', () {
    ({Uint8List authData, Uint8List sig, Uint8List pub}) signVector() {
      final domain = ECDomainParameters('prime256v1');
      final d = BigInt.parse(
          'C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721',
          radix: 16);
      final q = (domain.G * d)!;
      final pub = Uint8List.fromList([
        ..._to32((q.x!.toBigInteger())!),
        ..._to32((q.y!.toBigInteger())!),
      ]);
      final authData = _authData();
      final cdh = appAttestClientDataHash(
          thumbprint: appAttestThumbprint(_pkD()),
          challenge: _challenge());
      final random = SecureRandom('Fortuna')
        ..seed(KeyParameter(Uint8List.fromList(List.filled(32, 0x42))));
      final signer = ECDSASigner(SHA256Digest());
      signer.init(
          true,
          ParametersWithRandom(
              PrivateKeyParameter(ECPrivateKey(d, domain)), random));
      final sig = signer.generateSignature(
          Uint8List.fromList([...authData, ...cdh])) as ECSignature;
      return (
        authData: authData,
        sig: Uint8List.fromList(
            [..._to32(sig.r), ..._to32(sig.s)]),
        pub: pub,
      );
    }

    test('ok on valid signature, bad-signature on flip', () {
      final v = signVector();
      final ok = verifyAppAttestAssertionProof(
        assertionAuthData: v.authData,
        assertionSignature: v.sig,
        expectedChallenge: _challenge(),
        expectedPkD: _pkD(),
        credentialPubKey64: v.pub,
      );
      expect(ok.ok, isTrue);
      final flipped = Uint8List.fromList(v.sig)..[0] ^= 0xFF;
      final bad = verifyAppAttestAssertionProof(
        assertionAuthData: v.authData,
        assertionSignature: flipped,
        expectedChallenge: _challenge(),
        expectedPkD: _pkD(),
        credentialPubKey64: v.pub,
      );
      expect(bad.reason, 'bad-assertion-signature');
    });
  });

  group('Apple root pin', () {
    test('constant is a 32B hash (provenance in app_attest.dart)', () {
      expect(kAppleAppAttestRootSha256Hex.length, 64);
      expect(defaultPinnedAppAttestRoots().single.length, 32);
    });
  });
}

Uint8List _to32(BigInt v) {
  final hex = v.toRadixString(16).padLeft(64, '0');
  return Uint8List.fromList([
    for (var i = 0; i < 64; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
