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
// chain verification lives in the platform adapter (app layer) against
// pins provisioned here; no billing-gated backend carries one, so FULL/STD
// mean "claims hardware backing", verified only as a fresh signature over
// the live challenge plus offline pin checks below, never as server
// provenance. See PROXIMITY_DESIGN.md §3.4.
//
// Security §4 liveness: the face ticket bound into Sig_s/dSig now carries
// (livenessScore, livenessVer) — see crypto/primitives.dart faceTicketHash
// and crypto/verify.dart liveness gates. This file does NOT gate liveness;
// it owns the device side (chain/level/window + dSig tier).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';
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
/// one X.509 cert. This class is the pure-Dart in-memory form: no ASN.1
/// parse, no platform code, no IMEI. Full X.509 signature verify lives in
/// the platform adapter (app layer, owned by sec-hwkey); the pure pin
/// checks below ([verifyAttestationChainPin]) run offline on the professor
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
/// 06 09 2B 06 01 04 01 D6 79 02 01 11.
/// Pure-byte needle for [attestationLeafHasKeyOid] — no ASN.1 parser needed.
const List<int> kKeyAttestationOidDer = [
  0x06,
  0x09,
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
/// means "not an attestation cert" (fail closed). Full cert-signature
/// verify is the platform adapter's job — this only gates format.
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
/// (pins computed 2026-09-12 from the page's PEM roots):
/// - RSA root, serial f92009e853b6b045, valid to 2042-03-15.
/// - EC root ("Key Attestation CA11"), valid 2025-07-17 → 2035-07-15;
///   starts signing device chains 2026-02-01.
/// Legacy roots (2016/2019/2021) are deliberately omitted: the 2016 root
/// expired May 2026 and pre-2021 devices chaining to it fail closed as
/// `unknown-root` (manual path) rather than silently trusting an expired
/// anchor. iOS App Attest chains pin Apple roots instead — callers pass
/// their own [pinnedRootHashes]; these defaults are the Android set.
const String kGoogleHwAttestationRootRsaSha256Hex =
    'df1d9307e9905467bd87f3a596da5269525f81971c7a0ea0a9c364746b1271a7';
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
///    else `missing-attestation-oid`;
/// 4. leaf embeds [expectedChallenge] (see [deviceBindingChallenge]) —
///    else `challenge-mismatch`;
/// 5. SHA256(root DER) ∈ [pinnedRootHashes] (Google roots provisioned at
///    setup) — else `unknown-root`.
///
/// [pinnedRootHashes] are raw 32-byte SHA-256 digests of trusted root DERs
/// (TOFU→pin-check: first online fetch pins, offline verifies against the
/// pin). iOS App Attest flows through the same carrier with Apple roots —
/// the OID/challenge gates are Android-shaped; iOS callers pass their
/// pinned Apple root and skip the OID gate via [requireKeyOid] = false.
///
/// X.509 signature math is explicitly OUT of scope here (platform adapter
/// owns it) — this is the pure format+pin+challenge gate the professor
/// runs offline before [evaluateDeviceProof] tiers the proof.
ChainPinResult verifyAttestationChainPin({
  required AttestationChain chain,
  required List<Uint8List> pinnedRootHashes,
  required Uint8List expectedChallenge,
  required AttestationLevel level,
  bool requireKeyOid = true,
}) {
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
  if (expectedChallenge.isEmpty ||
      !attestationLeafContainsChallenge(leaf, expectedChallenge)) {
    return const ChainPinResult(
        ok: false,
        reason: 'challenge-mismatch',
        flags: ['attest-challenge-mismatch']);
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

/// M1-gap enrollment challenge (security §2, canonical):
/// SHA256(emailLower || installId || pkS32).
///
/// Binds the key to the Gmail + install at enrollment without a server
/// nonce (no billing-gated backend exists to supply one). Lowercases +
/// trims the email, UTF-8 encodes email + installId, appends the raw 32-byte
/// Ed25519 pkS. Pure Dart — no platform code, no IMEI/serial/phone-ID.
/// The OS attestation record embeds this challenge; the offline professor
/// re-computes it and checks leaf containment via
/// [verifyAttestationChainPin].
Uint8List deviceBindingChallenge({
  required String emailLower,
  required String installId,
  required Uint8List pkS,
}) =>
    ProxCrypto.sha256Sync(concat([
      utf8.encode(emailLower.trim().toLowerCase()),
      utf8.encode(installId),
      pkS,
    ]));

/// Legacy attestation challenge (pre-M1-gap):
/// SHA256(serverNonce || emailLower || installId || pkS32).
///
/// Kept so historical call sites/tests compile — new enrollments MUST use
/// [deviceBindingChallenge] (no server nonce exists offline). Do not call
/// for new code.
@Deprecated('M1-gap canonical is deviceBindingChallenge (no serverNonce).')
Uint8List attestationChallenge({
  required Uint8List serverNonce,
  required String emailLower,
  required String installId,
  required Uint8List pkS,
}) =>
    ProxCrypto.sha256Sync(concat([
      serverNonce,
      utf8.encode(emailLower.trim().toLowerCase()),
      utf8.encode(installId),
      pkS,
    ]));

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
