// Enrollment finalize math: pure, testable decision helpers for
// [EnrollmentController] (see core/enrollment.dart). Extraction only —
// no thresholds, values, or decision outcomes changed here. Thresholds
// stay canonical in enrollment.dart and are passed in as arguments, so
// this unit never duplicates a tuned value.
//
// The async hold-out FaceSession verify itself stays in the controller
// (it needs the embedder); the pure composition around it — probe mean
// of LEFT+RIGHT, saved template mean of all five — lives here.
library;

import 'dart:math' as math;

import 'package:proximity_protocol/protocol.dart';

/// Mean embedding direction of several enrollment frames, L2-normalized.
/// All vectors must share a length; single-frame input returns it unchanged.
List<double> averageUnit(List<List<double>> vectors) {
  final n = vectors.first.length;
  final mean = List.filled(n, 0.0);
  for (final v in vectors) {
    assert(v.length == n);
    for (var i = 0; i < n; i++) {
      mean[i] += v[i] / vectors.length;
    }
  }
  var norm = 0.0;
  for (final x in mean) {
    norm += x * x;
  }
  norm = math.sqrt(norm);
  if (norm == 0) return mean;
  return [for (final x in mean) x / norm];
}

/// Lowest pairwise cosine in [vectors] (1.0 for a single vector).
double minPairwise(List<List<double>> vectors) {
  var minPair = 1.0;
  for (var i = 0; i < vectors.length; i++) {
    for (var j = i + 1; j < vectors.length; j++) {
      final c = cosineSimilarity(vectors[i], vectors[j]);
      if (c < minPair) minPair = c;
    }
  }
  return minPair;
}

/// Best agreeing slot pair: highest pairwise cosine over slot means.
({int bi, int bj, double best}) bestAgreeingPair(
    List<List<double>> means) {
  var bi = 0, bj = 1;
  var best = -2.0;
  for (var i = 0; i < means.length; i++) {
    for (var j = i + 1; j < means.length; j++) {
      final c = cosineSimilarity(means[i], means[j]);
      if (c > best) {
        best = c;
        bi = i;
        bj = j;
      }
    }
  }
  return (bi: bi, bj: bj, best: best);
}

/// Odd-ones-out vs the best pair at [floor]: every non-pair slot whose
/// cosine to BOTH pair members sits below the agreement floor.
List<int> oddOnesOut(
    List<List<double>> means, int bi, int bj, double floor) {
  return [
    for (var k = 0; k < means.length; k++)
      if (k != bi &&
          k != bj &&
          cosineSimilarity(means[k], means[bi]) < floor &&
          cosineSimilarity(means[k], means[bj]) < floor)
        k
  ];
}

/// Index of the single slot with the lowest total agreement with the
/// rest (least sum of pairwise cosines). Monotonic-progress primitive.
int worstSlotIndex(List<List<double>> means) {
  var worst = 0;
  var worstSum = double.infinity;
  for (var k = 0; k < means.length; k++) {
    var sum = 0.0;
    for (var j = 0; j < means.length; j++) {
      if (j == k) continue;
      sum += cosineSimilarity(means[k], means[j]);
    }
    if (sum < worstSum) {
      worstSum = sum;
      worst = k;
    }
  }
  return worst;
}

/// Hold-out validation probe: mean of the LEFT+RIGHT slot means only.
/// Symmetric yaw cancels back toward frontal, so the held-out centre
/// frame reads frontal-like. Top/Bottom stay out (pitched foreshortening
/// would drag any 5-way mean down past any pass).
List<double> holdoutProbe(List<List<double>> means) =>
    averageUnit([means[1], means[2]]);

/// Saved template: normalized mean of ALL FIVE slot means. The hold-out
/// mean above is validation-only; this is what persists.
List<double> finalizeTemplate(List<List<double>> means) =>
    averageUnit(means);
