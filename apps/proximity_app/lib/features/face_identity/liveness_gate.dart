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
// Pre-processing ([minifasnetInputFromRgba]): face-box square crop (the
// box is detected ON the decoded frame via [InputImage.fromBitmap] —
// EXIF-blind by construction: no file path, no orientation flag, no
// header-dim mapping, so the crop and the box can never disagree; front
// cameras that store upright pixels with a stale rotate flag used to
// mis-crop background with confident spoof scores) + nearest-neighbour
// resize to 80x80 + BGR/255/NCHW packing. Fallback is the legacy
// centre-square crop when detection is unavailable/ambiguous (0 or >1
// faces, detector error / timeout, unparseable box) — same scorer + same
// Tl, never a pass, never a throw for the fallback itself (comment at the
// call-site).
//
// Honesty note (residuals, not immunity claims): the gate crops the face
// box with the 2.7x training-distribution margin ([kLivenessContextScale])
// but runs only the primary 2.7-scale model (upstream ensembles a second
// 4.0-scale model). FAR/FRR are UNMEASURED on Proximity captures (no
// Proximity ROC yet); Tl=0.85 ([kLivenessThreshold], protocol-owned) is the
// shipped STRICT operating point (print/replay incentive + cheap rescan
// recovery — see verify.dart), NOT a Proximity-measured EER.
// TODO(sec-face): measure a Proximity ROC (genuine dim/blurry stills vs
// print/replay spoofs) via liveness_calibration_test, then pin any new
// threshold with a [kLivenessVer] bump (re-face, key kept) + min_version
// floor. The adversarial drill + 2-phone relay (sec-verify) stay required.
// The gate FAILS CLOSED on unreadable stills, missing assets, and
// interpreter errors — never a pass, never a heuristic fallback.
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

/// Face-box context scale matching the training distribution: the vendored
/// weights are the `2.7_80x80` MiniFASNetV2 model, trained on face crops
/// with a 2.7x margin around the bbox centre (upstream preprocessing +
/// yakhyo `scale: 2.7` + HF card steps). The packer below expands the
/// squared box by this factor (clamped to the frame) so production scores
/// come from the distribution the weights expect — the tight-square crop
/// was the uncalibrated residual. Unit tests keep the tight path by
/// passing an explicit scale of 1.0; production always passes this.
const double kLivenessContextScale = 2.7;

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

/// Pure face-box helper (no native calls, unit-tested): squares an ML Kit
/// bbox ([faceLeft]/[faceTop]/[faceRight]/[faceBottom] in the SAME pixel
/// space as the frame) around its centre (max side) and clamps it to the
/// frame. [contextScale] expands the square to match the training
/// distribution ([kLivenessContextScale] = 2.7 in production; 1.0 = legacy
/// tight square, kept for unit-test stability). Returns null when the box
/// is unusable (empty, inverted, zero-area, or larger than the frame after
/// clamping, or <8px detail) — the caller falls back to the legacy
/// centre-square crop (same scorer + Tl, never a throw for the fallback
/// itself).
({int left, int top, int edge})? squareCropFromFaceBox({
  required int frameWidth,
  required int frameHeight,
  required int faceLeft,
  required int faceTop,
  required int faceRight,
  required int faceBottom,
}) {
  if (frameWidth <= 0 || frameHeight <= 0) return null;
  final l = faceLeft.clamp(0, frameWidth);
  final t = faceTop.clamp(0, frameHeight);
  final r = faceRight.clamp(0, frameWidth);
  final b = faceBottom.clamp(0, frameHeight);
  final w = r - l;
  final h = b - t;
  if (w <= 0 || h <= 0) return null;
  final tight = w > h ? w : h;
  if (tight < 8) return null;
  // Legacy tight square (scale 1.0): unit-test-stable contract. Production
  // passes [kLivenessContextScale] via [expandedSquareCropFromFaceBox] /
  // [minifasnetInputFromRgba] directly.
  return expandedSquareCropFromFaceBox(
    frameWidth: frameWidth,
    frameHeight: frameHeight,
    faceLeft: l,
    faceTop: t,
    faceRight: r,
    faceBottom: b,
    contextScale: 1.0,
  );
}

/// Pure expanded crop (no native calls, unit-tested): squares the box
/// around its centre, expands by [contextScale] ([kLivenessContextScale] in
/// production to match the 2.7_80x80 training distribution), then fits the
/// square inside the frame (shrinks to the frame when the context exceeds
/// it, centred as much as possible). Returns null only when no usable
/// square fits (frame smaller than 8px detail).
({int left, int top, int edge})? expandedSquareCropFromFaceBox({
  required int frameWidth,
  required int frameHeight,
  required int faceLeft,
  required int faceTop,
  required int faceRight,
  required int faceBottom,
  double contextScale = kLivenessContextScale,
}) {
  if (frameWidth <= 0 || frameHeight <= 0) return null;
  final l = faceLeft.clamp(0, frameWidth);
  final t = faceTop.clamp(0, frameHeight);
  final r = faceRight.clamp(0, frameWidth);
  final b = faceBottom.clamp(0, frameHeight);
  final w = r - l;
  final h = b - t;
  if (w <= 0 || h <= 0) return null;
  final tight = w > h ? w : h;
  if (tight < 8) return null;
  final scale = contextScale.isFinite && contextScale >= 1.0
      ? contextScale
      : 1.0;
  var edge = (tight * scale).round();
  if (edge < tight) edge = tight;
  if (scale == 1.0) {
    // Legacy tight contract (unit-test-stable): the square must fit as-is
    // or the caller falls back to the centre crop — never a silent shrink.
    if (edge > frameWidth || edge > frameHeight) return null;
  } else {
    // Production context expansion: fit the largest centred square when
    // the margin overflows the frame (same scorer + Tl either way).
    final maxEdge = frameWidth < frameHeight ? frameWidth : frameHeight;
    if (edge > maxEdge) edge = maxEdge;
  }
  if (edge < 8) return null;
  final cx = l + w ~/ 2;
  final cy = t + h ~/ 2;
  var sl = cx - edge ~/ 2;
  var st = cy - edge ~/ 2;
  if (sl < 0) sl = 0;
  if (st < 0) st = 0;
  if (sl + edge > frameWidth) sl = frameWidth - edge;
  if (st + edge > frameHeight) st = frameHeight - edge;
  if (sl < 0 || st < 0) return null;
  return (left: sl, top: st, edge: edge);
}

/// Pure box-mapping helper (no native calls, unit-tested): maps an ML Kit
/// bbox in ORIGINAL file pixels to DECODED frame pixels via the header
/// dims ([originalDimsFromBytes]) and the decoded size. Returns null on
/// any invalid geometry (the caller falls back to centre-square).
({int left, int top, int right, int bottom})? mapFaceBoxToFrame({
  required double origLeft,
  required double origTop,
  required double origRight,
  required double origBottom,
  required int origWidth,
  required int origHeight,
  required int frameWidth,
  required int frameHeight,
}) {
  if (origWidth <= 0 ||
      origHeight <= 0 ||
      frameWidth <= 0 ||
      frameHeight <= 0) {
    return null;
  }
  if (!(origRight > origLeft && origBottom > origTop)) return null;
  final sx = frameWidth / origWidth;
  final sy = frameHeight / origHeight;
  var l = (origLeft * sx).floor();
  var t = (origTop * sy).floor();
  var r = (origRight * sx).ceil();
  var b = (origBottom * sy).ceil();
  if (l < 0) l = 0;
  if (t < 0) t = 0;
  if (r > frameWidth) r = frameWidth;
  if (b > frameHeight) b = frameHeight;
  if (r <= l || b <= t) return null;
  return (left: l, top: t, right: r, bottom: b);
}

/// Pure header parser (no native calls, unit-tested): recovers the ORIGINAL
/// still dimensions from JPEG/PNG headers without a full decode, so the
/// native gate can map the ML Kit bbox (original space) onto the 160px
/// decoded frame. Returns null when the headers do not parse (the caller
/// falls back to centre-square — never a throw for the fallback itself).
/// Offline, no new dep. Bounds: PNG IHDR at 16..23; JPEG SOF0..SOF3 scan
/// capped at 256KB / stops at SOS (SOF always precedes SOS in valid JPEG).
({int width, int height})? originalDimsFromBytes(Uint8List bytes) {
  if (bytes.length < 32) return null;
  // PNG: 8-byte signature + IHDR chunk (width 16..19, height 20..23 BE).
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    if (bytes.length < 24) return null;
    if (bytes[12] != 0x49 ||
        bytes[13] != 0x48 ||
        bytes[14] != 0x44 ||
        bytes[15] != 0x52) {
      return null;
    }
    final w =
        (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final h =
        (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    if (w <= 0 || h <= 0 || w > 20000 || h > 20000) return null;
    return (width: w, height: h);
  }
  // JPEG: FF D8 ... SOF0 (C0)..SOF3 (C3) carry h/w.
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    final cap = bytes.length < 262144 ? bytes.length : 262144;
    var i = 2;
    while (i + 4 < cap) {
      if (bytes[i] != 0xFF) {
        i++;
        continue;
      }
      var j = i + 1;
      while (j < cap && bytes[j] == 0xFF) {
        j++;
      }
      if (j >= cap) return null;
      final marker = bytes[j];
      if (marker == 0xD9) return null; // EOI before SOF.
      // Standalone markers without a length field.
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
        i = j + 1;
        continue;
      }
      if (j + 2 >= cap) return null;
      final len = (bytes[j + 1] << 8) | bytes[j + 2];
      if (len < 2) return null;
      // SOS starts the entropy-coded scan — SOF always precedes it, so a
      // scan that reaches SOS without an SOF is unparseable for our use.
      if (marker == 0xDA) return null;
      if (marker >= 0xC0 && marker <= 0xC3) {
        if (j + 7 >= cap) return null;
        final h = (bytes[j + 4] << 8) | bytes[j + 5];
        final w = (bytes[j + 6] << 8) | bytes[j + 7];
        if (w <= 0 || h <= 0 || w > 20000 || h > 20000) return null;
        return (width: w, height: h);
      }
      i = j + len + 1;
    }
    return null;
  }
  return null;
}

/// Pure pre-processing (no native calls, unit-tested): packs decoded RGBA
/// bytes ([width]x[height], 4 bytes/px, row-major) into the model input —
/// a nested [1,3,80,80] list of doubles (NCHW, BGR order, pixels /255).
/// The crop is the squared face box ([faceBox] in the SAME pixel space as
/// the frame, via [expandedSquareCropFromFaceBox] with [contextScale])
/// when usable; otherwise the legacy centre square (fallback — same scorer
/// + Tl, documented in the file header). Resized to [kLivenessInputSize] by
/// nearest neighbour. [contextScale] defaults to 1.0 (tight, legacy unit
/// tests); production passes [kLivenessContextScale] (2.7, training
/// distribution). Throws [ArgumentError] on size mismatches (fail-closed
/// at the call-site).
List<List<List<List<double>>>> minifasnetInputFromRgba({
  required Uint8List rgba,
  required int width,
  required int height,
  ({int left, int top, int right, int bottom})? faceBox,
  double contextScale = 1.0,
}) {
  const size = kLivenessInputSize;
  if (width <= 0 || height <= 0) {
    throw ArgumentError('Bad frame dims ${width}x$height');
  }
  if (rgba.length != width * height * 4) {
    throw ArgumentError(
        'RGBA length ${rgba.length} != ${width}x$height frame');
  }
  // Face-box crop when usable, else the legacy centre-square fallback.
  var edge = width < height ? width : height;
  var ox = (width - edge) ~/ 2;
  var oy = (height - edge) ~/ 2;
  if (faceBox != null) {
    final squared = expandedSquareCropFromFaceBox(
      frameWidth: width,
      frameHeight: height,
      faceLeft: faceBox.left,
      faceTop: faceBox.top,
      faceRight: faceBox.right,
      faceBottom: faceBox.bottom,
      contextScale: contextScale,
    );
    if (squared != null) {
      ox = squared.left;
      oy = squared.top;
      edge = squared.edge;
    }
    // Null squared → centre-square fallback above (same scorer + Tl;
    // the Tl gate stays the decider, never a throw for the fallback).
  }
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
