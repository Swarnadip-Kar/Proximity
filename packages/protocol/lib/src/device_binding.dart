// anomaly flags. Pure Dart — no platform code.
//
// Model:
//   DKey P-256 (StrongBox→TEE / Secure Enclave once the keystore track
//     lands; software/fake `none` until then) with SKey Ed25519 sealed
//     to it (AES-GCM on HW, ciphertext only at rest). Extended claim
//     {pkS,pkD,installId,attestationLevel,self-asserted,attestedAt,
//     attestedUntil=+90d};
//   /prove adds pkD + dSig=Sign(DKey,session||window||j||C_j||
//     faceTicketHash||pkS) with Sig_s also binding pkD+ticketHash;
//   the professor verifies the fresh signature offline (dSig + Sig_s +
//     ticket + existing checks) and tiers on the CLAIMED level.
//
// Tiers (pure `evaluateDeviceProof` verdict):
//   FULL/STD → confirmed,
//   STALE (14d grace past attestedUntil) → confirmed+banner,
//   NONE → device-unproven (no tier claimed).
// Live-marking note: `verifyProve` (crypto/verify.dart) applies a graceful
// NONE fallback until HW keys ship — a bound-NONE proof still runs every
// ticket/Sig_s/face/sighting check and confirms with a
// `device-none-fallback` flag instead of verdicting device-unproven, so
// genuine software-key students mark normally. The pure tier above is
// unchanged (NONE still never *tiers*); only the live verify path falls
// back, loudly.
// Heartbeat rolls attestedUntil; old-DKey-signed MoveIntent = instant move
// else 30-day cooldown kept; backup-restore clone fails unwrap → 'restore
// detected — re-enroll'; double-pkD audit flag on sync.
//
// P-256 verification itself lives in the platform adapter (app layer):
// this file holds the pure tier/anomaly decisions beside
// evaluateStudentClaim (claim.dart forwards here), plus the canonical
// attestation-challenge helper and the offline chain-pinning types
// (security §2, sec-protocol 1A). Trust caveat, stated plainly: the
// [level] below is SELF-ASSERTED by the presenting device — full X.509
// chain verification runs HERE offline (pure-Dart `chain_verify.dart`:
// TBS signatures vs issuer SPKI, RSA + ECDSA P-256/P-384, root
// self-signed + hash-pinned) against pins provisioned here; no
// billing-gated backend carries one, so FULL/STD mean "claims hardware
// backing", verified as a fresh signature over the live challenge plus
// the offline chain checks below, never as server provenance.
// See PROXIMITY_DESIGN.md §3.4.
//
// Security §4 liveness: the face ticket bound into Sig_s/dSig now carries
// (livenessScore, livenessVer) — see crypto/primitives.dart faceTicketHash
// and crypto/verify.dart liveness gates. This file does NOT gate liveness;
// it owns the device side (chain/level/window + dSig tier).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'bytes.dart';
import 'chain_verify.dart';
import 'constants.dart';
import 'crypto/primitives.dart';

/// HW attestation level of the DKey that signed a proof.
enum AttestationLevel {
  /// Hardware-backed with full chain (StrongBox / Secure Enclave).
  full,

  /// Hardware-backed standard (TEE without StrongBox, or App Attest
  /// standard assertion).
  standard,

  /// No attestation (desktop/web stub, software fallback, or missing
  /// chain). Never confirms — manual path only.
  none,
}

/// Parses the wire string ('FULL'/'STD'/'NONE', case-insensitive).
AttestationLevel attestationLevelOf(String s) {
  switch (s.trim().toUpperCase()) {
    case 'FULL':
      return AttestationLevel.full;
    case 'STD':
    case 'STANDARD':
      return AttestationLevel.standard;
    default:
      return AttestationLevel.none;
  }
}

String attestationLevelName(AttestationLevel l) => switch (l) {
      AttestationLevel.full => 'FULL',
      AttestationLevel.standard => 'STD',
      AttestationLevel.none => 'NONE',
    };

/// Device-proof tier verdict (pure).
enum DeviceTier {
  /// FULL/STD and fresh: confirms.
  fresh,

  /// FULL/STD but past attestedUntil within the 14d grace: confirms with
  /// a banner (heartbeat should have rolled it; flag for re-attest).
  stale,

  /// NONE, expired past grace, or dSig invalid: device-unproven.
  unproven,
}

/// Pure device-proof evaluation, beside evaluateStudentClaim.
///
/// [dSigValid] is the platform P-256 verify of dSig over
/// [ProxCrypto.deviceProvePreimage] (already computed by the caller —
/// protocol stays pure Dart with no P-256 dependency).
/// [doublePkD] marks the sync-time audit flag (same pkD seen on two
/// installIds) — it does NOT change the tier here, it is surfaced in
/// [DeviceProofResult.auditFlags] for post-hoc review.
DeviceProofResult evaluateDeviceProof({
  required AttestationLevel level,
  required DateTime attestedAt,
  required DateTime attestedUntil,
  required bool dSigValid,
  required DateTime now,
  bool doublePkD = false,
}) {
  final n = now.toUtc();
  final flags = <String>[];
  if (doublePkD) flags.add('audit-double-pkD');
  if (level == AttestationLevel.none) {
    return DeviceProofResult(
        tier: DeviceTier.unproven,
        reason: 'device-unproven',
        auditFlags: flags);
  }
  if (!dSigValid) {
    return DeviceProofResult(
        tier: DeviceTier.unproven,
        reason: 'device-unproven',
        auditFlags: flags);
  }
  if (!n.isAfter(attestedUntil)) {
    return DeviceProofResult(
        tier: DeviceTier.fresh, reason: 'ok', auditFlags: flags);
  }
  final overdue = n.difference(attestedUntil.toUtc());
  if (overdue <= kDeviceStaleGrace) {
    return DeviceProofResult(
        tier: DeviceTier.stale,
        reason: 'ok-stale-device',
        auditFlags: [...flags, 'device-stale']);
  }
  return DeviceProofResult(
      tier: DeviceTier.unproven,
      reason: 'device-unproven',
      auditFlags: [...flags, 'device-expired']);
}

class DeviceProofResult {
  final DeviceTier tier;
  final String reason;
  final List<String> auditFlags;
  const DeviceProofResult(
      {required this.tier, required this.reason, this.auditFlags = const []});

  /// confirmed for fresh + stale (stale carries the banner flag);
  /// unproven never confirms.
  bool get confirms =>
      tier == DeviceTier.fresh || tier == DeviceTier.stale;
}

// ------------------------------------------------- attestation types ---

/// Offline attestation chain (security §2, §7).
///
/// Wire form is `attestationChain (list<string> DER hex)` on
/// `studentDevices/{email}` — leaf-first, root-last, each entry DER-hex of
/// one X.509 cert. This class is the pure-Dart in-memory form: no platform
/// code, no IMEI. Full X.509 chain-signature verification
/// ([verifyChainSignaturesLeafFirst], in `chain_verify.dart` — offline,
/// pure-Dart via `x509`/`asn1lib` parse + `pointycastle` RSA/ECDSA, no
/// network) runs inside [verifyAttestationChainPin] after the pin
/// pre-gates; the pure pin checks below run offline on the professor
/// phone against pinned roots provisioned at setup time.
class AttestationChain {
  /// Raw DER bytes per cert, leaf-first.
  final List<Uint8List> certsDer;

  const AttestationChain([this.certsDer = const []]);

  /// Parses the Firestore wire form (list of DER-hex strings). Throws
  /// [FormatException] on non-hex input (strict — never silent empty).
  factory AttestationChain.fromHexList(List<String> hexList) =>
      AttestationChain(
          hexList.map((h) => hexDecode(h)).toList(growable: false));

  /// Serializes back to the Firestore wire form.
  List<String> toHexList() =>
      certsDer.map((c) => hexEncode(c)).toList(growable: false);

  bool get isEmpty => certsDer.isEmpty;
  bool get isNotEmpty => certsDer.isNotEmpty;
  int get length => certsDer.length;

  /// Leaf (presenting device cert) or null when empty.
  Uint8List? get leaf => certsDer.isEmpty ? null : certsDer.first;

  /// Root (last cert) or null when empty.
  Uint8List? get root => certsDer.isEmpty ? null : certsDer.last;
}

/// Attestation validity window (security §2: +90d, 14d stale grace).
///
/// Pure value type beside [evaluateDeviceProof]: the tier function keeps
/// taking raw DateTimes (unchanged semantics — see below), this type is
/// the canonical carrier for claim/sync layers (owned by sec-sync) so
/// window math has one home.
class AttestationWindow {
  final DateTime attestedAt;
  final DateTime attestedUntil;

  const AttestationWindow(
      {required this.attestedAt, required this.attestedUntil});

  /// Fresh: now <= attestedUntil.
  bool contains(DateTime now) => !now.toUtc().isAfter(attestedUntil.toUtc());

  /// Stale: past attestedUntil but within [kDeviceStaleGrace].
  bool isStale(DateTime now) {
    final n = now.toUtc();
    if (!n.isAfter(attestedUntil.toUtc())) return false;
    return n.difference(attestedUntil.toUtc()) <= kDeviceStaleGrace;
  }

  /// Expired: past attestedUntil + grace.
  bool isExpired(DateTime now) => !contains(now) && !isStale(now);
}

/// Android Key Attestation extension OID for the attestation record
/// (security §2: professor verifies offline vs pinned Google roots).
/// OID 1.3.6.1.4.1.11129.2.1.17.
const String kKeyAttestationOid = '1.3.6.1.4.1.11129.2.1.17';

/// DER TLV encoding of [kKeyAttestationOid]:
/// 06 0A 2B 06 01 04 01 D6 79 02 01 11 (tag 06, length 10: the OID has 10
/// content bytes — 2B + 8 arcs with 11129 taking two base-128 bytes D6 79).
/// Pure-byte needle for [attestationLeafHasKeyOid] — no ASN.1 parser needed.
///
/// Provenance (audit 2026-09-13): byte-verified against a genuine
/// Google-signed leaf (`android/keyattestation` testdata
/// `blueline/sdk28/TEE_EC_NONE.pem`), whose extension carries
/// `... 30 82 01 2D 06 0A 2B 06 01 04 01 D6 79 02 01 11 ...`. The previous
/// `06 09` needle never matched a real cert (every genuine chain failed
/// `missing-attestation-oid`); fixed to `06 0A`.
const List<int> kKeyAttestationOidDer = [
  0x06,
  0x0A,
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

/// True when [leafDer] contains the Key Attestation OID TLV.
///
/// Minimal pure-Dart format check: the leaf of a genuine Android key
/// attestation cert carries extension 1.3.6.1.4.1.11129.2.1.17. Absence
/// means "not an attestation cert" (fail closed). Chain-signature math
/// runs after this gate (see [verifyAttestationChainPin]) — this only
/// gates format first so malformed leaves fail fast.
bool attestationLeafHasKeyOid(Uint8List leafDer) {
  final needle = kKeyAttestationOidDer;
  if (leafDer.length < needle.length) return false;
  outer:
  for (var i = 0; i <= leafDer.length - needle.length; i++) {
    for (var k = 0; k < needle.length; k++) {
      if (leafDer[i + k] != needle[k]) continue outer;
    }
    return true;
  }
  return false;
}

/// True when [leafDer] contains [challenge] as a contiguous byte run.
///
/// The enrollment challenge (see [deviceBindingChallenge]) is embedded in
/// the attestation record by the OS; the offline professor check requires
/// an exact match. Pure-byte containment — no parsing, no platform code.
bool attestationLeafContainsChallenge(
    Uint8List leafDer, Uint8List challenge) {
  if (challenge.isEmpty || leafDer.length < challenge.length) return false;
  outer:
  for (var i = 0; i <= leafDer.length - challenge.length; i++) {
    for (var k = 0; k < challenge.length; k++) {
      if (leafDer[i + k] != challenge[k]) continue outer;
    }
    return true;
  }
  return false;
}

/// Offline chain-pinning verdict (pure).
class ChainPinResult {
  final bool ok;
  final String reason;
  final List<String> flags;
  const ChainPinResult(
      {required this.ok, required this.reason, this.flags = const []});
}

/// Pinned Google Hardware Attestation Root CAs (security §2: the professor
/// verifies the chain offline against these pins — no network, no backend).
///
/// SHA-256 over the root CERTIFICATE DER (the exact bytes
/// [verifyAttestationChainPin] hashes). Public trust anchors, not secrets —
/// published at
/// https://developer.android.com/privacy-and-security/security-key-attestation#root_certificate
/// and mirrored with test vectors at
/// https://github.com/android/keyattestation/blob/main/roots.json
/// (audit 2026-09-13: both pins below re-hashed from that file's PEMs —
/// `SHA256(DER)` — with openssl cross-check of serials/validity):
/// - RSA root, serial f92009e853b6b045, 2022-03-20 → 2042-03-15.
/// - EC root, CN "Key Attestation CA1", serial 84A9D0297B0EB58AE7FF0E80DE76,
///   2025-07-17 → 2035-07-15; starts signing device chains 2026-02-01.
/// Legacy roots (2016/2019/2021) are deliberately omitted: the 2016 root
/// expired May 2026 and pre-2021 devices chaining to it fail closed as
/// `unknown-root` (manual path) rather than silently trusting an expired
/// anchor. iOS App Attest chains pin Apple roots instead — callers pass
/// their own [pinnedRootHashes]; these defaults are the Android set.
const String kGoogleHwAttestationRootRsaSha256Hex =
    'cedb1cb6dc896ae5ec797348bce9286753c2b38ee71ce0fbe34a9a1248800dfc';
const String kGoogleHwAttestationRootEcSha256Hex =
    '6d9db4ce6c5c0b293166d08986e05774a8776ceb525d9e4329520de12ba4bcc0';

/// Default pinned roots for Android key-attestation chains (see above).
/// Returns fresh copies (callers must not mutate the pins).
List<Uint8List> defaultPinnedAttestationRoots() => [
      hexDecode(kGoogleHwAttestationRootRsaSha256Hex),
      hexDecode(kGoogleHwAttestationRootEcSha256Hex),
    ];

/// Offline chain-vs-pinned-roots check (security §2-last-para, pure half).
///
/// Checks, in order (fail-closed, first failure wins):
/// 1. [level] >= TEE (FULL/STD only — NONE never pins);
/// 2. [chain] non-empty, every cert non-empty;
/// 3. leaf carries the Key Attestation OID ([kKeyAttestationOid]) —
///    else `missing-attestation-oid` (always required in production;
///    pin-pre-gate units with synthetic leaves run through
///    [verifyAttestationChainPinForTest] — see iOS note below);
/// 4. leaf embeds [expectedChallenge] (see [deviceBindingChallengeV2])
///    — else `challenge-mismatch`;
/// 5. full X.509 chain signatures verify offline, BEFORE the pin is
///    trusted (M4 validate-then-trust: each TBS signed by the issuer SPKI,
///    RSA + ECDSA P-256/P-384, root self-signed, TBS outer alg == inner —
///    see `chain_verify.dart`) — else `bad-chain-signature` /
///    `bad-root-signature` / `bad-chain-der` / `unsupported-sigalg` /
///    `unsupported-key` / `issuer-mismatch` / `expired-cert` (opt-in).
///    Never skipped in production (no downgrade flags — pin-pre-gate
///    units run through [verifyAttestationChainPinForTest]).
/// 6. SHA256(root DER) ∈ [pinnedRootHashes] (Google roots provisioned at
///    setup) — else `unknown-root`. Runs AFTER signature validation so an
///    unvalidated chain is never trusted by pin alone.
/// 7. optional leaf-pkD bind: when [expectedLeafPkD] is non-null, the
///    leaf EC SPKI (structure-only via `extractLeafEcPublicKeyRaw`, no
///    decryption) must equal it — else `leaf-pkd-mismatch`. This is the
///    pkD bind: the enrollment challenge binds email+installId+
///    pkS (the SKey), NOT pkD — pkD enters trust only through this leaf
///    check plus the fresh dSig over the prove preimage.
///
/// [pinnedRootHashes] are raw 32-byte SHA-256 digests of trusted root DERs
/// (TOFU→pin-check: first online fetch pins, offline verifies against the
/// pin).
///
/// Platform split (audit 2026-09-13): this gate is the ANDROID half —
/// the OID/challenge/pin checks above are Android-key-attestation-shaped.
/// iOS has no offline X.509 attestation chain to pin: App Attest
/// attestation needs Apple servers (online, once per key) and DeviceCheck
/// needs Apple server calls, so with no custom backend the iOS path is
/// Firebase App Check (Spark-compatible: App Attest provider on iOS 14+,
/// DeviceCheck fallback, console enforcement on Firestore — owned by
/// sec-integrity), while per-request App Attest assertions verify offline
/// against the stored key with a strictly-increasing counter. iOS callers
/// carrying a raw X.509 chain pass their pinned Apple root; App Attest
/// objects (CBOR/authenticator-data, never the Android OID) are
/// out-of-scope for this Android-shaped gate.
///
/// X.509 signature math runs HERE (offline, pure-Dart — see
/// `chain_verify.dart`), not in the platform adapter: this is the full
/// format+pin+challenge+signature gate the professor runs offline before
/// [evaluateDeviceProof] tiers the proof. Revocation
/// (Google's CRL at android.googleapis.com/attestation/status) needs
/// network and is therefore an online-setup-time check only — the offline
/// professor gate cannot consult it (residual risk, see doc §7).
/// Test-only entry point for pin/challenge pre-gate units with synthetic
/// leaves (not X.509): exposes the [requireKeyOid]/[verifySignatures]
/// downgrades the production gate deliberately lacks. Never used outside
/// tests — production [verifyAttestationChainPin] always verifies
/// signatures and always requires the attestation OID.
bool _allowInsecurePinGate = false;

@visibleForTesting
ChainPinResult verifyAttestationChainPinForTest({
  required AttestationChain chain,
  required List<Uint8List> pinnedRootHashes,
  required Uint8List expectedChallenge,
  required AttestationLevel level,
  bool requireKeyOid = true,
  bool verifySignatures = true,
  Uint8List? expectedLeafPkD,
}) {
  final prev = _allowInsecurePinGate;
  _allowInsecurePinGate = true;
  try {
    return _verifyAttestationChainPin(
      chain: chain,
      pinnedRootHashes: pinnedRootHashes,
      expectedChallenge: expectedChallenge,
      level: level,
      requireKeyOid: requireKeyOid,
      verifySignatures: verifySignatures,
      expectedLeafPkD: expectedLeafPkD,
    );
  } finally {
    _allowInsecurePinGate = prev;
  }
}

/// Offline chain-vs-pinned-roots gate (production): signatures ALWAYS
/// verify (pure-Dart X.509, leaf-first) and the attestation OID is ALWAYS
/// required — there are no downgrade flags (M4: the old
/// `verifySignatures:false` / `requireKeyOid:false` params existed only so
/// pin-pre-gate units could run synthetic leaves; they now live behind
/// [verifyAttestationChainPinForTest]).
///
/// [checkValidity] stays opt-in (default false) because the genuine Google
/// fixtures in chain_verify_test chain to the legacy 2016 root (expired
/// May 2026): fixture tests run without it, while the professor server
/// passes `checkValidity: true` explicitly.
ChainPinResult verifyAttestationChainPin({
  required AttestationChain chain,
  required List<Uint8List> pinnedRootHashes,
  required Uint8List expectedChallenge,
  required AttestationLevel level,
  Uint8List? expectedLeafPkD,
  DateTime? now,
  bool checkValidity = false,
}) =>
    _verifyAttestationChainPin(
      chain: chain,
      pinnedRootHashes: pinnedRootHashes,
      expectedChallenge: expectedChallenge,
      level: level,
      requireKeyOid: true,
      verifySignatures: true,
      expectedLeafPkD: expectedLeafPkD,
      now: now,
      checkValidity: checkValidity,
    );

ChainPinResult _verifyAttestationChainPin({
  required AttestationChain chain,
  required List<Uint8List> pinnedRootHashes,
  required Uint8List expectedChallenge,
  required AttestationLevel level,
  required bool requireKeyOid,
  required bool verifySignatures,
  Uint8List? expectedLeafPkD,
  DateTime? now,
  bool checkValidity = false,
}) {
  // The two downgrade hatches are test-only by construction: only
  // [verifyAttestationChainPinForTest] sets the zone flag (asserts fire in
  // debug if any other caller downgrades — and production has no params
  // to downgrade with).
  assert(
      verifySignatures || _allowInsecurePinGate,
      'verifySignatures:false is test-only (use verifyAttestationChainPinForTest).');
  assert(
      requireKeyOid || _allowInsecurePinGate,
      'requireKeyOid:false is test-only (use verifyAttestationChainPinForTest).');
  if (level == AttestationLevel.none) {
    return const ChainPinResult(
        ok: false, reason: 'level-none', flags: ['attest-level-none']);
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
  final leaf = chain.leaf!;
  if (requireKeyOid && !attestationLeafHasKeyOid(leaf)) {
    return const ChainPinResult(
        ok: false,
        reason: 'missing-attestation-oid',
        flags: ['attest-missing-oid']);
  }
  // C2 leaf-pkD bind (structure-only SPKI compare, no decryption): the
  // challenge binds pkS, so without this an attacker could transplant a
  // valid chain from another device onto their pkD. Runs before the
  // challenge gate so a key transplant fails as key mismatch, not challenge.
  if (expectedLeafPkD != null && expectedLeafPkD.isNotEmpty) {
    if (!leafPkDEquals(leaf, expectedLeafPkD)) {
      return const ChainPinResult(
          ok: false,
          reason: 'leaf-pkd-mismatch',
          flags: ['attest-leaf-pkd-mismatch']);
    }
  }
  if (expectedChallenge.isEmpty ||
      !_leafHasChallenge(leaf, expectedChallenge)) {
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

/// Opaque byte-containment for one challenge candidate (HARD REQUIREMENT:
///
/// sealed/attestation bytes are never decrypted or interpreted — only
/// structure, lengths, signatures, bindings are verified).
bool _leafHasChallenge(Uint8List leafDer, Uint8List challenge) =>
    attestationLeafContainsChallenge(leafDer, challenge);

/// M1-gap enrollment challenge (security §2, canonical):
/// `deviceBindingChallengeV2` below — domain-separated + length-prefixed
/// SHA256 over (emailLower || installId || pkS32).
///
/// Binds the key to the Gmail + install at enrollment without a server
/// nonce (no billing-gated backend exists to supply one). Lowercases +
/// trims the email, UTF-8 encodes email + installId, appends the raw 32-byte
/// Ed25519 pkS. Pure Dart — no platform code, no IMEI/serial/phone-ID.
/// The OS attestation record embeds this challenge; the offline professor
/// re-computes it and checks leaf containment via
/// [verifyAttestationChainPin].
///
/// BINDING SCOPE (C2): this challenge binds the SKey (pkS), NOT the DKey
/// (pkD). pkD enters trust only via the leaf-SPKI check
/// (`expectedLeafPkD` → `leaf-pkd-mismatch` in
/// [verifyAttestationChainPin]) plus the fresh dSig over the prove
/// preimage — never via this hash. A chain transplant across devices fails
/// the leaf check even when the challenge matches.
/// Domain tag for the enrollment challenge (M4 cross-protocol separation:
/// this hash verifies only as a Proximity device-binding challenge).
const String kDeviceBindingChallengeDomain = 'PROX-DHK-BIND/v1';

Uint8List _u16be(int v) {
  final b = ByteData(2)..setUint16(0, v & 0xFFFF, Endian.big);
  return b.buffer.asUint8List();
}

/// Enrollment challenge (canonical): domain-separated + length-prefixed.
///
/// `SHA256(domain || u16be(len(email)) || email || u16be(len(installId)) ||
/// installId || u16be(len(pkS)) || pkS)` where `email` is trimmed +
/// lowercased UTF-8, `domain` is [kDeviceBindingChallengeDomain]. The length
/// prefixes remove concat ambiguity and the domain tag stops a hash
/// minted for another protocol from verifying as a binding challenge.
///
/// The professor verifies exactly this challenge (no alternates, no
/// migration accepts) — pass it as `expectedChallenge` to
/// [verifyAttestationChainPin]. The leaf check stays opaque byte-containment
/// (HARD REQUIREMENT: sealed/attestation bytes are never decrypted or
/// interpreted — only structure, lengths, signatures, bindings are
/// verified).
Uint8List deviceBindingChallengeV2({
  required String emailLower,
  required String installId,
  required Uint8List pkS,
}) {
  final emailB = utf8.encode(emailLower.trim().toLowerCase());
  final installB = utf8.encode(installId);
  return ProxCrypto.sha256Sync(concat([
    utf8.encode(kDeviceBindingChallengeDomain),
    _u16be(emailB.length),
    emailB,
    _u16be(installB.length),
    installB,
    _u16be(pkS.length),
    pkS,
  ]));
}

/// Face-ticket anomaly flags for one proof (stateless half; the caller
/// supplies replay context):
/// - score==1.000 repeats ([priorScores] contains 1.0 and score==1.0):
///   'attest-score-saturated' (plugin cosine never reads exactly 1.0 on a
///   live capture twice — hook/mock replay signal);
/// - faceValidAt in the future beyond [futureSkew]: 'attest-future-face';
/// - faceValidAt reused ([seenFaceValidAtMs] contains it):
///   'attest-reused-face';
/// - verifierVer not in [allowlist] (prefix match): 'unknown-verifier';
/// - verifierVer differs from [lastVerifierVer] (non-empty both):
///   'verifier-flapping' (advisory — does not reject alone).
List<String> detectFaceAnomalies({
  required double score,
  required int faceValidAtMs,
  required String verifierVer,
  required DateTime now,
  List<double> priorScores = const [],
  Set<int> seenFaceValidAtMs = const {},
  List<String> allowlistPrefixes = const [kVerifierVerPrefix],
  String lastVerifierVer = '',
  Duration futureSkew = const Duration(seconds: 30),
}) {
  final flags = <String>[];
  final allowed = allowlistPrefixes.any((p) => verifierVer.startsWith(p));
  if (!allowed) flags.add('unknown-verifier');
  if (score >= 1.0 &&
      priorScores.any((s) => s >= 1.0)) {
    flags.add('attest-score-saturated');
  }
  final faceAt =
      DateTime.fromMillisecondsSinceEpoch(faceValidAtMs, isUtc: true);
  if (faceAt.isAfter(now.toUtc().add(futureSkew))) {
    flags.add('attest-future-face');
  }
  if (seenFaceValidAtMs.contains(faceValidAtMs)) {
    flags.add('attest-reused-face');
  }
  if (lastVerifierVer.isNotEmpty &&
      verifierVer.isNotEmpty &&
      lastVerifierVer != verifierVer) {
    flags.add('verifier-flapping');
  }
  return flags;
}
