// MiniFASNetLivenessGate: native (Android/iOS) passive scorer for
// liveness_gate.dart. Split out so the shared interface compiles for web
// without dart:io (records builds get liveness_gate_stub.dart via the
// conditional export — same pattern as face_verifier_plugin.dart).
//
// Passive MiniFASNetV2 (offline, ~1s, no license-key SDK): file sanity
// (missing/empty/tiny/unknown-magic fail closed) + dart:ui decode at 160px
// + face-box/BGR/NCHW packing ([minifasnetInputFromRgba] with an ML Kit
// bbox, fallback centre-crop) + ONE `tflite_flutter` Interpreter invoke on
// the vendored weights ([kLivenessModelAsset]) + LIVE-class post-processing
// ([liveScoreFromProbs]). See liveness_gate.dart header for the model
// contract and the honesty note (face-box crop, single 2.7 model, no
// ensemble; FAR/FRR unmeasured + calibration TODO). Every failure —
// unreadable still, missing asset, interpreter/shape error, timeout —
// throws StateError (fail-closed); there is NO heuristic fallback, by
// design. The face-box fallback (centre-crop) is NOT a heuristic pass:
// both paths feed the SAME scorer + Tl decider.
//
// Class-name note: the historical `HeuristicLivenessGate` name is kept so
// the shared wiring (`RealStudentDriver` default, web stub mirror) keeps
// compiling without touching other owners' files — the scorer inside is
// the MiniFASNetV2 model, and [kLivenessVer] names it truthfully.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../core/platformx.dart';
import 'liveness_gate.dart';

/// Native passive gate: real file + real decode + real model inference.
/// Construction is cheap (the interpreter loads lazily on first use and is
/// shared process-wide); every method gates on [requireMobileFace] (L1)
/// before touching the filesystem.
class HeuristicLivenessGate implements LivenessGate {
  /// Upper bound for read+decode+score (marking hot path is ~1s; anything
  /// slower is infrastructure failure and degrades to the rescan-safe
  /// throw below instead of hanging the face-check UI).
  final Duration budget;

  const HeuristicLivenessGate({
    this.budget = const Duration(milliseconds: 1200),
  });

  /// Process-wide interpreter singleton: first [detectPassive] pays the
  /// asset load, later calls reuse it. A failed load clears the slot so
  /// the next call retries instead of caching a dead future.
  static Interpreter? _ready;
  static Future<Interpreter>? _loading;

  static Future<Interpreter> _interpreter() async {
    final hit = _ready;
    if (hit != null) return hit;
    var pending = _loading;
    if (pending == null) {
      pending = _load();
      _loading = pending;
    }
    try {
      final it = await pending;
      _ready = it;
      return it;
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  static Future<Interpreter> _load() async {
    try {
      final it = await Interpreter.fromAsset(kLivenessModelAsset);
      // Pin the verified contract at load: anything else is a wrong-asset
      // packaging bug, failed closed here instead of mis-scored later.
      final inShape = it.getInputTensor(0).shape;
      final outShape = it.getOutputTensor(0).shape;
      if (inShape.length != 4 ||
          inShape[0] != 1 ||
          inShape[1] != 3 ||
          inShape[2] != kLivenessInputSize ||
          inShape[3] != kLivenessInputSize ||
          outShape.length != 2 ||
          outShape[0] != 1 ||
          outShape[1] != 3) {
        try {
          it.close();
        } catch (_) {}
        throw StateError(
            'Liveness model has an unexpected shape (in=$inShape, out=$outShape) — reinstall the app and try again.');
      }
      return it;
    } catch (e) {
      if (e is StateError) rethrow;
      throw StateError(
          'Liveness model did not load — reinstall the app and try again ($e)');
    }
  }

  /// Fail-closed still read BEFORE any decode: empty paths, missing files,
  /// tiny frames and non-image magic throw here as rescan-safe StateErrors
  /// the driver maps to inconclusive (rescan path, burns nothing), never a
  /// pass. Decode/model failures below throw the same way.
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

  /// Decode to raw RGBA at 160px (fast: ~25k px; the pure packer below
  /// nearest-neighbours to 80). Throws StateError when the bytes do not
  /// decode (fail-closed, same mapping as above).
  static Future<({Uint8List rgba, int width, int height})> _decodeRgba(
      Uint8List bytes) async {
    late final ui.Image img;
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 160);
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
      final raw = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null) {
        throw StateError(
            'The liveness still did not decode — recapture in good light, holding still.');
      }
      return (
        rgba: raw.buffer.asUint8List(),
        width: w,
        height: h,
      );
    } finally {
      img.dispose();
    }
  }

  /// Face-box detector for the pre-TFLite crop (bbox only, no landmarks /
  /// contours — minimal latency, offline, no new dep: the same
  /// `google_mlkit_face_detection` binary the pose gate already ships).
  /// Fast mode (pose gate uses accurate for Euler; the box needs only
  /// existence + rect). Process-wide singleton like the interpreter below;
  /// never closed (lives for the app lifetime). Runs on the MAIN isolate
  /// only (MethodChannel reply — same SIGABRT rule as pose_gate_mlkit.dart;
  /// [detectPassive] callers already run on main).
  static FaceDetector? _boxDetector;

  static FaceDetector _boxDetectorInstance() {
    var d = _boxDetector;
    if (d == null) {
      d = FaceDetector(
        options: FaceDetectorOptions(
          enableLandmarks: false,
          enableContours: false,
          performanceMode: FaceDetectorMode.fast,
        ),
      );
      _boxDetector = d;
    }
    return d;
  }

  /// One bbox pass in ORIGINAL file pixels. Returns null on every
  /// non-usable outcome (0 or >1 faces, detector/channel error, timeout,
  /// unparseable box) — the caller falls back to the legacy centre-square
  /// crop (same scorer + Tl, never a throw for the fallback itself).
  /// Never throws: detection failure must not block the scorer fallback.
  static Future<
      ({double left, double top, double right, double bottom})?>
      _detectFaceBoxOriginal(String imagePath, Duration remaining) async {
    try {
      final faces = await _boxDetectorInstance()
          .processImage(InputImage.fromFilePath(imagePath))
          .timeout(remaining);
      if (faces.length != 1) return null;
      final b = faces.first.boundingBox;
      if (!(b.right > b.left && b.bottom > b.top)) return null;
      if (!b.left.isFinite ||
          !b.top.isFinite ||
          !b.right.isFinite ||
          !b.bottom.isFinite) {
        return null;
      }
      return (
        left: b.left,
        top: b.top,
        right: b.right,
        bottom: b.bottom,
      );
    } catch (_) {
      return null;
    }
  }

  /// Single-flight turnstile for full passes: `tflite_flutter`
  /// interpreters are NOT safe for concurrent `run` — overlapping passes
  /// (rapid rescan taps, enroll+marking overlap) would share one
  /// synchronous invoke and corrupt output or crash native. Queued callers
  /// wait here but still fail closed on the shared [budget] deadline in
  /// [detectPassive] (rescan-safe throw, never a hang). The slot never
  /// completes with an error (see the `finally` below), so the chain stays
  /// healthy across failures. The ML Kit bbox pass above also runs inside
  /// this turnstile (serialized channel calls, no concurrent detects).
  static Future<void> _flight = Future.value();

  @override
  Future<LivenessResult> detectPassive(String imagePath) async {
    requireMobileFace();
    // Single deadline for the whole pass: read+decode+load+score share
    // [budget] (the marking hot path is ~1s). Per-stage timeouts would
    // stack to ~3x budget and blow the hot path, so every stage races the
    // same remaining time instead.
    final deadline = DateTime.now().add(budget);
    Future<T> within<T>(Future<T> f) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException(
            'liveness budget ${budget.inMilliseconds}ms exceeded');
      }
      return f.timeout(remaining);
    }
    // Queue behind any in-flight pass BEFORE touching the filesystem, so
    // concurrent callers serialize instead of sharing the interpreter.
    final prev = _flight;
    final turn = Completer<void>();
    _flight = turn.future;
    try {
      await within(prev);
      try {
        final bytes = await within(_readStillBytes(imagePath));
        final frame = await within(_decodeRgba(bytes));
        // Face-box crop before TFLite (sec-face hardening): ML Kit bbox in
        // ORIGINAL file pixels → map onto the 160px decoded frame via the
        // header dims → squared + clamped crop inside the packer. Fallback
        // is the legacy centre-square crop when detection is
        // unavailable/ambiguous (0 or >1 faces, detector error/timeout,
        // unparseable dims) — same scorer + same Tl, never a throw for the
        // fallback itself (the Tl gate stays the decider; no silent
        // downgrade — both paths feed the identical MiniFASNet scorer).
        ({int left, int top, int right, int bottom})? faceBox;
        try {
          final remaining = deadline.difference(DateTime.now());
          if (remaining > Duration.zero) {
            final orig =
                await _detectFaceBoxOriginal(imagePath, remaining);
            if (orig != null) {
              final dims = originalDimsFromBytes(bytes);
              if (dims != null) {
                faceBox = mapFaceBoxToFrame(
                  origLeft: orig.left,
                  origTop: orig.top,
                  origRight: orig.right,
                  origBottom: orig.bottom,
                  origWidth: dims.width,
                  origHeight: dims.height,
                  frameWidth: frame.width,
                  frameHeight: frame.height,
                );
              }
              // Null dims or null mapped box → centre-square fallback below.
            }
            // Null orig (0/>1 faces, detector error/timeout) → fallback.
          }
          // Expired remaining → fallback (inference still races the shared
          // deadline below and fails closed on timeout, never a hang).
        } catch (_) {
          // Belt-and-braces: the bbox helper never throws by contract, but
          // a mapping surprise must still fall back, never fail the pass.
          faceBox = null;
        }
        final input = minifasnetInputFromRgba(
          rgba: frame.rgba,
          width: frame.width,
          height: frame.height,
          faceBox: faceBox,
        );
        final output = List.generate(1, (_) => List.filled(3, 0.0));
        final it = await within(_interpreter());
        // Synchronous invoke (MiniFASNetV2 is ~5ms/frame on-device — the
        // deadline above guards read/decode/load; inference itself never
        // blocks on I/O, so no timeout can pre-empt it, by FFI design).
        // Runs under the turnstile above: never concurrent, by construction.
        it.run(input, output);
        final score = liveScoreFromProbs(output.first);
        return LivenessResult(score: score, ver: kLivenessVer);
      } on StateError {
        rethrow;
      } on TimeoutException catch (e) {
        // Hung read/decode/model: fail closed as a rescan-safe error (driver
        // maps to inconclusive, burns nothing), never a hang, never a pass.
        throw StateError(
            'Liveness check timed out — adjust light and try again ($e)');
      } on ArgumentError catch (e) {
        // Pure pre/post-processing contract breach (never on real frames):
        // fail closed, same mapping.
        throw StateError(
            'Liveness check did not read clearly — adjust light and try again ($e)');
      } catch (e) {
        throw StateError(
            'Liveness check did not read clearly — adjust light and try again ($e)');
      }
    } on StateError {
      rethrow;
    } on TimeoutException catch (e) {
      // Turnstile wait outlived the budget (a previous pass hogged it):
      // fail closed the same way, never a hang, never a pass.
      throw StateError(
          'Liveness check timed out — adjust light and try again ($e)');
    } catch (e) {
      throw StateError(
          'Liveness check did not read clearly — adjust light and try again ($e)');
    } finally {
      turn.complete();
    }
  }
}
