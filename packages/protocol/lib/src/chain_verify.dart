// Offline X.509 chain-signature verification (security §2, pure Dart).
//
// Verifies each certificate's TBS signature with its issuer's SPKI, offline
// with no network (Spark-free: only `x509`/`asn1lib` parsing plus
// `pointycastle` crypto — no billing-gated backend, no CRL fetch).
//
// Scope: RSA (PKCS#1 v1.5 + SHA-256/384/512) and ECDSA P-256/P-384
// (SHA-256/384; P-521/SHA-512 accepted where present). Anything else
// (MD5/SHA-1, DSA, EdDSA, RSASSA-PSS) fails closed as unsupported — never
// a silent downgrade to pin-only.
//
// Chain shape: leaf-first, root-last (same as [AttestationChain]). For each
// i < n-1, cert[i] must be signed by cert[i+1]'s key AND its issuer DN must
// equal cert[i+1]'s subject DN; the root must be self-signed (issuer ==
// subject, signature verifies with its own key). Root trust itself (hash
// pin) stays in `verifyAttestationChainPin` as a pre-gate — this file only
// proves the chain is internally consistent and rooted at the pinned key.
//
// Fail-closed: every parse/crypto failure returns ok:false (never throws).
// TBS bytes are the exact original DER (`encodedBytes` from the parser),
// never re-encoded, so signatures verify against the bytes that were
// actually signed.
library;

import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart';
import 'package:x509/x509.dart' as x509;

/// Signature-verification verdict (pure, offline).
class ChainSigResult {
  final bool ok;
  final String reason;
  final List<String> flags;
  const ChainSigResult(
      {required this.ok, required this.reason, this.flags = const []});
}

// -- OID tables (dotted) --------------------------------------------------

/// Signature-algorithm OIDs we verify (digest in parentheses).
const _sigRsa256 = '1.2.840.113549.1.1.11'; // sha256WithRSAEncryption
const _sigRsa384 = '1.2.840.113549.1.1.12'; // sha384WithRSAEncryption
const _sigRsa512 = '1.2.840.113549.1.1.13'; // sha512WithRSAEncryption
const _sigEcdsa256 = '1.2.840.10045.4.3.2'; // ecdsa-with-SHA256
const _sigEcdsa384 = '1.2.840.10045.4.3.3'; // ecdsa-with-SHA384
const _sigEcdsa512 = '1.2.840.10045.4.3.4'; // ecdsa-with-SHA512

/// SPKI algorithm OIDs.
const _spkiRsa = '1.2.840.113549.1.1.1'; // rsaEncryption
const _spkiEc = '1.2.840.10045.2.1'; // ecPublicKey

/// Named-curve OIDs (issuer keys we accept).
const _curveP256 = '1.2.840.10045.3.1.7'; // prime256v1
const _curveP384 = '1.3.132.0.34'; // secp384r1
const _curveP521 = '1.3.132.0.35'; // secp521r1

// -- Parsed form ----------------------------------------------------------

class _ParsedCert {
  /// Exact DER of the TBS (what was signed).
  final Uint8List tbsDer;

  /// Signature-algorithm OID (dotted) from the outer Certificate SEQ.
  /// Must equal the inner TBS `signature' OID (M4 alg-confusion gate).
  final String sigAlgOid;

  /// Raw signature bytes (BIT STRING content: RSA block or DER SEQ{r,s}).
  final Uint8List sigBytes;

  /// Raw DER of the TBS issuer and subject fields (for DN chaining).
  final Uint8List issuerDer;
  final Uint8List subjectDer;

  /// Parsed SPKI (subject public key of THIS cert — the issuer of its child).
  final _Spki spki;

  _ParsedCert({
    required this.tbsDer,
    required this.sigAlgOid,
    required this.sigBytes,
    required this.issuerDer,
    required this.subjectDer,
    required this.spki,
  });
}

class _Spki {
  final String algOid;
  final String? curveOid;
  final BigInt? rsaModulus;
  final BigInt? rsaExponent;
  final BigInt? ecX;
  final BigInt? ecY;
  const _Spki.rsa(this.rsaModulus, this.rsaExponent)
      : algOid = _spkiRsa,
        curveOid = null,
        ecX = null,
        ecY = null;
  const _Spki.ec(this.curveOid, this.ecX, this.ecY)
      : algOid = _spkiEc,
        rsaModulus = null,
        rsaExponent = null;
}

// -- Entry point ----------------------------------------------------------

/// Verifies the internal signatures of a leaf-first DER chain.
///
/// Checks, in order (fail-closed, first failure wins):
/// 1. every entry parses as a DER X.509 Certificate (else `bad-chain-der`);
/// 2. every signature algorithm is supported (else `unsupported-sigalg`);
/// 3. every issuer key parses as RSA/EC P-256/P-384(/P-521)
///    (else `unsupported-key`);
/// 4. child issuer DN == parent subject DN (else `issuer-mismatch`);
/// 5. child TBS signature verifies with the parent SPKI
///    (else `bad-chain-signature`);
/// 6. root is self-issued and self-signed (else `bad-root-signature`).
///
/// Does NOT check trust (pin), revocation, or key usage — the caller
/// ([verifyAttestationChainPin]) gates those. Validity dates are opt-in:
/// pass [checkValidity] with [now] to fail `expired-cert` outside
/// notBefore/notAfter (structure-only UTCTime/GeneralizedTime compare, no
/// content interpretation). Default off: attestation chains carry
/// far-future test validity (e.g. 2070+) and offline professor clocks skew;
/// expiry is otherwise enforced at the [AttestationWindow] tier, not here.
/// After the legacy-test-root sunset (2016 root expired 2026-05-24),
/// production callers SHOULD pass `checkValidity: true`; test fixtures
/// covering expired roots pass [allowExpiredTestRoots] instead (never in
/// production — it skips the date gate only, never signatures).
ChainSigResult verifyChainSignaturesLeafFirst(
  List<Uint8List> certsDer, {
  DateTime? now,
  bool checkValidity = false,
  bool allowExpiredTestRoots = false,
}) {
  if (certsDer.isEmpty) {
    return const ChainSigResult(
        ok: false, reason: 'bad-chain-der', flags: ['attest-bad-der']);
  }
  for (final c in certsDer) {
    if (c.isEmpty) {
      return const ChainSigResult(
          ok: false, reason: 'bad-chain-der', flags: ['attest-bad-der']);
    }
  }
  final parsed = <_ParsedCert>[];
  for (var i = 0; i < certsDer.length; i++) {
    try {
      parsed.add(_parseCert(certsDer[i]));
    } on _UnsupportedSigAlg {
      return ChainSigResult(
          ok: false,
          reason: 'unsupported-sigalg',
          flags: ['attest-unsupported-sigalg', 'attest-cert-$i']);
    } on _UnsupportedKey {
      return ChainSigResult(
          ok: false,
          reason: 'unsupported-key',
          flags: ['attest-unsupported-key', 'attest-cert-$i']);
    } catch (_) {
      return ChainSigResult(
          ok: false,
          reason: 'bad-chain-der',
          flags: ['attest-bad-der', 'attest-cert-$i']);
    }
  }
  // Touch the x509 package (parse each cert once) so the declared
  // dependency stays load-bearing: it cross-validates the asn1lib parse
  // above and fails closed on any structural disagreement. Validity
  // windows are captured here (structure-only dates, no content
  // interpretation) for the opt-in [checkValidity] gate below.
  final notBefore = <DateTime?>[];
  final notAfter = <DateTime?>[];
  for (var i = 0; i < certsDer.length; i++) {
    try {
      final seq = ASN1Parser(certsDer[i]).nextObject() as ASN1Sequence;
      final cert = x509.X509Certificate.fromAsn1(seq);
      DateTime? nb;
      DateTime? na;
      try {
        nb = cert.tbsCertificate.validity?.notBefore;
        na = cert.tbsCertificate.validity?.notAfter;
        // ignore: avoid_catches_without_on_clauses
      } catch (_) {}
      notBefore.add(nb);
      notAfter.add(na);
    } catch (_) {
      return ChainSigResult(
          ok: false,
          reason: 'bad-chain-der',
          flags: ['attest-bad-der', 'attest-cert-$i']);
    }
  }
  if (checkValidity && !allowExpiredTestRoots) {
    final at = (now ?? DateTime.now()).toUtc();
    for (var i = 0; i < certsDer.length; i++) {
      final nb = notBefore[i];
      final na = notAfter[i];
      // Missing/unparseable dates fail closed only when the gate is on.
      if (nb == null || na == null) {
        return ChainSigResult(
            ok: false,
            reason: 'expired-cert',
            flags: ['attest-expired', 'attest-cert-$i']);
      }
      if (at.isBefore(nb.toUtc()) || at.isAfter(na.toUtc())) {
        return ChainSigResult(
            ok: false,
            reason: 'expired-cert',
            flags: ['attest-expired', 'attest-cert-$i']);
      }
    }
  }
  for (var i = 0; i < parsed.length - 1; i++) {
    final child = parsed[i];
    final parent = parsed[i + 1];
    if (!_derEqual(child.issuerDer, parent.subjectDer)) {
      return ChainSigResult(
          ok: false,
          reason: 'issuer-mismatch',
          flags: ['attest-issuer-mismatch', 'attest-cert-$i']);
    }
    if (!_verifyWithKey(
        tbsDer: child.tbsDer,
        sigAlgOid: child.sigAlgOid,
        sigBytes: child.sigBytes,
        issuerKey: parent.spki)) {
      return ChainSigResult(
          ok: false,
          reason: 'bad-chain-signature',
          flags: ['attest-bad-signature', 'attest-cert-$i']);
    }
  }
  final root = parsed.last;
  if (!_derEqual(root.issuerDer, root.subjectDer)) {
    return const ChainSigResult(
        ok: false,
        reason: 'bad-root-signature',
        flags: ['attest-bad-root', 'attest-root-not-self-issued']);
  }
  if (!_verifyWithKey(
      tbsDer: root.tbsDer,
      sigAlgOid: root.sigAlgOid,
      sigBytes: root.sigBytes,
      issuerKey: root.spki)) {
    return const ChainSigResult(
        ok: false,
        reason: 'bad-root-signature',
        flags: ['attest-bad-root']);
  }
  return const ChainSigResult(ok: true, reason: 'ok');
}

// -- Leaf SPKI extraction (C2: pkD bind, structure-only) -------------------

/// Extracts the leaf's raw EC public key (x||y, 64B for P-256) without
/// decrypting or interpreting attestation content.
///
/// Structure-only parse of the leaf SPKI (lengths + OIDs + uncompressed
/// point shape): returns null for non-EC leaves, compressed points, or
/// malformed DER — callers fail closed. Never decrypts sealed bytes.
Uint8List? extractLeafEcPublicKeyRaw(Uint8List leafDer) {
  try {
    final parsed = _parseCert(leafDer);
    final spki = parsed.spki;
    if (spki.algOid != _spkiEc) return null;
    if (spki.ecX == null || spki.ecY == null) return null;
    // P-256 only for the pkD bind (P-384/P-521 leaves return null and the
    // caller fails closed as mismatch — no silent truncation).
    if (spki.curveOid != _curveP256) return null;
    Uint8List be(BigInt v, int len) {
      final hex = v.toRadixString(16).padLeft(len * 2, '0');
      if (hex.length != len * 2) return Uint8List(0);
      final out = Uint8List(len);
      for (var i = 0; i < len; i++) {
        out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return out;
    }

    final x = be(spki.ecX!, 32);
    final y = be(spki.ecY!, 32);
    if (x.length != 32 || y.length != 32) return null;
    return Uint8List.fromList([...x, ...y]);
  } catch (_) {
    return null;
  }
}

/// Constant-time equality of the leaf EC SPKI against an expected pkD.
///
/// [expectedPkD] is the 64B raw x||y P-256 device key. Returns false on
/// length mismatch, non-EC leaves, or parse failure — never throws.
bool leafPkDEquals(Uint8List leafDer, Uint8List expectedPkD) {
  if (expectedPkD.length != 64) return false;
  final raw = extractLeafEcPublicKeyRaw(leafDer);
  if (raw == null || raw.length != expectedPkD.length) return false;
  var acc = 0;
  for (var i = 0; i < raw.length; i++) {
    acc |= raw[i] ^ expectedPkD[i];
  }
  return acc == 0;
}

// -- Parsing --------------------------------------------------------------

class _UnsupportedSigAlg implements Exception {}

class _UnsupportedKey implements Exception {}

String _oidOf(ASN1ObjectIdentifier o) => o.oi.join('.');

_ParsedCert _parseCert(Uint8List der) {
  final top = ASN1Parser(der).nextObject();
  if (top is! ASN1Sequence || top.elements.length != 3) {
    throw const FormatException('not a DER Certificate');
  }
  final tbsSeq = top.elements[0];
  if (tbsSeq is! ASN1Sequence) throw const FormatException('bad TBS');
  final sigAlgSeq = top.elements[1];
  if (sigAlgSeq is! ASN1Sequence || sigAlgSeq.elements.isEmpty) {
    throw const FormatException('bad signatureAlgorithm');
  }
  final sigAlgOidObj = sigAlgSeq.elements[0];
  if (sigAlgOidObj is! ASN1ObjectIdentifier) {
    throw const FormatException('bad sig alg OID');
  }
  final sigAlgOid = _oidOf(sigAlgOidObj);
  if (sigAlgOid != _sigRsa256 &&
      sigAlgOid != _sigRsa384 &&
      sigAlgOid != _sigRsa512 &&
      sigAlgOid != _sigEcdsa256 &&
      sigAlgOid != _sigEcdsa384 &&
      sigAlgOid != _sigEcdsa512) {
    throw _UnsupportedSigAlg();
  }
  final sigValue = top.elements[2];
  if (sigValue is! ASN1BitString) throw const FormatException('bad sig');
  final sigBytes = Uint8List.fromList(sigValue.contentBytes());
  if (sigBytes.isEmpty) throw const FormatException('empty sig');

  final tbs = tbsSeq.elements;
  // TBS ::= SEQ { [0] version EXPLICIT OPTIONAL, serial, signature,
  //   issuer, validity, subject, spki, ... }
  final hasVersion = tbs.isNotEmpty && tbs.first.tag == 0xa0;
  final base = hasVersion ? 1 : 0;
  // Need at least serial..spki (6 fields after optional version).
  if (tbs.length < base + 6) throw const FormatException('short TBS');
  // M4 alg-confusion gate: the inner TBS `signature' alg MUST equal the
  // outer Certificate `signatureAlgorithm' (structure-only OID compare).
  // A mismatch means the TBS was signed under different parameters than
  // the outer claims — fail closed as malformed, never verify.
  final innerSigObj = tbs[base + 1];
  if (innerSigObj is! ASN1Sequence || innerSigObj.elements.isEmpty) {
    throw const FormatException('bad TBS signature alg');
  }
  final innerSigOidObj = innerSigObj.elements[0];
  if (innerSigOidObj is! ASN1ObjectIdentifier) {
    throw const FormatException('bad TBS sig alg OID');
  }
  if (_oidOf(innerSigOidObj) != sigAlgOid) {
    throw const FormatException('TBS/outer signatureAlgorithm mismatch');
  }
  final issuerObj = tbs[base + 2];
  final subjectObj = tbs[base + 4];
  final spkiObj = tbs[base + 5];
  if (spkiObj is! ASN1Sequence) throw const FormatException('bad SPKI');
  return _ParsedCert(
    tbsDer: Uint8List.fromList(tbsSeq.encodedBytes),
    sigAlgOid: sigAlgOid,
    sigBytes: sigBytes,
    issuerDer: Uint8List.fromList(issuerObj.encodedBytes),
    subjectDer: Uint8List.fromList(subjectObj.encodedBytes),
    spki: _parseSpki(spkiObj),
  );
}

_Spki _parseSpki(ASN1Sequence spki) {
  if (spki.elements.length != 2) throw const FormatException('bad SPKI len');
  final algSeq = spki.elements[0];
  if (algSeq is! ASN1Sequence || algSeq.elements.isEmpty) {
    throw const FormatException('bad SPKI alg');
  }
  final algOidObj = algSeq.elements[0];
  if (algOidObj is! ASN1ObjectIdentifier) {
    throw const FormatException('bad SPKI alg OID');
  }
  final algOid = _oidOf(algOidObj);
  final keyBits = spki.elements[1];
  if (keyBits is! ASN1BitString) throw const FormatException('bad SPKI key');
  final keyBytes = Uint8List.fromList(keyBits.contentBytes());
  if (keyBytes.isEmpty) throw const FormatException('empty SPKI key');

  if (algOid == _spkiRsa) {
    final rsaSeq = ASN1Parser(keyBytes).nextObject();
    if (rsaSeq is! ASN1Sequence || rsaSeq.elements.length != 2) {
      throw const FormatException('bad RSA SPKI');
    }
    final n = (rsaSeq.elements[0] as ASN1Integer).valueAsBigInteger;
    final e = (rsaSeq.elements[1] as ASN1Integer).valueAsBigInteger;
    if (n == BigInt.zero || e == BigInt.zero) {
      throw const FormatException('bad RSA params');
    }
    return _Spki.rsa(n, e);
  }
  if (algOid == _spkiEc) {
    if (algSeq.elements.length < 2) throw _UnsupportedKey();
    final curveObj = algSeq.elements[1];
    if (curveObj is! ASN1ObjectIdentifier) throw _UnsupportedKey();
    final curveOid = _oidOf(curveObj);
    if (curveOid != _curveP256 &&
        curveOid != _curveP384 &&
        curveOid != _curveP521) {
      throw _UnsupportedKey();
    }
    // Uncompressed ECPoint 0x04 || X || Y.
    if (keyBytes.isEmpty || keyBytes[0] != 0x04) throw _UnsupportedKey();
    final coordLen = (keyBytes.length - 1) ~/ 2;
    if (1 + coordLen * 2 != keyBytes.length || coordLen == 0) {
      throw const FormatException('bad EC point');
    }
    final x = _beToBigInt(keyBytes.sublist(1, 1 + coordLen));
    final y = _beToBigInt(keyBytes.sublist(1 + coordLen));
    return _Spki.ec(curveOid, x, y);
  }
  throw _UnsupportedKey();
}

bool _derEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var acc = 0;
  for (var i = 0; i < a.length; i++) {
    acc |= a[i] ^ b[i];
  }
  return acc == 0;
}

BigInt _beToBigInt(List<int> bytes) {
  var acc = BigInt.zero;
  for (final b in bytes) {
    acc = (acc << 8) | BigInt.from(b & 0xFF);
  }
  return acc;
}

// -- Verification ---------------------------------------------------------

bool _verifyWithKey({
  required Uint8List tbsDer,
  required String sigAlgOid,
  required Uint8List sigBytes,
  required _Spki issuerKey,
}) {
  try {
    if (sigAlgOid == _sigRsa256 ||
        sigAlgOid == _sigRsa384 ||
        sigAlgOid == _sigRsa512) {
      if (issuerKey.algOid != _spkiRsa) return false;
      final Digest digest;
      final String digestHex;
      switch (sigAlgOid) {
        case _sigRsa256:
          digest = SHA256Digest();
          digestHex = '0609608648016503040201';
        case _sigRsa384:
          digest = SHA384Digest();
          digestHex = '0609608648016503040202';
        default:
          digest = SHA512Digest();
          digestHex = '0609608648016503040203';
      }
      final signer = RSASigner(digest, digestHex);
      signer.init(
          false,
          PublicKeyParameter<RSAPublicKey>(RSAPublicKey(
              issuerKey.rsaModulus!, issuerKey.rsaExponent!)));
      return signer.verifySignature(tbsDer, RSASignature(sigBytes));
    }
    if (sigAlgOid == _sigEcdsa256 ||
        sigAlgOid == _sigEcdsa384 ||
        sigAlgOid == _sigEcdsa512) {
      if (issuerKey.algOid != _spkiEc) return false;
      final String domainName;
      switch (issuerKey.curveOid) {
        case _curveP256:
          domainName = 'prime256v1';
        case _curveP384:
          domainName = 'secp384r1';
        case _curveP521:
          domainName = 'secp521r1';
        default:
          return false;
      }
      final Digest digest;
      switch (sigAlgOid) {
        case _sigEcdsa256:
          digest = SHA256Digest();
        case _sigEcdsa384:
          digest = SHA384Digest();
        default:
          digest = SHA512Digest();
      }
      final seq = ASN1Parser(sigBytes).nextObject();
      if (seq is! ASN1Sequence || seq.elements.length != 2) return false;
      final r = (seq.elements[0] as ASN1Integer).valueAsBigInteger;
      final s = (seq.elements[1] as ASN1Integer).valueAsBigInteger;
      if (r <= BigInt.zero || s <= BigInt.zero) return false;
      final domain = ECDomainParameters(domainName);
      final q = domain.curve.createPoint(issuerKey.ecX!, issuerKey.ecY!);
      final verifier = ECDSASigner(digest);
      verifier.init(false, PublicKeyParameter(ECPublicKey(q, domain)));
      return verifier.verifySignature(tbsDer, ECSignature(r, s));
    }
    return false;
  } catch (_) {
    return false;
  }
}
