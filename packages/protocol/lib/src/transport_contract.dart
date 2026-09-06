// WiFi HTTPS contract: endpoint schemas, rate limits, CSV export. §6.3, §7.1.
//
// Endpoints (professor embedded shelf server, foreground):
//   GET  /window          -> {class, sessionID, windowID, j_now, PK_p, Cert_p, Sig_p}
//   POST /prove {ID,windowID,j,C_j,Sig_s,faceScore,peerW} -> {confirmed|late|invalid, serverTime, Sig_pAck}
//   GET  /live            -> counts + rows (professor Bearer)
//   GET  /export          -> attendance.csv + .sig (professor Bearer)
//
// Present rule default: Present = pass W1 AND W2, else Partial/Absent (§7.1).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';

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

/// Professor verification per POST + BLE sighting (§5.3), pure-logic half:
/// window open, C_j match, UUID_S match, sig verify, PK lookup + CRL,
/// face, sighting. Identity is the Gmail account (no institute-ID matching).
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
  });
}

class VerifyOutcome {
  final ProveDecision decision;
  final String reason;
  const VerifyOutcome(this.decision, this.reason);
}

/// Stateless verifier (caller supplies enrolled PK + CRL + expected C_j).
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
  final sigOk = ProxCrypto.verifyStudentProve(
    studentPk: studentPk,
    sessionId: sessionId,
    windowId: req.windowId,
    j: req.j,
    challenge: expectedCj,
    studentId: req.id,
    faceScore: req.faceScore,
    sig: req.sigS,
  );
  if (!sigOk) {
    return const VerifyOutcome(ProveDecision.invalid, 'bad-sig');
  }
  if (req.faceScore < kFaceThreshold) {
    return const VerifyOutcome(ProveDecision.invalid, 'face-below-threshold');
  }
  if (now.difference(req.faceValidAt.toUtc()).abs() > kFaceValidWindow) {
    return const VerifyOutcome(ProveDecision.invalid, 'face-stale');
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
