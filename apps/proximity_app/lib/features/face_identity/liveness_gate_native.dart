// HeuristicLivenessGate: native (Android/iOS) passive scorer for
// liveness_gate.dart. Split out so the shared interface compiles for web
// without dart:io (records builds get liveness_gate_stub.dart via the
// conditional export — same pattern as face_verifier_plugin.dart).
//
// Heuristic-v1 (offline, ~1s, no new deps, no license-key SDK): file
// sanity (missing/empty/tiny/unknown-magic fail closed) + dart:ui decode
// at 112px + three texture features (Laplacian sharpness, chroma
// diversity, specular fraction) combined by [combineLivenessFeatures].
// See liveness_gate.dart header for the honesty contract (cost, not
// immunity; FAR/FRR unmeasured; ONNX scorer via tflite_flutter later bumps
// the ver suffix and forces re-face — same API, no caller change).
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core/platformx.dart';
import 'liveness_gate.dart';

/// Native passive gate: real file + real decode, heuristic-v1 score.
/// Construction is cheap (no model load — heuristic); every method gates
/// on [requireMobileFace] (L1) before touching the filesystem.
class HeuristicLivenessGate implements LivenessGate {
  /// Upper bound for read+decode+score (marking hot path is ~1s; anything
  /// slower is infrastructure failure and degrades to the rescan-safe
  /// throw below instead of hanging the face-check UI).
  final Duration budget;

  const HeuristicLivenessGate({
    this.budget = const Duration(milliseconds: 1200),
  });

  /// Fail-closed still read BEFORE any decode: empty paths, missing files,
  /// tiny frames and non-image magic throw here as rescan-safe StateErrors
  /// the driver maps to inconclusive (rescan path, burns nothing), never a
  /// pass. Decode failures below throw the same way.
  Future<Uint8List> _readStillBytes(String imagePath) async {
    if (imagePath.trim().isEmpty) {
      throw StateError(
          'The liveness still came out blank — recapture in good light, holding still.');
    }
    late final File f;
    try {
      f = File(imagePath);
      if (!f.existsSync()) {
        throw StateError(
            'The liveness still is unreadable (file missing) — recapture in good light, holding still.');
      }
      final bytes = await f.readAsBytes();
      // Below a few KB no phone camera still is intact (corrupt write, not
      // a holder) — fail closed, never score garbage.
      if (bytes.length < 4096) {
        throw StateError(
            'The liveness still came out blank — recapture in good light, holding still.');
      }
      // JPEG (FF D8 FF) or PNG (89 50 4E 47) magic only: camera stills are
      // always one of these; anything else is not a capture (fail closed).
      final jpeg = bytes.length >= 3 &&
          bytes[0] == 0xFF &&
          bytes[1] == 0xD8 &&
          bytes[2] == 0xFF;
      final png = bytes.length >= 4 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47;
      if (!jpeg && !png) {
        throw StateError(
            'The liveness still is unreadable — recapture in good light, holding still.');
      }
      return bytes;
    } on StateError {
      rethrow;
    } catch (e) {
      throw StateError(
          'The liveness still is unreadable — recapture in good light, holding still ($e)');
    }
  }

  /// Decode + feature extraction at 112px (fast: ~17k px). Returns the
  /// three 0..1 features for [combineLivenessFeatures]. Throws StateError
  /// when the bytes do not decode (fail-closed, same mapping as above).
  static Future<({double sharpness, double chroma, double specular})>
      featuresOf(Uint8List bytes) async {
    late final ui.Image img;
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 112);
      img = (await codec.getNextFrame()).image;
    } catch (e) {
      throw StateError(
          'The liveness still did not decode — recapture in good light, holding still ($e)');
    }
    try {
      final w = img.width, h = img.height;
      if (w < 8 || h < 8) {
        throw StateError(
            'The liveness still came out blank — recapture in good light, holding still.');
      }
      final raw =
          await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null) {
        throw StateError(
            'The liveness still did not decode — recapture in good light, holding still.');
      }
      final px = raw.buffer.asUint8List();
      // Luminance grid for the Laplacian; chroma/specular accumulate inline.
      final lum = Float64List(w * h);
      var chromaAcc = 0.0;
      var specCount = 0;
      var n = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final o = (y * w + x) * 4;
          final r = px[o].toDouble();
          final g = px[o + 1].toDouble();
          final b = px[o + 2].toDouble();
          final l = 0.299 * r + 0.587 * g + 0.114 * b;
          lum[y * w + x] = l;
          final mx = math.max(r, math.max(g, b));
          final mn = math.min(r, math.min(g, b));
          chromaAcc += (mx - mn) / 255.0;
          if (l > 235) specCount++;
          n++;
        }
      }
      // Laplacian variance over interior pixels (4-neighbour kernel).
      var mean = 0.0;
      var m2 = 0.0;
      var k = 0;
      for (var y = 1; y < h - 1; y++) {
        for (var x = 1; x < w - 1; x++) {
          final c = lum[y * w + x];
          final lap = 4 * c -
              lum[y * w + x - 1] -
              lum[y * w + x + 1] -
              lum[(y - 1) * w + x] -
              lum[(y + 1) * w + x];
          k++;
          final delta = lap - mean;
          mean += delta / k;
          m2 += delta * (lap - mean);
        }
      }
      // Welford variance (m2/k).
      final lapVar = k > 0 ? (m2 / k) : 0.0;
      // Heuristic-v1 normalizations (UNCALIBRATED judgment — see the
      // interface header; pending ROC + ONNX scorer):
      //  - natural stills land lapVar ~10..1000+ → log10 maps to ~0.25..1.
      //  - indoor portraits average chroma spread ~0.05..0.25 → ×4.
      //  - specular highlights are rare (<2%) → fraction ×50 saturates.
      final sharpness = ((math.log(lapVar + 1) / math.ln10) - 0.5) / 2.0;
      final chroma = (chromaAcc / n) * 4.0;
      final specular = (specCount / n) * 50.0;
      double c(double v) => v.isNaN ? 0.0 : v.clamp(0.0, 1.0);
      return (
        sharpness: c(sharpness),
        chroma: c(chroma),
        specular: c(specular)
      );
    } finally {
      img.dispose();
    }
  }

  @override
  Future<LivenessResult> detectPassive(String imagePath) async {
    requireMobileFace();
    try {
      final bytes =
          await _readStillBytes(imagePath).timeout(budget);
      final f = await featuresOf(bytes).timeout(budget);
      final score = combineLivenessFeatures(
        sharpness: f.sharpness,
        chroma: f.chroma,
        specular: f.specular,
      );
      return LivenessResult(score: score, ver: kLivenessVer);
    } on StateError {
      rethrow;
    } on TimeoutException catch (e) {
      // Hung read/decode: fail closed as a rescan-safe error (driver maps
      // to inconclusive, burns nothing), never a hang, never a pass.
      throw StateError(
          'Liveness check timed out — adjust light and try again ($e)');
    } catch (e) {
      throw StateError(
          'Liveness check did not read clearly — adjust light and try again ($e)');
    }
  }
}
