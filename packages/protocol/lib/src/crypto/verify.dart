// WiFi HTTPS contract: endpoint schemas, rate limits, CSV export. §6.3, §7.1.
//
// Endpoints (professor embedded shelf server, foreground):
//   GET  /window          -> {class, sessionID, windowID, j_now, PK_p, Cert_p, Sig_p}
//   POST /prove {ID,windowID,j,C_j,Sig_s,faceScore,peerW} -> {confirmed|late|invalid, serverTime, Sig_pAck}
//   GET  /live            -> counts + rows (professor Bearer)
//   GET  /export          -> attendance.csv + .sig (professor Bearer)
//
// Present rule default: Present = pass W1 AND W2, else Partial/Absent (§7.1).
//
// only). verifyProve decision ORDER + reason strings, rate-limit counts +
// windows, and the revoked/unknown-id seams are untouched — the server
// passes revoked:false today, but the parameter is the future revocation
// seam. The W1/W2 CSV + signExport/verifyExport are likewise kept: still
// pinned by protocol + integration tests and a different schema from
// storage buildSimpleCsv (W-columns + Partial state), so not superseded.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import '../bytes.dart';
import '../constants.dart';
import '../device_binding.dart';
import 'primitives.dart';

enum ProveDecision { confirmed, late, invalid }

int decisionCode(ProveDecision d) => switch (d) {
      ProveDecision.confirmed => 0,
      ProveDecision.late => 1,
      ProveDecision.invalid => 2,
    };

/// Sliding-window IP rate limiter (in-memory, per-endpoint).
class RateLimiter {
  final int maxHits;
  final Duration window;
  final Map<String, List<DateTime>> _hits = {};

  RateLimiter({required this.maxHits, required this.window});

  bool allow(String ip, [DateTime? now]) {
    final n = (now ?? DateTime.now()).toUtc();
    final list = _hits.putIfAbsent(ip, () => []);
    list.removeWhere((t) => n.difference(t) > window);
    if (list.length >= maxHits) return false;
    list.add(n);
    return true;
  }
}

RateLimiter proveLimiter() =>
    RateLimiter(maxHits: kRateProveMax, window: kRateWindow);
RateLimiter windowLimiter() =>
    RateLimiter(maxHits: kRateWindowMax, window: kRateWindow);

/// Liveness gate threshold Tl (security §4, sec-protocol 1A).
///
/// The passive anti-spoof classifier (`LivenessGate.detect` in the app,
/// owned by sec-liveness) emits 0..1 on the same milli scale as the face
/// score. The host confirms only when `livenessScore >= kLivenessThreshold`.
/// Value 0.70 mirrors [kFaceThreshold] (strict, fail-closed); course-pinned
/// stricter lists are future work — lowering this constant is a ticket
/// break (bump min_version, never silent).
const double kLivenessThreshold = 0.70;

/// M3 one-sided future tolerance for the face-ticket stamp: a ticket may be
/// at most this far AHEAD of the verifier clock (clock skew), never more —
/// the old symmetric `abs() <= 5m` window accepted pre-played future
/// tickets. Anything later fails closed as `face-future-skew`.
const Duration kFaceFutureSkew = Duration(seconds: 30);

/// Liveness pipeline allowlist prefix. Stored `livenessVer` values look like
/// `liveness/minifasnet-v2+<assetHash8>` (model + weights pin). The host
/// accepts any version with this prefix unless a course pins a stricter
/// list (offline professor verifies against this prefix; mismatches fail
/// closed as `unknown-liveness-verifier`).
const String kLivenessVerPrefix = 'liveness/';

/// Professor verification per POST + BLE sighting (§5.3), pure-logic half:
/// window open, C_j match, UUID_S match, sig verify, PK lookup + CRL,
/// face, liveness (§4), sighting. Identity is the Gmail account
/// (no institute-ID matching).
class VerifyRequest {
  final String id;
  final Uint8List windowId;
  final int j;
  final Uint8List cClaimed;
  final Uint8List sigS;
  final double faceScore;
  final DateTime faceValidAt;
  final Uint8List peerW;
  final int rssiDbm;
  final int relayHop; // 0 = direct
  final DateTime now;
  // Tracks 2+3 local-trust ticket (transported in POST /prove
  // face:{score,faceValidAt,verifierVer} — no images/embeddings leave the
  // device). Sig_s binds all three via faceTicketHash + pkD (see
  // primitives.studentProvePreimage).
  final String verifierVer;
  final int faceValidAtMs;
  final Uint8List pkD; // DKey raw (empty = unbound legacy)
  final Uint8List faceTicketHashBytes;
  // Security §4 liveness ticket (transported in POST /prove
  // liveness:{score,ver} — classifier output only, no images). Sig_s AND
  // dSig bind both fields via the extended faceTicketHash (score||face ||
  // verifierVerHash8||livenessMilli||livenessVerHash8). Empty/0.0 =
  // unbound (pre-liveness); the bound path fails those closed, never as
  // a silent downgrade.
  final double livenessScore;
  final String livenessVer;
  final List<String> livenessAllowlist;
  // window. [dSigValid] is the P-256 verify over deviceProvePreimage,
  // computed by the platform adapter before calling in.
  final AttestationLevel attestationLevel;
  final DateTime attestedAt;
  final DateTime attestedUntil;
  final bool dSigValid;
  // Replay/anomaly context (server-kept): previously seen faceValidAt
  // stamps, prior scores for the 1.000-repeat flag, and the last
  // verifierVer for flapping detection.
  final Set<int> seenFaceValidAtMs;
  final List<double> priorScores;
  final String lastVerifierVer;
  final List<String> verifierAllowlist;
  VerifyRequest({
    required this.id,
    required this.windowId,
    required this.j,
    required this.cClaimed,
    required this.sigS,
    required this.faceScore,
    required this.faceValidAt,
    required this.peerW,
    required this.rssiDbm,
    required this.relayHop,
    required this.now,
    this.verifierVer = '',
    this.faceValidAtMs = 0,
    Uint8List? pkD,
    Uint8List? faceTicketHashBytes,
    this.livenessScore = 0.0,
    this.livenessVer = '',
    this.livenessAllowlist = const [kLivenessVerPrefix],
    this.attestationLevel = AttestationLevel.none,
    DateTime? attestedAt,
    DateTime? attestedUntil,
    this.dSigValid = false,
    this.seenFaceValidAtMs = const {},
    this.priorScores = const [],
    this.lastVerifierVer = '',
    this.verifierAllowlist = const [kVerifierVerPrefix],
  })  : pkD = pkD ?? Uint8List(0),
        faceTicketHashBytes = faceTicketHashBytes ?? Uint8List(0),
        attestedAt = attestedAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        attestedUntil = attestedUntil ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

class VerifyOutcome {
  final ProveDecision decision;
  final String reason;
  /// Attestation anomaly flags (score==1.000 repeats, future/reused
  /// faceValidAt, verifierVer flapping, device-stale banner). Signed ACK
  /// itself is unchanged; flags ride alongside for logging + post-hoc sync
  /// audit (double-pkD).
  final List<String> attestationFlags;
  const VerifyOutcome(this.decision, this.reason,
      [this.attestationFlags = const []]);
}

/// Stateless verifier (caller supplies enrolled PK + CRL + expected C_j).
///
/// Three modes (migration-safe, no silent downgrade):
/// - legacy (default): [VerifyRequest] carries no ticket (empty
///   verifierVer/pkD/livenessVer) and [requireBoundTicket] is false — the
///   original 6-field Sig_s preimage path with neutral defaults. Existing
///   callers verify exactly as before; no new gate applies.
/// - bound (Tracks 2+3 + §4 liveness): the request carries the
///   face+liveness ticket (score/faceValidAt/verifierVer +
///   livenessScore/livenessVer + pkD) or [requireBoundTicket] is true (the
///   professor server always sets it) — Sig_s is verified over the extended
///   preimage, the verifierVer allowlist + faceValid window apply, the
///   liveness gate (`>= kLivenessThreshold` + liveness allowlist) applies,
///   device-proof tiers gate (FULL/STD→confirmed, STALE→confirmed+banner),
///   and attestation anomaly flags ride on the outcome. Legacy and
///   pre-liveness tickets fail closed here once [requireLiveness] flips
///   (`face-unbound` / `unknown-verifier` / `liveness-unbound` /
///   `unknown-liveness-verifier` / `liveness-below-threshold`), never
///   auto-present. During migration ([requireLiveness] false) face-bound
///   proofs without liveness still confirm (no liveness claimed).
/// - bound with level NONE (explicit fallback — HW keys don't ship, so
///   production `SoftwareDeviceKey` is always NONE): C3 fail-closed by
///   default — returns `device-none-requires-approval` (never confirms)
///   unless the caller explicitly passes [allowNoneFallback]: true (server
///   test compat / documented deployment allowance). With the flag, the
///   ticket-bound Sig_s, face threshold/window, allowlists (face +
///   liveness), liveness threshold and sighting checks all still apply, but
///   no device tier is claimed and `dSig` is not gated. Confirms with a
///   `device-none-fallback` flag (logged, never silent). Tampered
///   ticket/pkD/liveness bindings still fail as `bad-sig`; FULL/STD/expiry
///   semantics unchanged.
/// - legacy (unbound): C3 migration bypass closed — when [requireLiveness]
///   is true a legacy proof (liveness fields absent 0.0/'') fails closed as
///   `liveness-unbound` unless the caller explicitly passes [legacyAllow]:
///   true (mixed-fleet tests). With [requireLiveness] false the legacy
///   confirm path is unchanged.
VerifyOutcome verifyProve({
  required VerifyRequest req,
  required Uint8List expectedCj,
  required Uint8List sessionId,
  required Uint8List windowIdExpected,
  required ed.PublicKey? studentPk, // null = unknown ID
  required bool revoked,
  required bool freshWindow, // 0 <= now - t_j < kSubEpochSeconds + kFreshness
  required bool singleUseOk, // (ID,j) unseen
  DateTime? nowOverride,
  bool requireBoundTicket = false,
  // Security §4 migration grace (PROXIMITY_SECURITY.md:121-123): false
  // (default) accepts pre-liveness face-bound proofs without a liveness
  // gate — live marking + existing tests keep working while liveness
  // clients roll out. Proofs that DO carry liveness fields are always
  // gated (allowlist + >= Tl on BOTH the NONE fallback and FULL/STD
  // paths), never silently downgraded.
  // TODO(sec-face): flip default to true together with the
  // liveness-required min_version bump + `unknown-liveness-verifier`
  // allowlist deploy — then pre-liveness fails `liveness-unbound`, never
  // a silent downgrade. Post-rollout test pins the closed behavior;
  // migration test pins the open default.
  bool requireLiveness = false,
  // C3(a): bound-NONE fallback allowance. False (default) fails a
  // ticket-bound NONE proof closed as `device-none-requires-approval`
  // (never confirms, never silent). True restores the explicit
  // confirm-with-`device-none-fallback`-flag path for deployments/tests
  // that knowingly run without HW keys.
  bool allowNoneFallback = false,
  // C3(b): legacy pre-liveness allowance. False (default) fails a legacy
  // (unbound, liveness 0.0/'') proof closed as `liveness-unbound` once
  // [requireLiveness] is true. True preserves the legacy confirm path
  // for mixed-fleet tests.
  bool legacyAllow = false,
}) {
  final now = (nowOverride ?? req.now).toUtc();
  if (!bytesEqual(req.windowId, windowIdExpected)) {
    return const VerifyOutcome(ProveDecision.invalid, 'window-mismatch');
  }
  if (!freshWindow) {
    return const VerifyOutcome(ProveDecision.late, 'stale-sub-epoch');
  }
  if (!singleUseOk) {
    return const VerifyOutcome(ProveDecision.invalid, 'replay-id-j');
  }
  if (!bytesEqual(req.cClaimed, expectedCj)) {
    return const VerifyOutcome(ProveDecision.invalid, 'bad-challenge');
  }
  if (studentPk == null) {
    return const VerifyOutcome(ProveDecision.invalid, 'unknown-id');
  }
  if (revoked) {
    return const VerifyOutcome(ProveDecision.invalid, 'revoked');
  }
  final bound = requireBoundTicket ||
      req.verifierVer.isNotEmpty ||
      req.faceValidAtMs != 0 ||
      req.pkD.isNotEmpty ||
      req.livenessVer.isNotEmpty ||
      req.livenessScore != 0.0;
  // The SIGNED stamp is authoritative for the preimage: legacy callers
  // leave faceValidAtMs at 0 (matching their sign-time defaults), bound
  // callers stamp the same millis they signed. The DateTime field drives
  // the faceValid window check below (callers/servers keep both in sync).
  final faceAtMs = req.faceValidAtMs;
  final ticket = req.faceTicketHashBytes.isNotEmpty
      ? req.faceTicketHashBytes
      : ProxCrypto.faceTicketHash(
          faceScore: req.faceScore,
          faceValidAtMs: faceAtMs,
          verifierVer: req.verifierVer,
          livenessScore: req.livenessScore,
          livenessVer: req.livenessVer);
  final sigOk = ProxCrypto.verifyStudentProve(
    studentPk: studentPk,
    sessionId: sessionId,
    windowId: req.windowId,
    j: req.j,
    challenge: expectedCj,
    studentId: req.id,
    faceScore: req.faceScore,
    sig: req.sigS,
    faceValidAtMs: faceAtMs,
    verifierVer: req.verifierVer,
    pkD: req.pkD,
    faceTicketHashBytes: ticket,
  );
  List<String> flags() => detectFaceAnomalies(
        score: req.faceScore,
        faceValidAtMs: faceAtMs,
        verifierVer: req.verifierVer,
        now: now,
        priorScores: req.priorScores,
        seenFaceValidAtMs: req.seenFaceValidAtMs,
        allowlistPrefixes: req.verifierAllowlist,
        lastVerifierVer: req.lastVerifierVer,
      );
  if (!sigOk) {
    return VerifyOutcome(
        ProveDecision.invalid, 'bad-sig', bound ? flags() : const []);
  }
  if (req.faceScore < kFaceThreshold) {
    return VerifyOutcome(ProveDecision.invalid, 'face-below-threshold',
        bound ? flags() : const []);
  }
  // M3 one-sided faceValid window: the stamp must be at most 30s in the
  // future (clock skew) and at most 5m old. The old symmetric abs() check
  // accepted pre-played future tickets.
  final faceAt = req.faceValidAt.toUtc();
  if (faceAt.isAfter(now.add(kFaceFutureSkew))) {
    return VerifyOutcome(ProveDecision.invalid, 'face-future-skew',
        bound ? flags() : const []);
  }
  if (now.difference(faceAt) > kFaceValidWindow) {
    return VerifyOutcome(
        ProveDecision.invalid, 'face-stale', bound ? flags() : const []);
  }
  if (bound) {
    // Bound-ticket gate: non-zero stamp + allowlisted verifierVer, or the
    // ticket was transplanted across pipelines. Fail closed — never
    // auto-present on an unbound match.
    final allowed =
        req.verifierAllowlist.any((p) => req.verifierVer.startsWith(p));
    if (faceAtMs == 0 || req.verifierVer.isEmpty || !allowed) {
      final reason = req.verifierVer.isNotEmpty && !allowed
          ? 'unknown-verifier'
          : 'face-unbound';
      return VerifyOutcome(ProveDecision.invalid, reason, flags());
    }
    // Security §4 liveness gate: the extended ticket binds
    // (livenessScore, livenessVer). Proofs CARRYING liveness are always
    // gated (allowlisted pipeline + score >= Tl) on BOTH the NONE fallback
    // and FULL/STD paths. Pre-liveness proofs (0.0/'') gate only when
    // [requireLiveness] is true (post-rollout + min_version bump → fail
    // `liveness-unbound`, never a silent downgrade); during migration they
    // confirm as face-bound (no liveness claimed, no liveness flag).
    final carriesLiveness =
        req.livenessVer.isNotEmpty || req.livenessScore != 0.0;
    if (carriesLiveness || requireLiveness) {
      final livenessAllowed = req.livenessAllowlist
          .any((p) => req.livenessVer.startsWith(p));
      if (req.livenessVer.isEmpty || req.livenessScore == 0.0) {
        return VerifyOutcome(
            ProveDecision.invalid, 'liveness-unbound', flags());
      }
      if (!livenessAllowed) {
        return VerifyOutcome(
            ProveDecision.invalid, 'unknown-liveness-verifier', flags());
      }
      if (req.livenessScore < kLivenessThreshold) {
        return VerifyOutcome(
            ProveDecision.invalid, 'liveness-below-threshold', flags());
      }
    }
    // C3(a) fail-closed NONE: a bound proof claiming no device tier never
    // confirms by default — `device-none-requires-approval` routes it to
    // the manual path instead of silently marking. Explicit
    // [allowNoneFallback]: true restores the flagged confirm below.
    if (req.attestationLevel == AttestationLevel.none) {
      if (!allowNoneFallback) {
        return VerifyOutcome(ProveDecision.invalid,
            'device-none-requires-approval', flags());
      }
      final fallbackFlags = [...flags(), 'device-none-fallback'];
      final direct = req.relayHop == 0 && req.rssiDbm > kRssiDirectDbm;
      final relayed = req.relayHop > 0 && req.relayHop <= kMaxRelayHop;
      if (!direct && !relayed) {
        return VerifyOutcome(
            ProveDecision.invalid, 'no-ble-sighting', fallbackFlags);
      }
      return VerifyOutcome(ProveDecision.confirmed, 'ok', fallbackFlags);
    }
    // STALE (14d grace)→confirmed+banner, expired/bad-dSig→device-unproven.
    final proof = evaluateDeviceProof(
      level: req.attestationLevel,
      attestedAt: req.attestedAt,
      attestedUntil: req.attestedUntil,
      dSigValid: req.dSigValid,
      now: now,
    );
    final allFlags = [...flags(), ...proof.auditFlags];
    if (!proof.confirms) {
      return VerifyOutcome(
          ProveDecision.invalid, 'device-unproven', allFlags);
    }
    // BLE sighting: direct RSSI > -70, or relayed hop <= 2 (flagged).
    final direct = req.relayHop == 0 && req.rssiDbm > kRssiDirectDbm;
    final relayed = req.relayHop > 0 && req.relayHop <= kMaxRelayHop;
    if (!direct && !relayed) {
      return VerifyOutcome(
          ProveDecision.invalid, 'no-ble-sighting', allFlags);
    }
    // STALE confirms with its banner flag (heartbeat should roll
    // attestedUntil; the flag tells the professor to expect re-attest).
    return VerifyOutcome(ProveDecision.confirmed, 'ok', allFlags);
  }
  // C3(b) legacy-unbound closed: post-liveness-floor (requireLiveness true)
  // a legacy proof (no ticket at all) fails as liveness-unbound unless the
  // caller explicitly opts into mixed-fleet via legacyAllow. With
  // requireLiveness false the legacy confirm path is unchanged.
  if (!bound && requireLiveness && !legacyAllow) {
    return const VerifyOutcome(ProveDecision.invalid, 'liveness-unbound');
  }
  // BLE sighting: direct RSSI > -70, or relayed hop <= 2 (flagged).
  final direct = req.relayHop == 0 && req.rssiDbm > kRssiDirectDbm;
  final relayed = req.relayHop > 0 && req.relayHop <= kMaxRelayHop;
  if (!direct && !relayed) {
    return const VerifyOutcome(ProveDecision.invalid, 'no-ble-sighting');
  }
  return const VerifyOutcome(ProveDecision.confirmed, 'ok');
}

// ------------------------------------------------------------ CSV export ---

/// attendance-<date>-<class>.csv + detached Sign(SK_p, H(csv)).
/// Identity is the Gmail account: rows are Name + Email (no institute ID).
String buildAttendanceCsv({
  required String classLabel,
  required String dateIso,
  required Map<String, bool> w1, // keyed by lowercased email
  required Map<String, bool> w2, // keyed by lowercased email
  required Map<String, String> names, // email -> display name
  Map<String, String> rolls = const {}, // email -> roll no. (unverified)
  bool lenientOneOfTwo = false,
}) {
  final emails = <String>{...w1.keys, ...w2.keys, ...names.keys}.toList()
    ..sort();
  final sb = StringBuffer('Name,ID Number,Email,W1,W2,Status\n');
  for (final email in emails) {
    final a = w1[email] ?? false, b = w2[email] ?? false;
    final status = (lenientOneOfTwo ? (a || b) : (a && b))
        ? 'Present'
        : (a || b)
            ? 'Partial'
            : 'Absent';
    sb.writeln(
        '${names[email] ?? ''},${rolls[email] ?? ''},$email,${a ? 1 : 0},${b ? 1 : 0},$status');
  }
  return sb.toString();
}

Uint8List signExport(ed.PrivateKey profSk, String csv) =>
    ProxCrypto.sign(profSk, ProxCrypto.sha256Sync(utf8.encode(csv)));

bool verifyExport(ed.PublicKey profPk, String csv, List<int> sig) =>
    ProxCrypto.verify(profPk, ProxCrypto.sha256Sync(utf8.encode(csv)), sig);
