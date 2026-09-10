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
// attestation-challenge helper. Trust caveat, stated plainly: the
// [level] below is SELF-ASSERTED by the presenting device — no chain
// verification exists anywhere in this system (no billing-gated backend
// carries one), so FULL/STD mean "claims hardware backing", verified
// only as a fresh signature over the live challenge, never as silicon
// provenance. See PROXIMITY_DESIGN.md §3.4.
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

/// Attestation challenge bound at enrollment:
/// SHA256(serverNonce || emailLower || installId || pkS32).
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

/// Exact-1.0 check helper (single proof, no history): a lone 1.000 is
/// suspicious but not conclusive — the host records it; the REPEAT is the
/// flag (see [detectFaceAnomalies]).
bool isSaturatedScore(double score) => score >= 1.0;
