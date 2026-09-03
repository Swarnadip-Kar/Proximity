// Face gate: threshold + freshness + retry policy. §4 (logic only; embeddings mocked in tests).
//
// Purpose: key proves phone, BLE proves location, face proves holder.
// Gating: SK use requires faceValid < 5min. Each 30s window demands fresh check.
// Failure: 2 instant retries, then needs-review (professor logged manual override).
// Threshold: cosine 0.60 starting point (FAR ~0.01% / FRR <2% pilot-tuned).
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
