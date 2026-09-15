// sec-chain — offline full X.509 chain-signature verification.
//
// Genuine Google fixtures (public test vectors, not secrets) + forged
// negatives proving the signature check is load-bearing beyond the pin:
// a chain whose root hash is PINNED but whose leaf signature is invalid
// MUST fail (bad-chain-signature), never confirm on pin alone.
//
// Fixture provenance:
// - `_chainLeafPem` .. `_chainRootPem`: the 4-cert chain from
//   android/keyattestation testdata `blueline/sdk28/TEE_EC_NONE.pem`
//   (leaf attestationChallenge "challenge" + 2 intermediates + legacy
//   2016 RSA root). The leaf DER (643B) is byte-identical to the
//   `_genuineLeafDerHex` ground truth in hardware_verify_test.dart.
//   NOTE: the root here is the LEGACY 2016 root (expired May 2026) — it is
//   pinned EXPLICITLY in these tests only to prove signature math on real
//   Google certs. Production defaults (`defaultPinnedAttestationRoots`)
//   deliberately omit legacy roots; pre-2021 chains fail closed as
//   `unknown-root` there.
// - `_currentEcRootPem`: the current EC P-384 root from
//   android/keyattestation `roots.json` (CN "Key Attestation CA1") —
//   covers the P-384 path. Its SHA256 matches
//   `kGoogleHwAttestationRootEcSha256Hex`.
//
// Pure Dart — no platform code, no network, no IMEI.
import 'dart:convert';
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

Uint8List _pemToDer(String pem) {
  final lines = pem.split('\n').map((l) => l.trim()).where((l) =>
      l.isNotEmpty &&
      !l.startsWith('-----BEGIN') &&
      !l.startsWith('-----END'));
  return Uint8List.fromList(base64.decode(lines.join()));
}

// -- Genuine 4-cert chain (TEE_EC_NONE.pem) --------------------------------

const _chainLeafPem = '''-----BEGIN CERTIFICATE-----
MIICfzCCAiagAwIBAgIBATAKBggqhkjOPQQDAjApMRkwFwYDVQQFExBhMGI2M2Ez
NTc0MzY3M2I3MQwwCgYDVQQMDANURUUwIBcNNzAwMTAxMDAwMDAwWhgPMjEwNjAy
MDcwNjI4MTVaMB8xHTAbBgNVBAMMFEFuZHJvaWQgS2V5c3RvcmUgS2V5MFkwEwYH
KoZIzj0CAQYIKoZIzj0DAQcDQgAEQ4ejMmmc5O9vcHpHjfo1EnLIuGseb9fTM26F
PBQBMjUAo0zyVYJQpnExkAnFnpKkfZPAyk7gLdFEngSetIk01qOCAUUwggFBMA4G
A1UdDwEB/wQEAwIHgDCCAS0GCisGAQQB1nkCAREEggEdMIIBGQIBAwoBAQIBBAoB
AQQJY2hhbGxlbmdlBAAwgYO/hT0IAgYBZiKOLXa/hUVzBHEwbzFJMEcEQmNvbS5n
b29nbGUud2lyZWxlc3MuYW5kcm9pZC5zZWN1cml0eS5hdHRlc3RhdGlvbnZlcmlm
aWVyLmNvbGxlY3RvcgIBADEiBCAQOTjuRTflno7nkvZUUE+4NG/Gs0bQu8RBX8M5
/PyOwTB4oQUxAwIBAqIDAgEDowQCAgEAqgMCAQG/g3cCBQC/hT4DAgEAv4VALDAq
BAABAQAKAQIEIG6dDFvqLNqZ8+XHb7J0DN+Hk9HTY0Is0GXSK/Ciu1utv4VBBQID
AV+Qv4VCBQIDAxS0v4VOBQIDAxRRv4VPBQIDAxS0MAoGCCqGSM49BAMCA0cAMEQC
IA21HJafZI/wGy5lXuBtZt40jaXq6zlbXm9kPJm3CzFQAiA81uyzS8PTA/h9W5hC
jrSGcsjHj3vZ0fDFxjq8JHAckg==
-----END CERTIFICATE-----''';

const _chainInter1Pem = '''-----BEGIN CERTIFICATE-----
MIICJTCCAaugAwIBAgIKBQFBMZUIaJgwUzAKBggqhkjOPQQDAjApMRkwFwYDVQQF
ExBlMThjNGYyY2E2OTk3MzlhMQwwCgYDVQQMDANURUUwHhcNMTgwNzIzMjAzMzI4
WhcNMjgwNzIwMjAzMzI4WjApMRkwFwYDVQQFExBhMGI2M2EzNTc0MzY3M2I3MQww
CgYDVQQMDANURUUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATTv5kVHCdbVoeY
YPnrPjNJ0QNtZMeJAKq0e0w5XfCMc2iHvHmZZ+hmWJud1S94wLKPJKx8OkJfpJg2
fZoISK4Wo4G6MIG3MB0GA1UdDgQWBBRGZfPoN9ZqhkjAS/oWiLsbm6HO9TAfBgNV
HSMEGDAWgBStaJfkd3MUTYzmNFYScunw3VEFvjAPBgNVHRMBAf8EBTADAQH/MA4G
A1UdDwEB/wQEAwICBDBUBgNVHR8ETTBLMEmgR6BFhkNodHRwczovL2FuZHJvaWQu
Z29vZ2xlYXBpcy5jb20vYXR0ZXN0YXRpb24vY3JsLzA1MDE0MTMxOTUwODY4OTgz
MDUzMAoGCCqGSM49BAMCA2gAMGUCMQDtPMGkhcrmmUIm0iDXKgtlIGE/27j9e44P
9lEoqbvgy4wT4pmfxYrP7S6JunE+2qcCMHt3SohaS7BaOu7awdlsdLoRO1avJURZ
fJnen8gPP+oiqw/P5tWy59kgcDOEcohbvg==
-----END CERTIFICATE-----''';

const _chainInter2Pem = '''-----BEGIN CERTIFICATE-----
MIID0TCCAbmgAwIBAgIKA4gmZ2BliZaFnjANBgkqhkiG9w0BAQsFADAbMRkwFwYD
VQQFExBmOTIwMDllODUzYjZiMDQ1MB4XDTE4MDcyMzIwMTM0MloXDTI4MDcyMDIw
MTM0MlowKTEZMBcGA1UEBRMQZTE4YzRmMmNhNjk5NzM5YTEMMAoGA1UEDAwDVEVF
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEbRn8j/RF9mvI3WO2fMpitlBrovJ+SrHx
4KBjW+Bcg1hnYTATavDaNk2O5ADA2KllkHLDSxIUTMMz6Zb7gJUd+/dC3sI701cR
h0aWV9RzqnlgdR3IChRY4yuG9BSwoTfmo4G2MIGzMB0GA1UdDgQWBBStaJfkd3MU
TYzmNFYScunw3VEFvjAfBgNVHSMEGDAWgBQ2YeEAfIgFCVGLRGxH/xpMyepPEjAP
BgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwICBDBQBgNVHR8ESTBHMEWgQ6BB
hj9odHRwczovL2FuZHJvaWQuZ29vZ2xlYXBpcy5jb20vYXR0ZXN0YXRpb24vY3Js
L0U4RkExOTYzMTREMkZBMTgwDQYJKoZIhvcNAQELBQADggIBAEWkf0CP/lLv+Reh
kJGy3VwI85YJ4ZshZVhUfUD0CcQR9VfGFjEEFN0ako0O+b7noTzZ+fwJqfMClmUk
ZAnhJtYGJgGnF9bmTq5Itr/Cny0hmCkDdrqO52vi4ILz4gEkUVjLBY1A/UVipmVt
kXgvEgdBUBmjv9fD7VP64vandbCAMtZpTCvu8cEAPgyh7EcaVhv1OEy7jahqJOIt
poBvFySwQ0+1zF+7xJzLSQZESGb/eU3NimwLhNN/MFbZCQh3itdYZ0wqD6O3uCV/
Jlx7SEakp+QOMk98IYA8276DJIgKkko3bLSmWrAP13zkea8geWCTFOfYfBo8g1in
mipKNQL/nXTfixdA4OUYzQ/YKfrc5r+ux0EpxYiVEi53/aVMNeSbV+lOzbRctq1V
wJPq4a00HBx1jwtZNmSjPWJjFkNu4bEU9bctCSHLsMsjEO3KGJRTGRATK7Dz43Qu
rhwypvN/ZZl1K4NV+9RY4zNZV6ix9mWl+4cQAiPrJtrvohLtz7FM0LYZ3nz+Ak2j
iCNQsKpOH3fuALhkQ6xZXVKoXmckEmXUc0wSSJ0qfkPD7SVpxjGeeiFmlWXM6ee1
QFwKMcfaWQvqNTbKEihVSqV2BjXvxICsW93WEyqzt/COpcugGlvObeUTrqXuh59l
o9ZGllgJgFJeGqByZDbQGawyB4Rc
-----END CERTIFICATE-----''';

const _chainRootPem = '''-----BEGIN CERTIFICATE-----
MIIFYDCCA0igAwIBAgIJAOj6GWMU0voYMA0GCSqGSIb3DQEBCwUAMBsxGTAXBgNV
BAUTEGY5MjAwOWU4NTNiNmIwNDUwHhcNMTYwNTI2MTYyODUyWhcNMjYwNTI0MTYy
ODUyWjAbMRkwFwYDVQQFExBmOTIwMDllODUzYjZiMDQ1MIICIjANBgkqhkiG9w0B
AQEFAAOCAg8AMIICCgKCAgEAr7bHgiuxpwHsK7Qui8xUFmOr75gvMsd/dTEDDJdS
Sxtf6An7xyqpRR90PL2abxM1dEqlXnf2tqw1Ne4Xwl5jlRfdnJLmN0pTy/4lj4/7
tv0Sk3iiKkypnEUtR6WfMgH0QZfKHM1+di+y9TFRtv6y//0rb+T+W8a9nsNL/ggj
nar86461qO0rOs2cXjp3kOG1FEJ5MVmFmBGtnrKpa73XpXyTqRxB/M0n1n/W9nGq
C4FSYa04T6N5RIZGBN2z2MT5IKGbFlbC8UrW0DxW7AYImQQcHtGl/m00QLVWutHQ
oVJYnFPlXTcHYvASLu+RhhsbDmxMgJJ0mcDpvsC4PjvB+TxywElgS70vE0XmLD+O
JtvsBslHZvPBKCOdT0MS+tgSOIfga+z1Z1g7+DVagf7quvmag8jfPioyKvxnK/Eg
sTUVi2ghzq8wm27ud/mIM7AY2qEORR8Go3TVB4HzWQgpZrt3i5MIlCaY504LzSRi
igHCzAPlHws+W0rB5N+er5/2pJKnfBSDiCiFAVtCLOZ7gLiMm0jhO2B6tUXHI/+M
RPjy02i59lINMRRev56GKtcd9qO/0kUJWdZTdA2XoS82ixPvZtXQpUpuL12ab+9E
aDK8Z4RHJYYfCT3Q5vNAXaiWQ+8PTWm2QgBR/bkwSWc+NpUFgNPN9PvQi8WEg5Um
AGMCAwEAAaOBpjCBozAdBgNVHQ4EFgQUNmHhAHyIBQlRi0RsR/8aTMnqTxIwHwYD
VR0jBBgwFoAUNmHhAHyIBQlRi0RsR/8aTMnqTxIwDwYDVR0TAQH/BAUwAwEB/zAO
BgNVHQ8BAf8EBAMCAYYwQAYDVR0fBDkwNzA1oDOgMYYvaHR0cHM6Ly9hbmRyb2lk
Lmdvb2dsZWFwaXMuY29tL2F0dGVzdGF0aW9uL2NybC8wDQYJKoZIhvcNAQELBQAD
ggIBACDIw41L3KlXG0aMiS//cqrG+EShHUGo8HNsw30W1kJtjn6UBwRM6jnmiwfB
Pb8VA91chb2vssAtX2zbTvqBJ9+LBPGCdw/E53Rbf86qhxKaiAHOjpvAy5Y3m00m
qC0w/Zwvju1twb4vhLaJ5NkUJYsUS7rmJKHHBnETLi8GFqiEsqTWpG/6ibYCv7rY
DBJDcR9W62BW9jfIoBQcxUCUJouMPH25lLNcDc1ssqvC2v7iUgI9LeoM1sNovqPm
QUiG9rHli1vXxzCyaMTjwftkJLkf6724DFhuKug2jITV0QkXvaJWF4nUaHOTNA4u
JU9WDvZLI1j83A+/xnAJUucIv/zGJ1AMH2boHqF8CY16LpsYgBt6tKxxWH00XcyD
CdW2KlBCeqbQPcsFmWyWugxdcekhYsAWyoSf818NUsZdBWBaR/OukXrNLfkQ79Iy
ZohZbvabO/X+MVT3rriAoKc8oE2Uws6DF+60PV7/WIPjNvXySdqspImSN78mflxD
qwLqRBYkA3I75qppLGG9rp7UCdRjxMl8ZDBld+7yvHVgt1cVzJx9xnyGCC23Uaic
MDSXYrB4I4WHXPGjxhZuCuPBLTdOLU8YRvMYdEvYebWHMpvwGCF6bAx3JBpIeOQ1
wDB5y0USicV3YgYGmi+NZfhA4URSh77Yd6uuJOJENRaNVTzk
-----END CERTIFICATE-----''';

// -- Current EC P-384 root (roots.json) ------------------------------------

const _currentEcRootPem = '''-----BEGIN CERTIFICATE-----
MIICIjCCAaigAwIBAgIRAISp0Cl7DrWK5/8OgN52BgUwCgYIKoZIzj0EAwMwUjEc
MBoGA1UEAwwTS2V5IEF0dGVzdGF0aW9uIENBMTEQMA4GA1UECwwHQW5kcm9pZDET
MBEGA1UECgwKR29vZ2xlIExMQzELMAkGA1UEBhMCVVMwHhcNMjUwNzE3MjIzMjE4
WhcNMzUwNzE1MjIzMjE4WjBSMRwwGgYDVQQDDBNLZXkgQXR0ZXN0YXRpb24gQ0Ex
MRAwDgYDVQQLDAdBbmRyb2lkMRMwEQYDVQQKDApHb29nbGUgTExDMQswCQYDVQQG
EwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABCPaI3FO3z5bBQo8cuiEas4HjqCt
G/mLFfRT0MsIssPBEEU5Cfbt6sH5yOAxqEi5QagpU1yX4HwnGb7OtBYpDTB57uH5
Eczm34A5FNijV3s0/f0UPl7zbJcTx6xwqMIRq6NCMEAwDwYDVR0TAQH/BAUwAwEB
/zAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFFIyuyz7RkOb3NaBqQ5lZuA0QepA
MAoGCCqGSM49BAMDA2gAMGUCMETfjPO/HwqReR2CS7p0ZWoD/LHs6hDi422opifH
EUaYLxwGlT9SLdjkVpz0UUOR5wIxAIoGyxGKRHVTpqpGRFiJtQEOOTp/+s1GcxeY
uR2zh/80lQyu9vAFCj6E4AXc+osmRg==
-----END CERTIFICATE-----''';

List<Uint8List> _genuineChain() => [
      _pemToDer(_chainLeafPem),
      _pemToDer(_chainInter1Pem),
      _pemToDer(_chainInter2Pem),
      _pemToDer(_chainRootPem),
    ];

void main() {
  group('genuine Google chain (ECDSA P-256 leaf + RSA root)', () {
    test('leaf DER is byte-identical to the OID ground truth', () {
      // Guards fixture drift: the leaf here must stay the same cert the
      // OID/challenge helpers were byte-verified against.
      final leaf = _pemToDer(_chainLeafPem);
      expect(leaf.length, 643);
      expect(attestationLeafHasKeyOid(leaf), isTrue);
      expect(
          attestationLeafContainsChallenge(
              leaf, Uint8List.fromList('challenge'.codeUnits)),
          isTrue);
    });

    test('TBS signatures verify end-to-end (leaf-first)', () {
      final r = verifyChainSignaturesLeafFirst(_genuineChain());
      expect(r.ok, isTrue, reason: r.reason);
      expect(r.reason, 'ok');
    });

    test('full pin gate passes on the genuine chain (pre-gates + sig)', () {
      final certs = _genuineChain();
      final rootHash = ProxCrypto.sha256Sync(certs.last);
      final r = verifyAttestationChainPin(
        chain: AttestationChain(certs),
        pinnedRootHashes: [rootHash],
        expectedChallenge: Uint8List.fromList('challenge'.codeUnits),
        level: AttestationLevel.full,
      );
      expect(r.ok, isTrue, reason: r.reason);
    });

    test('legacy root is self-signed (RSA path)', () {
      final certs = _genuineChain();
      final r = verifyChainSignaturesLeafFirst([certs.last]);
      expect(r.ok, isTrue, reason: r.reason);
    });
  });

  group('forged chain (pinned root, invalid sig) must fail', () {
    test('leaf sig tamper fails closed even though pin matches', () {
      final certs = _genuineChain();
      // Forge: flip the last leaf byte (inside the ECDSA signatureValue).
      // OID + challenge bytes are untouched and the root is unchanged, so
      // every pre-gate still passes — only the TBS signature is invalid.
      final forgedLeaf = Uint8List.fromList(certs[0]);
      forgedLeaf[forgedLeaf.length - 1] ^= 0xFF;
      final forged = [forgedLeaf, certs[1], certs[2], certs[3]];
      final sig = verifyChainSignaturesLeafFirst(forged);
      expect(sig.ok, isFalse);
      expect(sig.reason, 'bad-chain-signature');
      final rootHash = ProxCrypto.sha256Sync(certs.last);
      final pin = verifyAttestationChainPin(
        chain: AttestationChain(forged),
        pinnedRootHashes: [rootHash],
        expectedChallenge: Uint8List.fromList('challenge'.codeUnits),
        level: AttestationLevel.full,
      );
      expect(pin.ok, isFalse);
      expect(pin.reason, 'bad-chain-signature');
    });

    test('tampered root pinned to its own hash still fails self-check', () {
      final certs = _genuineChain();
      final badRoot = Uint8List.fromList(certs.last);
      badRoot[badRoot.length - 1] ^= 0xFF;
      // Attacker pins the TAMPERED root hash so the pin gate passes —
      // the self-signature check must still fail closed.
      final tamperedHash = ProxCrypto.sha256Sync(badRoot);
      final sig = verifyChainSignaturesLeafFirst([badRoot]);
      expect(sig.ok, isFalse);
      expect(sig.reason, 'bad-root-signature');
      final pin = verifyAttestationChainPin(
        chain: AttestationChain([certs[0], certs[1], certs[2], badRoot]),
        pinnedRootHashes: [tamperedHash],
        expectedChallenge: Uint8List.fromList('challenge'.codeUnits),
        level: AttestationLevel.full,
      );
      // Either the chain link or the root self-check fails — never ok.
      expect(pin.ok, isFalse);
    });

    test('reordered chain fails (issuer mismatch, no silent accept)', () {
      final certs = _genuineChain();
      final reordered = [certs[1], certs[0], certs[2], certs[3]];
      final r = verifyChainSignaturesLeafFirst(reordered);
      expect(r.ok, isFalse);
      expect(r.reason, 'issuer-mismatch');
    });

    test('garbage DER fails closed (never throws)', () {
      expect(
          verifyChainSignaturesLeafFirst(
              [Uint8List.fromList([1, 2, 3])]).ok,
          isFalse);
      expect(
          verifyChainSignaturesLeafFirst(
              [Uint8List.fromList([1, 2, 3])]).reason,
          'bad-chain-der');
      expect(verifyChainSignaturesLeafFirst(const []).ok, isFalse);
    });
  });

  group('leaf-pkD bind (C2 key-substitution)', () {
    test('extracted leaf SPKI round-trips as expectedLeafPkD', () {
      final certs = _genuineChain();
      final rootHash = ProxCrypto.sha256Sync(certs.last);
      final leafPkD = extractLeafEcPublicKeyRaw(certs.first);
      expect(leafPkD, isNotNull);
      expect(leafPkD, hasLength(64));
      final r = verifyAttestationChainPin(
        chain: AttestationChain(certs),
        pinnedRootHashes: [rootHash],
        expectedChallenge: Uint8List.fromList('challenge'.codeUnits),
        level: AttestationLevel.full,
        expectedLeafPkD: leafPkD,
      );
      expect(r.ok, isTrue, reason: r.reason);
    });

    test('wrong pkD fails leaf-pkd-mismatch before challenge/pin', () {
      final certs = _genuineChain();
      final rootHash = ProxCrypto.sha256Sync(certs.last);
      final leafPkD = extractLeafEcPublicKeyRaw(certs.first)!;
      final wrong = Uint8List.fromList(leafPkD)..[0] ^= 0xFF;
      final r = verifyAttestationChainPin(
        chain: AttestationChain(certs),
        pinnedRootHashes: [rootHash],
        expectedChallenge: Uint8List.fromList('challenge'.codeUnits),
        level: AttestationLevel.full,
        expectedLeafPkD: wrong,
      );
      expect(r.ok, isFalse);
      expect(r.reason, 'leaf-pkd-mismatch');
    });
  });

  group('current EC P-384 root (self-signed)', () {
    test('self-signature verifies with its own P-384 key', () {
      final root = _pemToDer(_currentEcRootPem);
      expect(root.length, 550);
      expect(hexEncode(ProxCrypto.sha256Sync(root)),
          kGoogleHwAttestationRootEcSha256Hex);
      final r = verifyChainSignaturesLeafFirst([root]);
      expect(r.ok, isTrue, reason: r.reason);
    });

    test('tampered P-384 root fails closed', () {
      final root = _pemToDer(_currentEcRootPem);
      final bad = Uint8List.fromList(root);
      bad[bad.length - 1] ^= 0xFF;
      final r = verifyChainSignaturesLeafFirst([bad]);
      expect(r.ok, isFalse);
      expect(r.reason, 'bad-root-signature');
    });
  });

  group('RFC 5280 validity century rule (field 2026-09-15)', () {
    test('UTCTime 70 reads as 1970, not 2070 (iQOO Trustonic leaf)', () {
      // The genuine failing leaf encoded notBefore `700101000000Z`: the
      // x509 package mapped it to 2070 (phantom expired-cert) while RFC
      // 5280 — and Android/BoringSSL — read 1970.
      expect(parseX509ValidityTime('700101000000Z', isUtcTime: true),
          DateTime.utc(1970, 1, 1));
      expect(parseX509ValidityTime('480101000000Z', isUtcTime: true),
          DateTime.utc(2048, 1, 1));
    });

    test('UTCTime cutoff: 00-49 go to 2000s, 50-99 to 1900s', () {
      expect(parseX509ValidityTime('000101000000Z', isUtcTime: true),
          DateTime.utc(2000, 1, 1));
      expect(parseX509ValidityTime('490101000000Z', isUtcTime: true),
          DateTime.utc(2049, 1, 1));
      expect(parseX509ValidityTime('500101000000Z', isUtcTime: true),
          DateTime.utc(1950, 1, 1));
      expect(parseX509ValidityTime('991231235959Z', isUtcTime: true),
          DateTime.utc(1999, 12, 31, 23, 59, 59));
    });

    test('GeneralizedTime carries its century literally', () {
      expect(parseX509ValidityTime('20480101000000Z', isUtcTime: false),
          DateTime.utc(2048, 1, 1));
      expect(parseX509ValidityTime('20700101000000Z', isUtcTime: false),
          DateTime.utc(2070, 1, 1));
    });

    test('malformed times fail closed as null', () {
      expect(parseX509ValidityTime('', isUtcTime: true), isNull);
      expect(parseX509ValidityTime('not-a-date', isUtcTime: true), isNull);
      expect(parseX509ValidityTime('700101000000Z', isUtcTime: false), isNull);
      expect(parseX509ValidityTime('20480101000000Z', isUtcTime: true), isNull);
      expect(parseX509ValidityTime('701301000000Z', isUtcTime: true), isNull);
    });

    test('non-profile shapes fail closed (BoringSSL-grade strictness)', () {
      // Leap second, impossible calendar days, seconds-less forms: all
      // rejected — the RFC 5280 profile requires seconds + real dates.
      expect(parseX509ValidityTime('700101000060Z', isUtcTime: true), isNull);
      expect(parseX509ValidityTime('700230000000Z', isUtcTime: true), isNull);
      expect(parseX509ValidityTime('230229000000Z', isUtcTime: true), isNull);
      expect(parseX509ValidityTime('7001010000Z', isUtcTime: true), isNull);
      expect(parseX509ValidityTime('204801010000Z', isUtcTime: false), isNull);
      expect(parseX509ValidityTime('240229000000Z', isUtcTime: true),
          DateTime.utc(2024, 2, 29));
    });

    test('genuine fixture leaf (UTCTime 70) debugs as 1970 ok', () {
      // Google's own reference leaf (blueline TEE_EC_NONE) carries the same
      // epoch-anchored convention: notBefore UTCTime `70`, notAfter
      // GeneralizedTime 2106.
      final leaf = _pemToDer(_chainLeafPem);
      final line = chainValidityDebugLine([leaf],
          now: DateTime.utc(2026, 9, 15));
      expect(line, contains('cert0:1970-01-01→2106-02-07 ok'));
    });

    test('validity gate accepts the epoch-anchored leaf', () {
      final leaf = _pemToDer(_chainLeafPem);
      // checkValidity only inspects dates here (signatures need the full
      // chain); the leaf alone must not fail as expired-cert.
      final r = verifyChainSignaturesLeafFirst([leaf],
          checkValidity: true, now: DateTime.utc(2026, 9, 15));
      expect(r.reason, isNot('expired-cert'));
    });

    test('full pin gate passes with validity on (time-travelled)', () {
      // The whole genuine chain (epoch-anchored leaf + 2018 intermediates
      // + 2016 root) is simultaneously valid around 2025: with the old
      // 2070 mapping this failed as expired-cert on the LEAF; with the
      // RFC 5280 rule it passes. Pins the test-only legacy root hash.
      final certs = _genuineChain();
      final rootHash = ProxCrypto.sha256Sync(certs.last);
      final r = verifyAttestationChainPin(
        chain: AttestationChain(certs),
        pinnedRootHashes: [rootHash],
        expectedChallenge: Uint8List.fromList('challenge'.codeUnits),
        level: AttestationLevel.full,
        now: DateTime.utc(2025, 6, 1),
        checkValidity: true,
      );
      expect(r.ok, isTrue, reason: '${r.reason} ${r.flags}');
    });
  });
}
