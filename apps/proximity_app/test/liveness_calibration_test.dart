// sec-face: Tl calibration harness (NO Proximity-measured ROC — Tl=0.85 is
// a STRICT posture from upstream data, not a Proximity EER).
//
// Tl=0.85 (`kLivenessThreshold`, protocol-owned) is the shipped STRICT
// operating point (2.7x training crop + upstream ~98.2% acc / ROC-AUC
// 0.9984 + APK near FPR 1e-5 @ TPR 97.8%; proxy incentive + cheap rescan
// recovery). FAR/FRR remain UNMEASURED on Proximity captures (see
// `liveness_gate.dart` header). Do NOT invent ROC numbers — every score
// below marked SYNTHETIC is a hand-written fixture that pins the HARNESS
// MATH only, never a claim about the model.
//
// Procedure (run on REAL labeled Proximity captures to re-calibrate):
//   1. Collect labeled stills: genuine holder stills (live) + print/replay
//      spoofs, same capture pipeline (face-box crop path).
//   2. Score each still offline via `LivenessGate.detectPassive` (the real
//      `HeuristicLivenessGate` on device — never the fake) → 0..1 vitality.
//   3. Feed the (score, isLive) pairs in as `LabeledScore`s → `sweepTl()` →
//      `formatCalibrationTable()` for the FAR/FRR table.
//   4. Pick Tl via `recommendTl()` (EER default, or lowest-FRR under a
//      `maxFar` cap for a strict posture) — the recommendation is computed
//      from YOUR data, never from this file's fixtures.
//   5. Ship the new Tl ONLY as: bump `kLivenessThreshold`
//      (`packages/protocol/lib/src/crypto/verify.dart`) + bump
//      `kLivenessVer` (`liveness_gate.dart` — new tag forces re-face, key
//      kept) + `min_version` floor bump with the rules deploy together +
//      update this file's pins. Never change Tl silently.
//
// TODO(sec-face): measure a Proximity ROC, then:
//   a. set the Tl this harness recommends on that data;
//   b. bump `kLivenessVer` (new tag — stale-pipeline re-face, key kept);
//   c. bump `kLivenessThreshold` in protocol + `min_version` floor;
//   d. replace the SYNTHETIC pins below with the measured table reference.
// Until then `kLivenessVer` stays UNCHANGED (pinned by test below).
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart'
    show kLivenessVer;
import 'package:proximity_protocol/protocol.dart' show kLivenessThreshold;

/// One labeled capture score: vitality 0..1 + ground truth.
class LabeledScore {
  /// Classifier vitality score (0..1, same milli scale as the gate).
  final double score;

  /// True = genuine holder still; false = print/replay spoof.
  final bool isLive;

  /// Capture kind label for the report (`live`, `print`, `replay`).
  final String kind;

  const LabeledScore(
      {required this.score, required this.isLive, required this.kind});
}

/// FAR/FRR at one candidate threshold: FAR = spoofs scoring >= Tl / all
/// spoofs; FRR = lives scoring < Tl / all lives.
class TlPoint {
  final double threshold;
  final double far;
  final double frr;
  final int nLive;
  final int nSpoof;
  const TlPoint(
      {required this.threshold,
      required this.far,
      required this.frr,
      required this.nLive,
      required this.nSpoof});

  /// Equal-error distance (0 at the EER crossing).
  double get eerGap => (far - frr).abs();
}

/// Default sweep grid: 0.50..0.95 step 0.05 (the plausible operating band
/// around the shipped 0.70 — full 0..1 adds no decision value, only rows).
List<double> defaultSweepThresholds() =>
    [for (var t = 50; t <= 95; t += 5) t / 100];

/// Sweeps [thresholds] over [scores]. Throws [ArgumentError] when either
/// class is absent (a one-sided set cannot define both rates — collect
/// both live AND spoof captures) or on non-finite/out-of-range scores.
List<TlPoint> sweepTl(List<LabeledScore> scores, List<double> thresholds) {
  for (final s in scores) {
    if (!s.score.isFinite || s.score < 0.0 || s.score > 1.0) {
      throw ArgumentError('score out of range 0..1: ${s.score}');
    }
  }
  final lives = [for (final s in scores) if (s.isLive) s.score];
  final spoofs = [for (final s in scores) if (!s.isLive) s.score];
  if (lives.isEmpty || spoofs.isEmpty) {
    throw ArgumentError(
        'need both live and spoof captures (got ${lives.length} live, ${spoofs.length} spoof)');
  }
  return [
    for (final t in thresholds)
      TlPoint(
        threshold: t,
        far: spoofs.where((s) => s >= t).length / spoofs.length,
        frr: lives.where((s) => s < t).length / lives.length,
        nLive: lives.length,
        nSpoof: spoofs.length,
      ),
  ];
}

/// Recommends Tl from a sweep: with [maxFar], the lowest FRR among points
/// with FAR <= cap (lowest feasible Tl — raising Tl only trades FRR for
/// FAR); without it, the EER point (min |FAR−FRR|, ties prefer the stricter
/// higher Tl — security posture). Returns null only for an empty sweep.
TlPoint? recommendTl(List<TlPoint> points, {double? maxFar}) {
  if (points.isEmpty) return null;
  if (maxFar != null) {
    final feasible = [for (final p in points) if (p.far <= maxFar) p];
    if (feasible.isEmpty) return points.last; // strictest available
    feasible.sort((a, b) {
      final f = a.frr.compareTo(b.frr);
      return f != 0 ? f : a.threshold.compareTo(b.threshold);
    });
    return feasible.first;
  }
  final sorted = List<TlPoint>.of(points)
    ..sort((a, b) {
      final g = a.eerGap.compareTo(b.eerGap);
      return g != 0 ? g : b.threshold.compareTo(a.threshold);
    });
  return sorted.first;
}

/// Fixed-width FAR/FRR table for the calibration report / review paste.
String formatCalibrationTable(List<TlPoint> points) {
  final sb = StringBuffer('Tl     FAR    FRR    nLive  nSpoof\n');
  for (final p in points) {
    sb.writeln(
        '${p.threshold.toStringAsFixed(2)}   ${p.far.toStringAsFixed(3)}  ${p.frr.toStringAsFixed(3)}  ${p.nLive.toString().padLeft(5)}  ${p.nSpoof.toString().padLeft(6)}');
  }
  return sb.toString();
}

void main() {
  // SYNTHETIC fixtures — harness-math pins only, NOT model measurements.
  // 4 live:    0.90, 0.80, 0.60, 0.40
  // 4 spoof:   0.70, 0.50, 0.30, 0.10  (print/replay mix)
  const synthetic = [
    LabeledScore(score: 0.90, isLive: true, kind: 'live'),
    LabeledScore(score: 0.80, isLive: true, kind: 'live'),
    LabeledScore(score: 0.60, isLive: true, kind: 'live'),
    LabeledScore(score: 0.40, isLive: true, kind: 'live'),
    LabeledScore(score: 0.70, isLive: false, kind: 'print'),
    LabeledScore(score: 0.50, isLive: false, kind: 'replay'),
    LabeledScore(score: 0.30, isLive: false, kind: 'print'),
    LabeledScore(score: 0.10, isLive: false, kind: 'replay'),
  ];

  group('sweepTl (harness math, SYNTHETIC fixtures)', () {
    test('FAR/FRR at Tl=0.70 hand-computed', () {
      final pts = sweepTl(synthetic, [0.70]);
      expect(pts, hasLength(1));
      // Live >= 0.70: 0.90, 0.80 → 2/4 pass → FRR 0.50.
      expect(pts.single.frr, moreOrLessEquals(0.50));
      // Spoof >= 0.70: 0.70 → 1/4 pass → FAR 0.25.
      expect(pts.single.far, moreOrLessEquals(0.25));
      expect(pts.single.nLive, 4);
      expect(pts.single.nSpoof, 4);
    });

    test('raising Tl lowers FAR and raises FRR (monotone trade)', () {
      final pts = sweepTl(synthetic, [0.50, 0.70, 0.90]);
      expect(pts[0].far, greaterThanOrEqualTo(pts[1].far));
      expect(pts[1].far, greaterThanOrEqualTo(pts[2].far));
      expect(pts[0].frr, lessThanOrEqualTo(pts[1].frr));
      expect(pts[1].frr, lessThanOrEqualTo(pts[2].frr));
    });

    test('one-sided or bad input throws (collect both classes)', () {
      expect(
          () => sweepTl(
              [const LabeledScore(score: 0.9, isLive: true, kind: 'live')],
              [0.70]),
          throwsArgumentError);
      expect(() => sweepTl([], [0.70]), throwsArgumentError);
      expect(
          () => sweepTl(
              [
                const LabeledScore(
                    score: double.nan, isLive: true, kind: 'live'),
                const LabeledScore(
                    score: 0.1, isLive: false, kind: 'print'),
              ],
              [0.70]),
          throwsArgumentError);
    });
  });

  group('recommendTl (SYNTHETIC fixtures)', () {
    test('EER default picks the min |FAR-FRR| point', () {
      final pts = sweepTl(synthetic, defaultSweepThresholds());
      final rec = recommendTl(pts)!;
      var best = pts.first;
      for (final p in pts) {
        if (p.eerGap < best.eerGap ||
            (p.eerGap == best.eerGap && p.threshold > best.threshold)) {
          best = p;
        }
      }
      expect(rec.threshold, best.threshold);
    });

    test('maxFar cap picks lowest FRR within the cap', () {
      final pts = sweepTl(synthetic, defaultSweepThresholds());
      final rec = recommendTl(pts, maxFar: 0.0)!;
      expect(rec.far, lessThanOrEqualTo(0.0));
      // No spoof may pass: Tl must exceed the top spoof (0.70).
      expect(rec.threshold, greaterThan(0.70));
    });
  });

  group('calibration report', () {
    test('table renders Tl/FAR/FRR rows for review paste', () {
      final pts = sweepTl(synthetic, [0.60, 0.70]);
      final table = formatCalibrationTable(pts);
      expect(table, contains('Tl'));
      expect(table, contains('FAR'));
      expect(table, contains('FRR'));
      expect(table, contains('0.70'));
      // Sober footer lives in the file header (procedure + TODO), not in
      // pasted numbers: the table alone never claims a measurement.
    });
  });

  group('shipped operating point (FIELD-RELAXED Tl=0.70 pins)', () {
    test('kLivenessThreshold is the field-relaxed 0.70', () {
      // Flip ONLY via the TODO(sec-face) procedure above (threshold bump +
      // kLivenessVer bump + min_version floor, never silently).
      // 2026-09-13: relaxed 0.85→0.70 for mid-range field usability;
      // measured spoofs (≤0.31) still fail with ≥0.39 margin.
      expect(kLivenessThreshold, 0.70);
    });

    test('kLivenessVer unchanged until real data lands', () {
      expect(kLivenessVer.startsWith('liveness/'), isTrue);
      expect(kLivenessVer, contains('minifasnet-v2'));
    });
  });
}
