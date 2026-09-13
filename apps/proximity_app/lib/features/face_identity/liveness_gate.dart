// LivenessGate: the ONE narrow on-device anti-spoof interface
// (PROXIMITY_SECURITY.md §4, F4 fix). Everything anti-spoof in the app goes
// through here — enrollment active challenges + marking passive check. No
// images ever leave the device: the gate owns its classifier; the app only
// sees {score, ver} and binds them into Sig_s via the extended face ticket
// (ProxCrypto.faceTicketHash with livenessScore/livenessVer — the host
// re-checks score>=Tl + the liveness allowlist, so transplanting a score
// across tickets fails as bad-sig/liveness-unbound, never a silent pass).
//
// Flows (spec §4):
//   enroll  = ACTIVE blink+smile walked in per-session Fisher-Yates
//             shuffled order ([EnrollLivenessPlan], offline — the order is
//             unpredictable, so a pre-recorded clip cannot match it) +
//             PASSIVE centre-still ([detectPassive] on the centre capture,
//             fail-closed, the DECIDER).
//   marking = PASSIVE only on the single check still (~1s budget, no
//             prompts — the holder just holds still).
//
// Honesty note on the active walk: each newly accepted pose bucket
// acknowledges the current challenge (time-separated, pose-validated
// captures — sustained live presence across the walked order). This is
// NOT measured blink/smile detection: the stills path has no eye/smile
// classifier, and sparse stills cannot catch 200ms blinks (see
// PROXIMITY_DESIGN.md §4 — stills heuristics were tried and removed).
// The passive MiniFASNetV2 centre-still gate above remains the enroll
// decider; the walk binds presence + order, never a vitality verdict.
//
// Backend: real passive MiniFASNetV2 classifier (sec-liveness PRIMARY
// rung, audit 2026-09-12 C4 fix). The vendored weights are the
// `2.7_80x80_MiniFASNetV2` anti-spoof model from minivision-ai's
// Silent-Face-Anti-Spoofing (Apache-2.0), converted to TFLite
// (litert-community build), shipped at [kLivenessModelAsset] and run via
// `tflite_flutter` (see liveness_gate_native.dart). The pipeline tag
// [kLivenessVer] pins WHICH scorer produced the score (model + weights
// hash8); a scorer swap ships as a new tag and forces re-face via the
// stale-pipeline check (key kept) — same versioning contract as
// [kFaceVerifierVer].
//
// Model contract (verified against the vendored file, 2026-09-12):
//   input  [1,3,80,80] float32 NCHW, BGR order, pixels /255 (face crop).
//   output [1,3] float32 softmax [spoof-print, LIVE, spoof-replay].
//   score  output[1] ([kMinifasnetLiveIndex]) via [liveScoreFromProbs].
// Pre-processing ([minifasnetInputFromRgba]): centre-square crop of the
// still + nearest-neighbour resize to 80x80 + BGR/255/NCHW packing.
//
// Honesty note (residuals, not immunity claims): the gate crops the whole
// still's centre — it does NOT run a face detector for the 2.7x face-box
// crop the weights were trained on, and it runs only the primary 2.7-scale
// model (upstream ensembles a second 4.0-scale model). FAR/FRR are
// UNMEASURED on Proximity captures (no Proximity ROC yet); the host
// threshold Tl=0.70 ([kLivenessThreshold], protocol-owned) applies to the
// OUTPUT. The adversarial drill + 2-phone relay (sec-verify) stay
// required. The gate FAILS CLOSED on unreadable stills, missing assets,
// and interpreter errors — never a pass, never a heuristic fallback.
//
// L1 mobile gate: [detectPassive] calls [requireMobileFace] first —
// desktop/web fail closed (records-only stub below throws before any
// decode; SK never signs without a real holder check).
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'liveness_gate_native.dart'
    if (dart.library.html) 'liveness_gate_stub.dart';

/// Opaque liveness pipeline tag stored on the ticket and bound into every
/// Sig_s ticket. Format: `liveness/<model>+<weightsHash8>` (mirrors the
/// `face_verification/<pkgVer>+<assetHash8>` shape). The host allowlists on
/// the `liveness/` prefix; a stricter course pins the full tag. Bumping the
/// tag (new weights) invalidates old tickets — re-face only, key kept.
///
/// `4ff758f4` = first 8 hex of the SHA-256 of the vendored TFLite file
/// (see [kLivenessModelAsset]).
const kLivenessVer = 'liveness/minifasnet-v2-27-80x80+4ff758f4';

/// Bundled anti-spoof weights (declared via `assets/models/` in pubspec —
/// no per-file entry needed). MiniFASNetV2 `2.7_80x80`, TFLite, 1.85MB.
const kLivenessModelAsset =
    'assets/models/silentface-minifasnetv2-27-80x80.tflite';

/// Model input edge (square): 80x80.
const kLivenessInputSize = 80;

/// Output index of the LIVE class in the model's [1,3] softmax
/// ([spoof-print, LIVE, spoof-replay]).
const kMinifasnetLiveIndex = 1;

/// Active enroll challenges: blink + smile, prompted in shuffled order.
/// Passive only for marking (no prompts there — single still, ~1s).
enum LivenessAction { blink, smile }

/// Fisher-Yates shuffle of the enroll active challenges (offline, no
/// network). A seeded [Random] drives deterministic unit tests; production
/// passes none (Random.secure). The order is the anti-replay property: a
/// pre-recorded clip cannot predict which prompt comes first.
List<LivenessAction> shuffledActiveChallenges({Random? rng}) {
  final r = rng ?? Random.secure();
  final list = [...LivenessAction.values];
  for (var i = list.length - 1; i > 0; i--) {
    final k = r.nextInt(i + 1);
    final t = list[i];
    list[i] = list[k];
    list[k] = t;
  }
  return list;
}

/// Pure post-processing (no native calls, unit-tested): the model's [1,3]
/// softmax [spoof-print, LIVE, spoof-replay] maps to one 0..1 vitality
/// score on the same milli scale as the face score. The score IS the LIVE
/// class probability ([kMinifasnetLiveIndex]) — no re-weighting, no
/// calibration fudge. Throws [ArgumentError] on any other shape or
/// non-finite input (fail-closed at the call-site, never a pass).
double liveScoreFromProbs(List<double> probs) {
  if (probs.length != 3 || probs.any((p) => !p.isFinite)) {
    throw ArgumentError(
        'MiniFASNet output must be 3 finite softmax probs, got $probs');
  }
  return probs[kMinifasnetLiveIndex].clamp(0.0, 1.0);
}

/// Pure pre-processing (no native calls, unit-tested): packs decoded RGBA
/// bytes ([width]x[height], 4 bytes/px, row-major) into the model input —
/// a nested [1,3,80,80] list of doubles (NCHW, BGR order, pixels /255).
/// The crop is the frame's centre square (see the file header: NOT a
/// face-detector crop — documented residual), resized to
/// [kLivenessInputSize] by nearest neighbour. Throws [ArgumentError] on
/// size mismatches (fail-closed at the call-site).
List<List<List<List<double>>>> minifasnetInputFromRgba({
  required Uint8List rgba,
  required int width,
  required int height,
}) {
  const size = kLivenessInputSize;
  if (width <= 0 || height <= 0) {
    throw ArgumentError('Bad frame dims ${width}x$height');
  }
  if (rgba.length != width * height * 4) {
    throw ArgumentError(
        'RGBA length ${rgba.length} != ${width}x$height frame');
  }
  // Centre-square crop box.
  final edge = width < height ? width : height;
  final ox = (width - edge) ~/ 2;
  final oy = (height - edge) ~/ 2;
  // [c][y][x] accumulator in BGR order.
  final planes = List.generate(
      3, (_) => List.generate(size, (_) => List.filled(size, 0.0)));
  for (var y = 0; y < size; y++) {
    final sy = oy + (y * edge ~/ size);
    for (var x = 0; x < size; x++) {
      final sx = ox + (x * edge ~/ size);
      final o = (sy * width + sx) * 4;
      // RGBA bytes → BGR channels, /255.
      planes[0][y][x] = rgba[o + 2] / 255.0;
      planes[1][y][x] = rgba[o + 1] / 255.0;
      planes[2][y][x] = rgba[o] / 255.0;
    }
  }
  return [planes];
}

/// Result of one passive anti-spoof pass: vitality score + pipeline tag.
/// `ver` is [kLivenessVer] on real runs (the ticket binds it); fakes in
/// tests pin their own tag (allowlist-carrying tests set full tags).
class LivenessResult {
  final double score;
  final String ver;
  const LivenessResult({required this.score, required this.ver});
}

/// Narrow anti-spoof interface (one file, no wrappers).
abstract class LivenessGate {
  /// Passive anti-spoof on one still file (marking hot path, ~1s budget;
  /// enroll centre-still). Returns {score, ver}. Throws StateError when
  /// the still is unreadable/unsupported or the platform cannot run the
  /// classifier — fail-closed (callers map throws to inconclusive/rescan,
  /// never a pass, never a throw past them).
  Future<LivenessResult> detectPassive(String imagePath);
}

/// Per-session active-challenge walk for enrollment (security §4, pure,
/// unit-tested, offline). One plan per capture session: the blink+smile
/// order is [shuffledActiveChallenges] (Fisher-Yates — unpredictable per
/// session, the anti-replay property), and each newly accepted pose
/// bucket acknowledges the current challenge, binding sustained live
/// presence across the walked order (fills arrive on ~600ms beats, so
/// consecutive acknowledgments are time-separated captures, never one
/// frozen frame). This is an order/presence record, NOT a vitality
/// verdict: completion is not measured blink/smile detection (no
/// eye/smile classifier in the stills path; sparse stills cannot catch
/// 200ms blinks), and the save gate stays the passive centre-still
/// classifier + the 5 pose-validated buckets — the plan never passes or
/// fails a holder by itself.
class EnrollLivenessPlan {
  /// Shuffled walk order for this session ([LivenessAction.blink] +
  /// [LivenessAction.smile] in unpredictable order).
  final List<LivenessAction> order;
  int _acknowledged = 0;

  EnrollLivenessPlan._(this.order);

  /// Fresh per-session walk. A seeded [Random] drives deterministic unit
  /// tests; production passes none (Random.secure via
  /// [shuffledActiveChallenges]).
  factory EnrollLivenessPlan.fresh({Random? rng}) =>
      EnrollLivenessPlan._(shuffledActiveChallenges(rng: rng));

  /// Next uncompleted challenge, null once the walk is complete.
  LivenessAction? get current =>
      _acknowledged < order.length ? order[_acknowledged] : null;

  /// Challenges acknowledged so far (0..2).
  int get acknowledged => _acknowledged;

  /// True once both challenges have been walked.
  bool get isComplete => _acknowledged >= order.length;

  /// Acknowledges the current challenge (called once per newly accepted
  /// bucket fill). No-op once complete — extra fills never over-advance.
  void acknowledgeFill() {
    if (!isComplete) _acknowledged++;
  }
}

/// Test-only fake (same role FakeFaceVerifier plays): scripted score/ver,
/// records calls, optional fail-closed throw. Never shipped (DI wires the
/// platform gate / stub).
class FakeLivenessGate implements LivenessGate {
  double score;
  String ver;
  final List<String> calls = [];

  /// When true, [detectPassive] throws StateError (unreadable-still path).
  bool throwOnDetect;
  FakeLivenessGate({
    this.score = 0.92,
    this.ver = kLivenessVer,
    this.throwOnDetect = false,
  });

  @override
  Future<LivenessResult> detectPassive(String imagePath) async {
    calls.add(imagePath);
    if (throwOnDetect) {
      throw StateError(
          'Liveness check did not read clearly — adjust light and try again.');
    }
    return LivenessResult(score: score, ver: ver);
  }
}

/// DI seam: override with the platform gate ([HeuristicLivenessGate],
/// resolving to the web fail-closed stub on records builds via the
/// conditional export above — same pattern as faceVerifierProvider) or
/// with [FakeLivenessGate] in tests. [RealStudentDriver] and
/// [EnrollmentController] default-construct the platform gate themselves
/// (same copy idiom), so production never reads this provider without an
/// override — it exists for widget tests and future main wiring. The
/// gate class keeps its historical name for that shared wiring — the
/// scorer inside is the MiniFASNetV2 TFLite model above, not a heuristic.
final livenessGateProvider = Provider<LivenessGate>((ref) {
  throw UnimplementedError('Override in main / tests');
});
