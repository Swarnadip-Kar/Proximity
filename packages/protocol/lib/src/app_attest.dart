// Apple App Attest offline verification (iOS branch, security §2).
//
// Split from `device_binding.dart`: the Android gate there is
// key-attestation-OID-shaped, but Apple App Attest objects are CBOR (never
// the Android OID) chaining to the Apple App Attest Root. iOS callers verify
// here; the Android path is untouched.
//
// What the plugin hands us (`attested_secure_keys` iOS, first-party Apple
// frameworks only): attest() returns PgAttestation(type appleAppAttest /
// appleAppAssert, encoding cbor, x5c [], raw <bytes>) where raw is EITHER
// the DCAppAttest attestation object (first registration per install:
// CBOR {1:'apple', 2:authData, 3:{'x5c':[credCert..AppleCA], ...}}) OR a
// lightweight assertion (later calls on the same install: raw
// authenticatorData ‖ 64B P-256 signature, NOT CBOR).
//
// Binding (all offline, pure Dart): the plugin sets
// clientData = ascii(JWK-thumbprint of OUR Secure Enclave key) ‖ challenge
// and clientDataHash = SHA256(clientData). The attestation object's credCert
// carries Apple extension 1.2.840.113635.100.8.2 whose nonce is
// SHA256(authData ‖ clientDataHash). The professor recomputes the thumbprint
// from the live pkD (RFC 7638 over base64url-unpadded x/y — byte-exact with
// the plugin's Swift), recomputes the nonce from the stored authData +
// live challenge, and compares against the Apple-signed leaf. An assertion
// instead proves (signature over authData ‖ clientDataHash') under the
// enrollment credential key with the same recomputed clientDataHash' — the
// credential key itself is TOFU on the assertion path (see below).
//
// Checks (fail-closed, first failure wins), attestation-object path:
// 1. level == STD (iOS tier — Secure Enclave + App Attest standard; FULL
//    is Android-only here, NONE never pins);
// 2. chain non-empty, certs non-empty (x5c extracted from the CBOR object);
// 3. NO Android-OID check (deliberate: App Attest leaves carry the Apple
//    nonce extension, never 1.3.6.1.4.1.11129.2.1.17);
// 4. leaf nonce == SHA256(authData ‖ SHA256(thumbprint(pkD) ‖ challenge))
//    — else `challenge-mismatch` (binds SE key + enrollment challenge);
// 5. X.509 signatures verify offline BEFORE the pin is trusted
//    (M4 validate-then-trust, same `chain_verify.dart` engine as Android);
// 6. SHA256(root DER) ∈ pinned Apple roots — else `unknown-root`.
//
// Assertion path (same-install iOS re-enroll — the plugin caches the App
// Attest keyId per install, so only the first attest() per install yields
// an object): the signature must verify under the enrollment credential key
// with the recomputed clientDataHash'. The credential key's Apple provenance
// was established at the first (object) enroll; a professor that never saw
// that enroll accepts the credential key TOFU (first-seen stability is
// enforced the same way pkS pins are — a changed key mid-class flags).
// rpId + counter are NOT checked offline (the professor doesn't know the
// teamID.appId binding without a backend) — stated residual, never silent.
//
// Sealed/attestation bytes are never decrypted or interpreted — only
// structure, lengths, signatures and bindings are verified.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pointycastle/export.dart';

import 'bytes.dart';
import 'chain_verify.dart';
import 'crypto/primitives.dart';
import 'device_binding.dart';

/// Apple App Attest Root CA, SHA-256 over the root CERTIFICATE DER.
///
/// Public trust anchor, not a secret — published at
/// https://www.apple.com/certificateauthority/ (Apple_App_Attestation_Root_CA.pem;
/// fetched 2026-09-13: self-signed CN=Apple App Attestation Root CA,
/// serial 0BF3BE0EF1CDD2E0FB8C6E721F621798, 2020-03-18 → 2045-03-15;
/// `openssl x509 -outform DER | openssl dgst -sha256` = the value below).
const String kAppleAppAttestRootSha256Hex =
    '1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932';

/// Default pinned roots for App Attest chains (see above). Fresh copies.
List<Uint8List> defaultPinnedAppAttestRoots() => [
      hexDecode(kAppleAppAttestRootSha256Hex),
    ];

/// Apple App Attest nonce extension OID (credCert carries
/// nonce = SHA256(authData ‖ clientDataHash) here).
const String kAppAttestNonceOid = '1.2.840.113635.100.8.2';

/// DER TLV encoding of [kAppAttestNonceOid]: 06 0B + content
/// 2A 86 48 86 F7 63 64 03 01 08 02 (1*40+2=0x2A; 840=0x86 0x48;
/// 113635 base-128 = 0x86 0xF7 0x63; 100=0x64; 8=0x08; 2=0x02).
const List<int> kAppAttestNonceOidDer = [
  0x06,
  0x0B,
  0x2A,
  0x86,
  0x48,
  0x86,
  0xF7,
  0x63,
  0x64,
  0x03,
  0x01,
  0x08,
  0x02,
];

// ---------------------------------------------------------- CBOR ---

/// Minimal definite-length CBOR reader (App Attest subset): unsigned/negative
/// ints, byte/text strings, arrays, maps. Indefinite lengths, break stop
/// codes, floats and tags throw [FormatException] (fail-closed — Apple emits
/// definite lengths here; anything else is malformed, never skipped).
class _CborReader {
  final Uint8List bytes;
  int pos = 0;
  _CborReader(this.bytes);

  bool get done => pos >= bytes.length;

  int _byte() {
    if (pos >= bytes.length) {
      throw const FormatException('cbor: truncated');
    }
    return bytes[pos++];
  }

  int _arg(int ai) {
    if (ai < 24) return ai;
    if (ai == 24) return _byte();
    if (ai == 25) return (_byte() << 8) | _byte();
    if (ai == 26) {
      var v = 0;
      for (var i = 0; i < 4; i++) {
        v = (v << 8) | _byte();
      }
      return v;
    }
    if (ai == 27) {
      var v = 0;
      for (var i = 0; i < 8; i++) {
        final b = _byte();
        // Fail-closed on lengths overflowing int64: an 8-byte big-endian
        // value exceeds 0x7FFFFFFFFFFFFFFF iff the first byte's high bit
        // is set. Checked without the literal itself — dart2js cannot
        // represent 0x7FFFFFFFFFFFFFFF exactly, so the literal fails the
        // web build (records-only compile gate).
        if (i == 0 && (b & 0x80) != 0) {
          throw const FormatException('cbor: length overflow');
        }
        v = (v << 8) | b;
      }
      return v;
    }
    throw const FormatException('cbor: indefinite/reserved');
  }

  Uint8List _take(int n) {
    if (n < 0 || pos + n > bytes.length) {
      throw const FormatException('cbor: truncated');
    }
    final out = bytes.sublist(pos, pos + n);
    pos += n;
    return out;
  }

  dynamic read() {
    final initial = _byte();
    final major = initial >> 5;
    final ai = initial & 0x1F;
    switch (major) {
      case 0:
        return _arg(ai);
      case 1:
        return -1 - _arg(ai);
      case 2:
        return _take(_arg(ai));
      case 3:
        return utf8.decode(_take(_arg(ai)));
      case 4:
        final n = _arg(ai);
        return [for (var i = 0; i < n; i++) read()];
      case 5:
        final n = _arg(ai);
        final m = <dynamic, dynamic>{};
        for (var i = 0; i < n; i++) {
          m[read()] = read();
        }
        return m;
      default:
        throw const FormatException('cbor: tags/floats unsupported');
    }
  }
}

/// Which Apple shape [raw] carries (see file header).
enum AppAttestRawKind {
  /// First registration per install: CBOR {1:'apple',2:authData,3:attStmt}.
  attestationObject,

  /// Later calls on the same install: raw authenticatorData ‖ 64B signature.
  assertion,
}

/// Parsed Apple raw (attestation object or assertion). Throws
/// [FormatException] on malformed input (fail-closed at the gate).
class ParsedAppAttestRaw {
  final AppAttestRawKind kind;

  /// Authenticator data (authData).
  final Uint8List authData;

  /// Attestation object only: x5c DER certs, leaf-first.
  final List<Uint8List> x5c;

  /// Assertion only: 64B raw R‖S over (authData ‖ clientDataHash).
  final Uint8List signature;

  ParsedAppAttestRaw._({
    required this.kind,
    required this.authData,
    this.x5c = const [],
    required this.signature,
  });

  /// Parses plugin `raw` bytes (see [AppAttestRawKind]).
  factory ParsedAppAttestRaw.parse(Uint8List raw) {
    if (raw.isNotEmpty && raw[0] == 0xA3) {
      // Plausible CBOR map(3) — must fully parse as the Apple object.
      final reader = _CborReader(raw);
      final top = reader.read();
      if (!reader.done) {
        throw const FormatException('appattest: trailing bytes');
      }
      if (top is Map && top[1] == 'apple' && top[2] is Uint8List) {
        final stmt = top[3];
        if (stmt is Map && stmt['x5c'] is List) {
          final certs = <Uint8List>[];
          for (final c in (stmt['x5c'] as List)) {
            if (c is! Uint8List || c.isEmpty) {
              throw const FormatException('appattest: bad x5c entry');
            }
            certs.add(c);
          }
          if (certs.isEmpty) {
            throw const FormatException('appattest: empty x5c');
          }
          return ParsedAppAttestRaw._(
            kind: AppAttestRawKind.attestationObject,
            authData: top[2] as Uint8List,
            x5c: certs,
            signature: Uint8List(0),
          );
        }
      }
      throw const FormatException('appattest: not an apple object');
    }
    // Assertion shape: authenticatorData (rpIdHash 32 + flags 1 + counter 4
    // + at least the attested-credential minimum is NOT required here —
    // assertions carry no credential data, so >= 37B) ‖ 64B signature.
    if (raw.length >= 37 + 64) {
      return ParsedAppAttestRaw._(
        kind: AppAttestRawKind.assertion,
        authData: raw.sublist(0, raw.length - 64),
        signature: raw.sublist(raw.length - 64),
      );
    }
    throw const FormatException('appattest: unrecognized shape');
  }
}

// --------------------------------------------- binding math ---

String _b64urlNoPad(Uint8List bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// JWK thumbprint of the Secure Enclave key, byte-exact with the plugin
/// Swift (`{"crv":"P-256","kty":"EC","x":"..","y":".."}` over
/// base64url-unpadded coordinates, SHA-256, base64url-unpadded ascii).
/// Throws [ArgumentError] unless [pkD] is 64B x‖y.
String appAttestThumbprint(Uint8List pkD) {
  if (pkD.length != 64) {
    throw ArgumentError('appAttestThumbprint needs 64B x||y.');
  }
  final x = _b64urlNoPad(pkD.sublist(0, 32));
  final y = _b64urlNoPad(pkD.sublist(32, 64));
  final canonical = '{"crv":"P-256","kty":"EC","x":"$x","y":"$y"}';
  return _b64urlNoPad(ProxCrypto.sha256Sync(utf8.encode(canonical)));
}

/// clientDataHash = SHA256(ascii(thumbprint) ‖ challenge) — the plugin's
/// clientData is `thumbprint ‖ serverNonce` (serverNonce = our enrollment
/// challenge).
Uint8List appAttestClientDataHash({
  required String thumbprint,
  required Uint8List challenge,
}) =>
    ProxCrypto.sha256Sync(concat([utf8.encode(thumbprint), challenge]));

/// Expected credCert nonce = SHA256(authData ‖ clientDataHash).
Uint8List appAttestExpectedNonce({
  required Uint8List authData,
  required Uint8List clientDataHash,
}) =>
    ProxCrypto.sha256Sync(concat([authData, clientDataHash]));

/// Extracts the 32B Apple nonce from a credCert leaf (extension
/// 1.2.840.113635.100.8.2: extnValue OCTET STRING wrapping either an inner
/// OCTET STRING(32) or the raw 32B). Returns null when absent/malformed
/// (opaque byte walk — the bytes are never decrypted or interpreted).
Uint8List? appAttestLeafNonce(Uint8List leafDer) {
  final needle = kAppAttestNonceOidDer;
  var start = -1;
  outer:
  for (var i = 0; i <= leafDer.length - needle.length; i++) {
    for (var k = 0; k < needle.length; k++) {
      if (leafDer[i + k] != needle[k]) continue outer;
    }
    start = i + needle.length;
    break;
  }
  if (start < 0) return null;
  var p = start;
  if (p >= leafDer.length || leafDer[p++] != 0x04) return null;
  var len = 0;
  if (p >= leafDer.length) return null;
  final lb = leafDer[p++];
  if (lb & 0x80 == 0) {
    len = lb;
  } else {
    final n = lb & 0x7F;
    if (n == 0 || n > 2 || p + n > leafDer.length) return null;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | leafDer[p++];
    }
  }
  if (len <= 0 || p + len > leafDer.length) return null;
  final inner = leafDer.sublist(p, p + len);
  if (inner.length == 34 && inner[0] == 0x04 && inner[1] == 0x20) {
    return inner.sublist(2);
  }
  if (inner.length == 32) return inner;
  return null;
}

/// Credential public key (64B x‖y) from attestation authData
/// (rpIdHash 32 ‖ flags 1 ‖ counter 4 ‖ aaguid 16 ‖ credIdLen u16be ‖
/// credId ‖ COSE_Key map {1:kty=2, 3:alg=-7, -1:crv=1, -2:x, -3:y}).
/// Throws [FormatException] on malformed input.
Uint8List extractAppAttestCredentialKey(Uint8List authData) {
  if (authData.length < 55) {
    throw const FormatException('appattest: authData too short');
  }
  var p = 32 + 1 + 4 + 16;
  final credIdLen = (authData[p] << 8) | authData[p + 1];
  p += 2 + credIdLen;
  if (p >= authData.length) {
    throw const FormatException('appattest: authData truncated at cose');
  }
  final cose = _CborReader(authData.sublist(p)).read();
  if (cose is! Map) {
    throw const FormatException('appattest: cose not a map');
  }
  if (cose[1] != 2 || cose[3] != -7 || cose[-1] != 1) {
    throw const FormatException('appattest: cose not ES256 P-256');
  }
  final x = cose[-2];
  final y = cose[-3];
  if (x is! Uint8List || y is! Uint8List || x.length != 32 || y.length != 32) {
    throw const FormatException('appattest: cose bad coordinates');
  }
  return Uint8List.fromList([...x, ...y]);
}

/// Verifies an App Attest assertion signature offline: ES256 over
/// (authData ‖ clientDataHash) under the 64B credential key. Returns false
/// (never throws) on any failure — the gate maps it to
/// `bad-assertion-signature`.
bool verifyAppAttestAssertion({
  required Uint8List authData,
  required Uint8List signature64,
  required Uint8List clientDataHash,
  required Uint8List credentialPubKey64,
}) {
  try {
    if (signature64.length != 64 || credentialPubKey64.length != 64) {
      return false;
    }
    BigInt be(Uint8List b) {
      var v = BigInt.zero;
      for (final byte in b) {
        v = (v << 8) | BigInt.from(byte);
      }
      return v;
    }

    final domain = ECDomainParameters('prime256v1');
    final q = domain.curve.createPoint(
      be(credentialPubKey64.sublist(0, 32)),
      be(credentialPubKey64.sublist(32, 64)),
    );
    final verifier = ECDSASigner(SHA256Digest());
    verifier.init(false, PublicKeyParameter(ECPublicKey(q, domain)));
    final message = Uint8List.fromList([...authData, ...clientDataHash]);
    return verifier.verifySignature(
      message,
      ECSignature(
        be(signature64.sublist(0, 32)),
        be(signature64.sublist(32, 64)),
      ),
    );
  } catch (_) {
    return false;
  }
}

// --------------------------------------------- production gate ---

bool _allowInsecureAppAttestGate = false;

/// iOS production gate: App Attest chain vs Apple roots + SE-key/challenge
/// nonce binding (see file header — steps 1-6). No downgrade flags by
/// construction (M4): signature math and the Apple nonce check always run.
/// Test-only pre-gate units run through [verifyAppAttestChainPinForTest].
///
/// [appAttestAuthData] is the authData from the enrollment attestation
/// object (persisted in the claim doc at enroll time); [expectedPkD] is the
/// live proving SE key (64B x‖y) whose JWK thumbprint the nonce commits to.
ChainPinResult verifyAppAttestChainPin({
  required AttestationChain chain,
  required List<Uint8List> pinnedRootHashes,
  required Uint8List expectedChallenge,
  required Uint8List expectedPkD,
  required Uint8List appAttestAuthData,
  required AttestationLevel level,
  DateTime? now,
  bool checkValidity = false,
}) =>
    _verifyAppAttestChainPin(
      chain: chain,
      pinnedRootHashes: pinnedRootHashes,
      expectedChallenge: expectedChallenge,
      expectedPkD: expectedPkD,
      appAttestAuthData: appAttestAuthData,
      level: level,
      verifySignatures: true,
      now: now,
      checkValidity: checkValidity,
    );

/// Test-only entry point for gate-logic units with synthetic leaves (not
/// Apple-signed): exposes the [verifySignatures] downgrade the production
/// gate deliberately lacks. Never used outside tests.
@visibleForTesting
ChainPinResult verifyAppAttestChainPinForTest({
  required AttestationChain chain,
  required List<Uint8List> pinnedRootHashes,
  required Uint8List expectedChallenge,
  required Uint8List expectedPkD,
  required Uint8List appAttestAuthData,
  required AttestationLevel level,
  bool verifySignatures = true,
  DateTime? now,
  bool checkValidity = false,
}) {
  final prev = _allowInsecureAppAttestGate;
  _allowInsecureAppAttestGate = true;
  try {
    return _verifyAppAttestChainPin(
      chain: chain,
      pinnedRootHashes: pinnedRootHashes,
      expectedChallenge: expectedChallenge,
      expectedPkD: expectedPkD,
      appAttestAuthData: appAttestAuthData,
      level: level,
      verifySignatures: verifySignatures,
      now: now,
      checkValidity: checkValidity,
    );
  } finally {
    _allowInsecureAppAttestGate = prev;
  }
}

ChainPinResult _verifyAppAttestChainPin({
  required AttestationChain chain,
  required List<Uint8List> pinnedRootHashes,
  required Uint8List expectedChallenge,
  required Uint8List expectedPkD,
  required Uint8List appAttestAuthData,
  required AttestationLevel level,
  required bool verifySignatures,
  DateTime? now,
  bool checkValidity = false,
}) {
  assert(
      verifySignatures || _allowInsecureAppAttestGate,
      'verifySignatures:false is test-only (use verifyAppAttestChainPinForTest).');
  // iOS tier is STD (Secure Enclave + App Attest standard assertion) —
  // FULL is Android-only on this branch, NONE never pins.
  if (level != AttestationLevel.standard) {
    return const ChainPinResult(
        ok: false,
        reason: 'attest-level-mismatch',
        flags: ['attest-level-mismatch']);
  }
  if (chain.isEmpty) {
    return const ChainPinResult(
        ok: false, reason: 'empty-chain', flags: ['attest-empty-chain']);
  }
  for (final c in chain.certsDer) {
    if (c.isEmpty) {
      return const ChainPinResult(
          ok: false, reason: 'empty-cert', flags: ['attest-empty-cert']);
    }
  }
  if (expectedPkD.length != 64 ||
      expectedChallenge.isEmpty ||
      appAttestAuthData.isEmpty) {
    return const ChainPinResult(
        ok: false,
        reason: 'challenge-mismatch',
        flags: ['attest-challenge-mismatch']);
  }
  // Nonce binding BEFORE signatures (mirrors the Android gate's format
  // gates): the Apple-signed leaf must commit to THIS SE key + challenge.
  late final Uint8List expectedNonce;
  try {
    final thumbprint = appAttestThumbprint(expectedPkD);
    final clientDataHash = appAttestClientDataHash(
        thumbprint: thumbprint, challenge: expectedChallenge);
    expectedNonce = appAttestExpectedNonce(
        authData: appAttestAuthData, clientDataHash: clientDataHash);
  } catch (_) {
    return const ChainPinResult(
        ok: false,
        reason: 'challenge-mismatch',
        flags: ['attest-challenge-mismatch']);
  }
  final leaf = chain.leaf!;
  final leafNonce = appAttestLeafNonce(leaf);
  if (leafNonce == null || !bytesEqual(leafNonce, expectedNonce)) {
    return const ChainPinResult(
        ok: false,
        reason: 'challenge-mismatch',
        flags: ['attest-challenge-mismatch']);
  }
  // M4 validate-then-trust: signatures BEFORE the pin is trusted.
  if (verifySignatures) {
    final sig = verifyChainSignaturesLeafFirst(
      chain.certsDer,
      now: now,
      checkValidity: checkValidity,
    );
    if (!sig.ok) {
      return ChainPinResult(
          ok: false, reason: sig.reason, flags: sig.flags);
    }
  }
  final root = chain.root!;
  final rootHash = ProxCrypto.sha256Sync(root);
  final pinned = pinnedRootHashes.any((h) => bytesEqual(h, rootHash));
  if (!pinned) {
    return const ChainPinResult(
        ok: false, reason: 'unknown-root', flags: ['attest-unknown-root']);
  }
  return const ChainPinResult(ok: true, reason: 'ok');
}

/// Assertion-path proof (same-install iOS re-enroll): verifies the
/// assertion signature under [credentialPubKey64] with the recomputed
/// clientDataHash' (live pkD + expected challenge over the assertion
/// authData). Returns a [ChainPinResult] (`ok` / `bad-assertion-shape` /
/// `bad-assertion-signature` / `challenge-mismatch`).
///
/// Trust note: the signature proves possession of the enrollment credential
/// key and binds the NEW SE key + challenge; the credential key's Apple
/// provenance was established at the first (object) enroll — a professor
/// that never saw it accepts the key TOFU (stability enforced like pkS
/// pins: a changed key mid-class flags). rpId/counter unchecked (residual,
// sie doc header).
ChainPinResult verifyAppAttestAssertionProof({
  required Uint8List assertionAuthData,
  required Uint8List assertionSignature,
  required Uint8List expectedChallenge,
  required Uint8List expectedPkD,
  required Uint8List credentialPubKey64,
}) {
  if (assertionAuthData.isEmpty ||
      assertionSignature.length != 64 ||
      credentialPubKey64.length != 64 ||
      expectedChallenge.isEmpty ||
      expectedPkD.length != 64) {
    return const ChainPinResult(
        ok: false,
        reason: 'bad-assertion-shape',
        flags: ['attest-bad-assertion-shape']);
  }
  late final Uint8List clientDataHash;
  try {
    clientDataHash = appAttestClientDataHash(
        thumbprint: appAttestThumbprint(expectedPkD),
        challenge: expectedChallenge);
  } catch (_) {
    return const ChainPinResult(
        ok: false,
        reason: 'challenge-mismatch',
        flags: ['attest-challenge-mismatch']);
  }
  final ok = verifyAppAttestAssertion(
    authData: assertionAuthData,
    signature64: assertionSignature,
    clientDataHash: clientDataHash,
    credentialPubKey64: credentialPubKey64,
  );
  if (!ok) {
    return const ChainPinResult(
        ok: false,
        reason: 'bad-assertion-signature',
        flags: ['attest-bad-assertion-signature']);
  }
  return const ChainPinResult(ok: true, reason: 'ok');
}
