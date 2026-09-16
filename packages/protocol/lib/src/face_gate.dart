// Face gate: threshold + freshness + retry policy. §4 (logic only; the
// on-device match itself runs in the `face_verification` plugin — see
// features/face_identity/face_verifier.dart in the app).
//
// Purpose: key proves phone, BLE proves location, face proves holder.
// Gating: SK use requires faceValid < 5min. Each 30s window demands fresh check.
// Failure: 2 instant retries, then needs-review (professor logged manual override).
// Threshold: 0.70 on the plugin (FaceNet) score scale — plugin default,
// UNCALIBRATED on Proximity captures (uncalibrated, field ROC required per
// liveness_calibration_test procedure before quoting any FAR/FRR — no
// invented numbers). The old 0.60/0.80 EdgeFace-XS cosine numbers MUST NOT
// be reused (deleted pipeline, incomparable space).
// Score note: the plugin returns identity only (matched id or null), never
// a distance — a match carries the decision threshold as its score (honest
// boundary value, host re-checks score>=T); distance unavailable by plugin
// contract, so the score is kept as the boundary with this note.
// Crop-path note: the liveness scorer runs on the face-box crop with a
// legacy centre-square fallback (same scorer + same Tl, never a pass by
// itself) — callers MUST debugPrint which path scored per still (box vs
// fallback) so field review can tell them apart.
// Size-gate note (unified): still readability gates (empty path, missing /
// zero-byte file, tiny frame, non-image magic, <8px decode) live in the
// callers (face_verifier_plugin + liveness native) and fail closed BEFORE
// scoring — this gate never sees an unreadable still.
// Passive only: no blink/turn-head prompts — production callers pass
// livenessPass:true; the parameter stays so historical call sites compile,
// but nothing gates on an active prompt anymore.
library;

import 'dart:math';

import 'constants.dart';

double cosineSimilarity(List<double> a, List<double> b) {
  assert(a.length == b.length && a.isNotEmpty);
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0.0;
  return dot / (sqrt(na) * sqrt(nb));
}

enum FaceDecision { pass, retry, needsReview }

class FaceGate {
  final double threshold;
  final Duration validWindow;
  final int maxRetries;

  DateTime? _lastValidAt;
  int _consecFails = 0;

  FaceGate({
    this.threshold = kFaceThreshold,
    this.validWindow = kFaceValidWindow,
    this.maxRetries = kFaceMaxRetries,
  });

  /// Evaluate one match attempt. Updates valid stamp / fail counter.
  FaceDecision evaluate({
    required double score,
    required bool livenessPass,
    DateTime? now,
  }) {
    final n = (now ?? DateTime.now()).toUtc();
    if (score >= threshold && livenessPass) {
      _lastValidAt = n;
      _consecFails = 0;
      return FaceDecision.pass;
    }
    _consecFails += 1;
    if (_consecFails > maxRetries) return FaceDecision.needsReview;
    return FaceDecision.retry;
  }

  /// SK-use gate: faceValid < 5min.
  bool get canSign => isFresh();

  bool isFresh([DateTime? now]) {
    final last = _lastValidAt;
    if (last == null) return false;
    final n = (now ?? DateTime.now()).toUtc();
    return n.difference(last) < validWindow;
  }

  /// Throws if SK use attempted without fresh face (signing API contract).
  void requireFreshForSign([DateTime? now]) {
    if (!isFresh(now)) {
      throw StateError('SK locked: faceValid expired — fresh face check required');
    }
  }

  int get consecFails => _consecFails;
  DateTime? get lastValidAt => _lastValidAt;

  void reset() {
    _lastValidAt = null;
    _consecFails = 0;
  }
}
