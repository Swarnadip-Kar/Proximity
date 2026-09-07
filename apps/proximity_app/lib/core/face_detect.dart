// BlazeFace short-range face detection + canonical alignment, all on-device.
//
// Pipeline (mirrors MediaPipe's factory graph, verified numerically against
// it in tmp_blaze/): letterbox still → 128×128 RGB [-1,1] → TFLite
// (assets/models/blaze_face_short_range.tflite, 224KB, Apache-2.0) → SSD
// decode with fixed-size anchors → sigmoid scores → weighted NMS → best
// face first. Keypoints feed similarity-transform alignment to the
// EdgeFace-native 112×112 canonical frame.
//
// Verified 2026-09-05: decode reproduces factory geometry on real portraits
// (Lena: single tight box, keypoints on features); alignment reaches 0.94
// cosine parity with the SCRFD-based reference alignment on the same photo;
// 0.6ms TFLite inference (desktop CPU; ~3ms mobile per Google's Pixel 6
// numbers). Model: https://github.com/google-ai-edge/mediapipe (face
// detector short-range), Apache License 2.0.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

export 'face_detect_fake.dart';

/// BlazeFace input resolution.
const blazeInputSize = 128;

/// Detection score floor (MediaPipe default min_detection_confidence).
const kBlazeMinScore = 0.5;

/// NMS overlap threshold (MediaPipe min_suppression_threshold, WEIGHTED).
const kBlazeNmsIou = 0.3;

/// One decoded face: normalized box + 6 normalized keypoints in 128-space.
/// Keypoint order (image order): left eye, right eye, nose tip, mouth
/// center, left tragion, right tragion.
class FaceDetection {
  /// ymin, xmin, ymax, ymax in 128-space (may slightly exceed 0..1).
  final List<double> box;
  final List<Offset> keypoints;
  final double score;
  const FaceDetection(
      {required this.box, required this.keypoints, required this.score});
}

abstract class FaceDetector {
  Future<List<FaceDetection>> detect(Uint8List jpegBytes);
  Future<void> load();
  bool get isLoaded;
  void close();
}

/// SSD anchors mirroring MediaPipe's SsdAnchorsCalculator with
/// fixed_anchor_size (w/h are 1.0; only centers vary): strides 8/16/16/16
/// on the 128 grid, 0.5 offset, aspect box + interpolated box interleaved
/// per cell → 896 entries.
List<List<double>> blazeAnchors() {
  const strides = [8, 16, 16, 16];
  final anchors = <List<double>>[];
  for (final s in strides) {
    final grid = blazeInputSize ~/ s;
    for (var y = 0; y < grid; y++) {
      for (var x = 0; x < grid; x++) {
        final cx = (x + 0.5) / grid;
        final cy = (y + 0.5) / grid;
        anchors.add([cx, cy, 1.0, 1.0]);
        anchors.add([cx, cy, 1.0, 1.0]);
      }
    }
  }
  return anchors;
}

/// One raw BlazeFace decoding: box [ymin,xmin,ymax,xmax] + 12 keypoint
/// values in 128-space, plus the sigmoid score. See [decodeBlaze].
class BlazeRawDet {
  final List<double> v;
  final double score;
  BlazeRawDet(this.v, this.score);
}

/// Decode raw BlazeFace tensors (no exponential on box size, reversed
/// [ymin,xmin,ymax,xmax] order, sigmoid scores clipped at ±100).
/// [rawBoxes] is 896×16, [rawScores] 896×1; returns thresholded detections.
List<BlazeRawDet> decodeBlaze(
    List<List<double>> rawBoxes, List<double> rawScores) {
  const scale = 128.0;
  const clip = 100.0;
  final anchors = blazeAnchors();
  final out = <BlazeRawDet>[];
  for (var i = 0; i < 896; i++) {
    final rb = rawBoxes[i];
    final clipped = rawScores[i].clamp(-clip, clip);
    final score = 1.0 / (1.0 + math.exp(-clipped));
    if (score < kBlazeMinScore) continue;
    final ax = anchors[i][0], ay = anchors[i][1];
    final v = List.filled(16, 0.0);
    final w = rb[2] / scale, h = rb[3] / scale;
    final xc = rb[0] / scale + ax, yc = rb[1] / scale + ay;
    v[0] = yc - h / 2;
    v[1] = xc - w / 2;
    v[2] = yc + h / 2;
    v[3] = xc + w / 2;
    for (var k = 0; k < 6; k++) {
      v[4 + k * 2] = rb[4 + k * 2] / scale + ax;
      v[5 + k * 2] = rb[5 + k * 2] / scale + ay;
    }
    out.add(BlazeRawDet(v, score));
  }
  return out;
}

double _iou(List<double> a, List<double> b) {
  final iy0 = math.max(a[0], b[0]), ix0 = math.max(a[1], b[1]);
  final iy1 = math.min(a[2], b[2]), ix1 = math.min(a[3], b[3]);
  final inter = math.max(0.0, iy1 - iy0) * math.max(0.0, ix1 - ix0);
  final ua = (a[2] - a[0]) * (a[3] - a[1]);
  final ub = (b[2] - b[0]) * (b[3] - b[1]);
  final union = ua + ub - inter;
  return union <= 0 ? 0.0 : inter / union;
}

/// Weighted (blended) NMS: overlapping detections merge into a
/// score-weighted mean instead of winner-takes-all (less jitter).
List<FaceDetection> blazeNms(List<BlazeRawDet> dets) {
  final remaining = List<BlazeRawDet>.from(dets)
    ..sort((a, b) => b.score.compareTo(a.score));
  final out = <FaceDetection>[];
  while (remaining.isNotEmpty) {
    final first = remaining.removeAt(0);
    final overlapping = <BlazeRawDet>[first];
    remaining.removeWhere((d) {
      if (_iou(first.v, d.v) > kBlazeNmsIou) {
        overlapping.add(d);
        return true;
      }
      return false;
    });
    var coords = first.v;
    var score = first.score;
    if (overlapping.length > 1) {
      var wsum = 0.0;
      final acc = List.filled(16, 0.0);
      for (final d in overlapping) {
        wsum += d.score;
        for (var i = 0; i < 16; i++) {
          acc[i] += d.v[i] * d.score;
        }
      }
      coords = [for (final x in acc) x / wsum];
      score = wsum / overlapping.length;
    }
    out.add(FaceDetection(
      box: coords.sublist(0, 4),
      keypoints: [
        for (var k = 0; k < 6; k++)
          Offset(coords[4 + k * 2], coords[5 + k * 2])
      ],
      score: score,
    ));
  }
  return out;
}

/// Letterbox: pad the still symmetrically with black to a square (official
/// MediaPipe preprocessing keeps aspect ratio; no content is cropped).
/// Returns the square side length; use [letterboxSquare] for pixels.
int letterboxSide(img.Image still) =>
    math.max(still.width, still.height);

img.Image letterboxSquare(img.Image still) {
  final s = letterboxSide(still);
  final sq = img.Image(width: s, height: s);
  img.compositeImage(sq, still,
      dstX: (s - still.width) ~/ 2, dstY: (s - still.height) ~/ 2);
  return sq;
}


/// Canonical ArcFace 112×112 template for [eyeL, eyeR, nose, mouthCenter]
/// (image order: pts[0] is the image-left eye).
///
/// Audited against the InsightFace 5-point standard
/// (38.29/51.69, 73.53/51.50, 56.02/71.74 + two mouth corners ≈
/// 41.5/70.7×92.3): eyes and nose match exactly; the 4th point is the
/// midpoint of the two mouth corners. The reduction 5→4 is forced —
/// BlazeFace reports a single mouth CENTER, not corners — and the midpoint
/// is the consistent reduction: same least-squares similarity, same
/// canonical frame. End-to-end validated (genuine 0.80 vs impostor ~0.0).
///
/// BlazeFace keypoint order (upstream docs + model card): subject-right
/// eye first = IMAGE-left on unmirrored stills (front-camera takePicture
/// stills are unmirrored on Android/iOS; only the live preview is
/// mirrored). Fit-residual check agreed (2–5px vs 20px swapped).
const alignTemplate = [
  Offset(38.29, 51.69),
  Offset(73.53, 51.69),
  Offset(56.02, 71.74),
  Offset(56.00, 92.36),
];

/// Least-squares similarity (scale+rotation+translation, Horn closed form)
/// mapping [src] onto [dst]. Returns [a, b, tx, ty] with
/// dx = a·sx − b·sy + tx, dy = b·sx + a·sy + ty.
List<double> similarityTransform(List<Offset> src, List<Offset> dst) {
  assert(src.length == dst.length && src.isNotEmpty);
  var smx = 0.0, smy = 0.0, dmx = 0.0, dmy = 0.0;
  for (var i = 0; i < src.length; i++) {
    smx += src[i].dx;
    smy += src[i].dy;
    dmx += dst[i].dx;
    dmy += dst[i].dy;
  }
  smx /= src.length;
  smy /= src.length;
  dmx /= src.length;
  dmy /= src.length;
  var variance = 0.0, cov = 0.0, cross = 0.0;
  for (var i = 0; i < src.length; i++) {
    final sx = src[i].dx - smx, sy = src[i].dy - smy;
    final dx = dst[i].dx - dmx, dy = dst[i].dy - dmy;
    variance += sx * sx + sy * sy;
    cov += sx * dx + sy * dy;
    cross += sx * dy - sy * dx;
  }
  final a = cov / variance, b = cross / variance;
  return [a, b, dmx - (a * smx - b * smy), dmy - (b * smx + a * smy)];
}

/// Warp the letterboxed [square] to the canonical 112×112 frame using the
/// detection keypoints (128-space normalized): eyes, nose, mouth center.
img.Image alignFace(img.Image square, FaceDetection det) {
  const out = 112;
  final s = square.width.toDouble();
  final src = [
    for (var k = 0; k < 4; k++)
      Offset(det.keypoints[k].dx * s, det.keypoints[k].dy * s)
  ];
  final t = similarityTransform(src, alignTemplate);
  final a = t[0], b = t[1], tx = t[2], ty = t[3];
  // Inverse map (output px → source px). Forward is M = [[a,-b],[b,a]] +
  // [tx,ty], so M^-1 = (1/det)·[[a,b],[-b,a]]:
  //   sx = ( a·(x-tx) + b·(y-ty)) / det
  //   sy = (-b·(x-tx) + a·(y-ty)) / det
  // NOTE: the off-diagonal signs are load-bearing. Flipping them is
  // invisible on perfectly frontal faces (b≈0) but shifts tilted faces by
  // tens of pixels, silently destroying identity separation (measured
  // 2026-09-05: genuine 0.21 vs impostor 0.56 with flipped signs, genuine
  // 0.80 vs impostor ~0.0 fixed — see blazeface_test warp test).
  final det2 = a * a + b * b;
  final ia = a / det2, ib = b / det2;
  final itx = -(ia * tx + ib * ty), ity = ib * tx - ia * ty;
  final dst = img.Image(width: out, height: out);
  final w = square.width, h = square.height;
  for (var y = 0; y < out; y++) {
    for (var x = 0; x < out; x++) {
      var sx = ia * x + ib * y + itx;
      var sy = -ib * x + ia * y + ity;
      sx = sx.clamp(0.0, (w - 1).toDouble());
      sy = sy.clamp(0.0, (h - 1).toDouble());
      final x0 = sx.floor(), y0 = sy.floor();
      final x1 = math.min(x0 + 1, w - 1), y1 = math.min(y0 + 1, h - 1);
      final fx = sx - x0, fy = sy - y0;
      final p00 = square.getPixel(x0, y0);
      final p10 = square.getPixel(x1, y0);
      final p01 = square.getPixel(x0, y1);
      final p11 = square.getPixel(x1, y1);
      dst.setPixel(
          x,
          y,
          img.ColorRgb8(
            _bilinear(p00.r.toDouble(), p10.r.toDouble(), p01.r.toDouble(),
                p11.r.toDouble(), fx, fy),
            _bilinear(p00.g.toDouble(), p10.g.toDouble(), p01.g.toDouble(),
                p11.g.toDouble(), fx, fy),
            _bilinear(p00.b.toDouble(), p10.b.toDouble(), p01.b.toDouble(),
                p11.b.toDouble(), fx, fy),
          ));
    }
  }
  return dst;
}

int _bilinear(
    double c00, double c10, double c01, double c11, double fx, double fy) {
  final v = c00 * (1 - fx) * (1 - fy) +
      c10 * fx * (1 - fy) +
      c01 * (1 - fx) * fy +
      c11 * fx * fy;
  return v.round().clamp(0, 255);
}

/// Geometric plausibility of one detection: eyes above nose above mouth,
/// roughly level eyes, sane eye distance, keypoints near the unit square.
/// Rejects detector-slip garbage for free (no attempt consumed).
bool saneGeometry(FaceDetection det) {
  final k = det.keypoints;
  final eyeL = k[0], eyeR = k[1], nose = k[2], mouth = k[3];
  final eyeDist =
      math.sqrt(math.pow(eyeR.dx - eyeL.dx, 2) + math.pow(eyeR.dy - eyeL.dy, 2));
  if (eyeDist < 0.05 || eyeDist > 0.7) return false;
  final slope =
      (eyeR.dy - eyeL.dy).abs() / math.max(eyeDist, 1e-6);
  if (slope > 0.5) return false; // eyes must be roughly level
  final eyeMidY = (eyeL.dy + eyeR.dy) / 2;
  if (!(eyeMidY < nose.dy && nose.dy < mouth.dy)) return false;
  if (mouth.dy - eyeMidY > 4 * eyeDist) return false;
  for (final p in k) {
    if (p.dx < -0.1 || p.dx > 1.1 || p.dy < -0.1 || p.dy > 1.1) return false;
  }
  return true;
}

/// Variance-of-Laplacian sharpness over a downscaled (~160px) gray copy.
/// Garbage filter, not an identity signal: strong motion streaks and flat
/// frames score < 30; soft-but-usable faces score 50+. Null when the bytes
/// don't decode (fail-closed upstream). Same math as the Python grounding
/// (0.299/0.587/0.114 gray, 4-neighbor Laplacian, population variance).
double? estimateSharpness(List<int> bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(Uint8List.fromList(bytes));
  } catch (_) {
    return null;
  }
  if (decoded == null || decoded.width < 3 || decoded.height < 3) return null;
  return sharpnessOf(decoded);
}

/// [estimateSharpness] on an already-decoded still (one decode per frame).
double sharpnessOf(img.Image still) {
  final scale = 160 / math.max(still.width, still.height);
  final w = math.max(3, (still.width * scale).round());
  final h = math.max(3, (still.height * scale).round());
  final small = img.copyResize(still, width: w, height: h);
  var sum = 0.0, sum2 = 0.0;
  var n = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      double g(int px, int py) {
        final p = small.getPixel(px, py);
        return 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      }

      final l = g(x - 1, y) + g(x + 1, y) + g(x, y - 1) + g(x, y + 1) -
          4 * g(x, y);
      sum += l;
      sum2 += l * l;
      n++;
    }
  }
  if (n == 0) return 0;
  final mean = sum / n;
  return (sum2 / n - mean * mean).clamp(0.0, double.infinity);
}

/// Below this sharpness a frame is motion mush, not a face to match.
/// Measured: soft-but-usable portraits 50+, strong blur < 25, flat 0.
/// Tune per pilot hall lighting.
const kMinSharpness = 30.0;

/// Scan pose target: which head direction counts toward acceptance.
/// `any` (marking scans) disables pose scoping entirely.
enum PoseTarget { any, front, left, right, up, down }

/// Yaw proxy from detection keypoints: nose offset from the eye midpoint,
/// in eye widths. The standard lightweight landmark-based pose signal
/// (ISO 29794-5 lists landmark-based pose as a core quality component;
/// full solvePnP needs a 3D model + intrinsics and buys nothing for
/// coarse left/front/right bins). No new model, ~10 flops.
///
/// Sign (unmirrored still coords): the holder turning to THEIR left gives
/// a POSITIVE value. Chain: turn-left ⟹ nose toward world −X (facing −Z,
/// left = −X) ⟹ appears display-right in the unmirrored still (camera
/// looks along +Z, so display-right = −X) ⟹ nose pixel-x grows ⟹ yaw > 0.
/// Independently consistent with the working pipeline (subject-right eye
/// = image-left is proven by genuine 0.80 — mirrored stills would swap
/// the eyes and tank it). In the MIRRORED live preview the same motion
/// appears as nose-toward-screen-left, so left-slot arrows point ←.
/// Residual risk: if some device mirrored its stills, left/right prompts
/// swap — template diversity is unaffected (still two opposite poses),
/// and side slots accept almost everything anyway (no minima), so no
/// loop is possible either way.
///
/// Measured: frontal portraits ±0.12 max (5 samples), Pointing'04 lab
/// ±15° reads 0.09–0.25, ±30° reads ±0.40, ±45° reads 0.58–0.69,
/// ±60°+ reads 0.85+ (already sanity-rejected via eye distance).
double poseYawOf(FaceDetection det) {
  final k = det.keypoints;
  final eyeMidX = (k[0].dx + k[1].dx) / 2;
  final eyeDist = (k[1].dx - k[0].dx).abs();
  if (eyeDist < 1e-6) return 0;
  return (k[2].dx - eyeMidX) / eyeDist;
}

/// |yaw| at or below this counts as frontal. Covers measured frontal
/// asymmetry spread (±0.12 across 5 portraits + lab frontal) with margin;
/// still near-frontal, so front-slot frames match well.
const kPoseFrontMax = 0.18;

/// Minimum |yaw| for a side slot to count the frame: the turn must be
/// real, not asymmetry. Calibrated on Pointing'04 (same person, lab):
/// frontal ≈ ±0.12 max, ±15° reads 0.09–0.25, ±30° reads ±0.40.
/// 0.18 sits above every frontal sample with margin yet below a clear
/// turn — slight turns converge after one "a bit more" nudge, and random
/// stills can no longer complete a turn slot.
const kPoseSideMin = 0.18;

/// |yaw| beyond this is profile mush (foreshortened, keypoints noisy):
/// held out with an "ease back" prompt. ±30° reads ±0.40 (counts), ±45°
/// reads 0.58–0.69 (counts), ±60°+ reads 0.85+ (held out; usually fails
/// detection/sanity first anyway).
const kPoseSideMax = 0.70;

/// Vertical pitch proxy from detection keypoints: nose height inside the
/// eye→mouth segment, `(noseY − eyeMidY) / (mouthY − eyeMidY)`. Frontal
/// portraits sit ≈0.54 (eyeMidY 0.42, nose 0.55, mouth 0.66); chin-up
/// (Top slot) pulls the nose toward the eyes (ratio drops), chin-down
/// (Bottom slot) pushes it toward the mouth (ratio rises). Distance
/// invariant (pure ratio), ~10 flops, no depth model — the same
/// landmark-proxy philosophy as [poseYawOf]. Heuristic (face shape
/// varies), so gates below stay wide with overlap at the boundaries
/// (no dead zone where a frame counts nowhere).
double posePitchOf(FaceDetection det) {
  final k = det.keypoints;
  final eyeMidY = (k[0].dy + k[1].dy) / 2;
  final denom = (k[3].dy - eyeMidY);
  if (denom.abs() < 1e-6) return 0.54;
  return (k[2].dy - eyeMidY) / denom;
}

/// Frontal pitch band. Measured frontal ≈0.54; the band is deliberately
/// wide (face-shape spread) — up/down slots exclude it (see below), so a
/// frontal stare can never complete Top/Bottom.
const kPitchFrontMin = 0.46;
const kPitchFrontMax = 0.62;

/// Top slot (chin up) counts at or below this. Frontal 0.54 is held out
/// with an "a bit more" nudge; slight tilts converge in one nudge.
/// Deliberately slight-tilt friendly: pitched faces score lower AND blur
/// more (head moves to tilt), so the gate asks for the SMALLEST tilt that
/// still excludes a dead-center stare — never an exaggerated pose.
/// Overlaps the frontal band edge so no frame counts nowhere. A
/// near-frontal frame occasionally clearing Top is HARMLESS (same person,
/// same session — pose diversity is carried by the side slots, and the
/// agreement checks reject strangers at ~0.0 either way). Hold the phone
/// at eye level: a low phone mimics pitch and fights this gate
/// (camera-height confound — no 2D landmark proxy can separate head pitch
/// from camera height; the eye-level instruction is the fix).
const kPitchUpMax = 0.53;

/// Bottom slot (chin down) counts at or above this. Mirrors [kPitchUpMax].
const kPitchDownMin = 0.55;

/// True when [yaw] may count toward [target]. Front and marking scans
/// are ungated beyond the obvious; side slots REQUIRE a real turn in
/// the slot's direction — frontal or opposite frames are held out with
/// directional guidance (never an error, never an attempt; the streak
/// simply waits). Every hold-out is satisfiable, so no loop is possible.
///
/// Up/down slots use the pitch proxy [posePitchOf]: frontal frames are
/// held out there exactly like frontal frames are held out of side slots,
/// so staring straight can never complete Top/Bottom.
bool poseOkFor(PoseTarget target, double yaw, [double? pitch]) => switch (target) {
      PoseTarget.any => true,
      PoseTarget.front => yaw.abs() <= kPoseFrontMax,
      PoseTarget.left =>
        yaw >= kPoseSideMin && yaw <= kPoseSideMax,
      PoseTarget.right =>
        yaw <= -kPoseSideMin && yaw >= -kPoseSideMax,
      PoseTarget.up => pitch != null && pitch <= kPitchUpMax,
      PoseTarget.down => pitch != null && pitch >= kPitchDownMin,
    };

/// Relative pitch margin for the personalized up/down gates below: the
/// tilt must move the proxy this far from the holder's OWN frontal
/// reading. Keypoint jitter across stills is ~±0.01 in ratio units, so
/// 0.02 demands a real-but-small tilt with margin while staying sharp and
/// matchable (pitched faces score lower AND blur more — an exaggerated
/// pose would fail the 0.70 pair check downstream).
const kPitchRelDelta = 0.02;

/// Up/down gate with a personalized frontal reference (median pitch of
/// the holder's own front-section frames, same lighting/session). Face
/// shape spreads the absolute frontal ratio (≈0.46–0.62 band): for a
/// long-faced holder one direction then demands an extreme tilt that
/// blurs and degrades past any pass, which reads in the field as "top /
/// bottom never complete". Relative gates ask every face for the same
/// small motion from THEIR straight-ahead. Null [frontPitch] (resume
/// scans without a front section) falls back to the absolute gates.
bool poseOkWithRef(
        PoseTarget target, double yaw, double? pitch, double? frontPitch) =>
    switch (target) {
      PoseTarget.up when pitch != null && frontPitch != null =>
        pitch <= frontPitch - kPitchRelDelta,
      PoseTarget.down when pitch != null && frontPitch != null =>
        pitch >= frontPitch + kPitchRelDelta,
      _ => poseOkFor(target, yaw, pitch),
    };

/// Guidance twin of [poseOkWithRef]: same relative nudge ladder, same
/// single-line contract (never top-vs-bottom guesswork for the holder).
String? poseGuidanceWithRef(
    PoseTarget target, double yaw, double? pitch, double? frontPitch) {
  if (target == PoseTarget.up && frontPitch != null) {
    if (pitch == null) return 'Tilt your chin slightly up ↑.';
    if (pitch <= frontPitch - kPitchRelDelta) return null;
    if (pitch <= frontPitch) return 'A bit more up ↑ — lift your chin.';
    return 'Look straight first, then lift your chin ↑.';
  }
  if (target == PoseTarget.down && frontPitch != null) {
    if (pitch == null) return 'Tilt your chin slightly down ↓.';
    if (pitch >= frontPitch + kPitchRelDelta) return null;
    if (pitch >= frontPitch) return 'A bit more down ↓ — lower your chin.';
    return 'Look straight first, then lower your chin ↓.';
  }
  return poseGuidanceFor(target, yaw, pitch);
}

/// Live directional copy for a good-but-misposed frame (null when the
/// frame counts). Arrows match motion on the MIRRORED preview: turning
/// left moves the nose screen-left. Every arrow duplicates a word
/// ("turn left ←" never relies on ← alone).
///
/// Up/down copy lives in the SAME line as left/right (single live
/// instruction): the holder never has to decide between a top title and
/// a bottom hint — one sentence says where to look right now.
String? poseGuidanceFor(PoseTarget target, double yaw, [double? pitch]) {
  switch (target) {
    case PoseTarget.any:
      return null;
    case PoseTarget.front:
      return yaw.abs() <= kPoseFrontMax ? null : 'Face the camera straight on.';
    case PoseTarget.left:
      if (yaw > kPoseSideMax) return 'Too far — ease back a little →.';
      if (yaw < 0) return 'Other way — turn left ←.';
      if (yaw < kPoseSideMin) return 'A bit more left ←.';
      return null;
    case PoseTarget.right:
      if (yaw < -kPoseSideMax) return 'Too far — ease back a little ←.';
      if (yaw > 0) return 'Other way — turn right →.';
      if (yaw > -kPoseSideMin) return 'A bit more right →.';
      return null;
    case PoseTarget.up:
      if (pitch == null) return 'Tilt your chin slightly up ↑.';
      if (pitch <= kPitchUpMax) return null;
      if (pitch <= kPitchFrontMax) return 'A bit more up ↑ — lift your chin.';
      return 'Look straight first, then lift your chin ↑.';
    case PoseTarget.down:
      if (pitch == null) return 'Tilt your chin slightly down ↓.';
      if (pitch >= kPitchDownMin) return null;
      if (pitch >= kPitchFrontMin) return 'A bit more down ↓ — lower your chin.';
      return 'Look straight first, then lower your chin ↓.';
  }
}
