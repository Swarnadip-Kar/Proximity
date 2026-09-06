// EdgeFace-XS embedding runtime (TFLite, on-device). Native half of the
// edgeface.dart facade (see that file): shared names (FaceModelMissing,
// kFacePipelineVer) are mirrored in edgeface_web.dart — keep them identical.
//
// Pipeline (lock-screen style, fully on-device): JPEG bytes → BlazeFace
// short-range detect (6 keypoints) → geometric sanity gate →
// similarity-transform alignment to the canonical 112×112 frame → EdgeFace-XS
// (gamma=0.6, 1.77M params) NCHW inference → L2-normalized 512-D embedding.
// Cosine gate stays 0.60 (§4).
//
// Models (both vendored under assets/models/):
//   edgeface_xs.tflite — EdgeFace-XS, exported from the official PyTorch
//     weights (https://github.com/otroshi/edgeface,
//     `checkpoints/edgeface_xs_gamma_06.pt`) via litert-torch. Float32,
//     NCHW `[1,3,112,112]` RGB `(x-127.5)/127.5` in, `[1,512]` out —
//     exactly the official recipe (ToTensor to [0,1] + Normalize(0.5, 0.5)
//     = x*2-1 on uint8), verified against it numerically. L2-normalize
//     the output (ArcFace-style cosine space) before any comparison.
//     Verified 2026-09-05 (cosine 0.99999994 vs ONNX; CC BY-NC-SA 4.0).
//   blaze_face_short_range.tflite — MediaPipe BlazeFace short-range
//     detector (224KB, Apache-2.0), 128×128 RGB [-1,1] in, 896×16 boxes +
//     896×1 scores out. Verified 2026-09-05 (factory-geometry decode;
//     alignment reaches 0.94 cosine parity with the SCRFD-based reference
//     alignment on the same photo).
//
// If either file is missing, [load] throws [FaceModelMissing] and every
// face check fails closed (never a silent wrong score).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:proximity_face/face.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'blazeface_native.dart';
import 'face_camera.dart';
import 'face_detect.dart';

class FaceModelMissing implements Exception {
  final String message;
  const FaceModelMissing(this.message);
  @override
  String toString() => 'FaceModelMissing: $message';
}

/// Face pipeline version: EdgeFace-XS γ=0.6 weights + BlazeFace decode +
/// similarity-warp alignment. Bump whenever ANY stage changes (model,
/// decode, warp, preprocessing): embeddings are not comparable across
/// versions, so a mismatch forces re-enrollment instead of garbage scores.
/// (History: alignfix1 = corrected inverse-warp signs, 2026-09-05. The old
/// signs were invisible on frontal faces but shifted tilted faces by tens
/// of pixels — genuine 0.21 vs impostor 0.56 measured broken.)
const kFacePipelineVer = 'edgeface-xs-g06-tflite-alignfix1';

class EdgeFaceEmbedder implements FaceEmbedder {
  static const modelAsset = 'assets/models/edgeface_xs.tflite';
  static const inputSize = 112;
  static const embeddingDim = 512;

  final FaceDetector _blaze;
  EdgeFaceEmbedder({FaceDetector? detector})
      : _blaze = detector ?? BlazeFaceDetector();

  /// The detector backing this embedder (shared with the scan screen so
  /// the model loads exactly once).
  FaceDetector get detector => _blaze;

  Interpreter? _interpreter;
  bool get isLoaded => _interpreter != null && _blaze.isLoaded;

  Future<void> load() async {
    try {
      await _blaze.load();
      _interpreter = await Interpreter.fromAsset(modelAsset);
    } catch (e) {
      throw FaceModelMissing(
        'Place the EdgeFace-XS model at $modelAsset and the BlazeFace '
        'detector at ${BlazeFaceDetector.modelAsset} '
        '(see edgeface.dart header). Underlying: $e',
      );
    }
  }

  @override
  Future<List<double>> embed(List<int> frameBytes) async {
    final it = _interpreter;
    if (it == null || !_blaze.isLoaded) {
      throw const FaceModelMissing(
          'Call load() with $modelAsset present first.');
    }
    img.Image? decoded;
    try {
      decoded = img.decodeImage(Uint8List.fromList(frameBytes));
    } catch (_) {
      decoded = null;
    }
    if (decoded == null) throw StateError('Undecodable frame.');
    final bytes = Uint8List.fromList(frameBytes);
    final dets = await _blaze.detect(bytes);
    // Same quality gates as the live scan (detect/sanity/lighting/
    // sharpness): a poor frame throws instead of embedding, so callers
    // fail closed (inconclusive, attempt kept) instead of matching garbage
    // and burning a mismatch attempt. Never auto-present on a bad read.
    final q = analyzeFrame(
      faces: dets.isEmpty ? 0 : 1,
      luma: estimateBrightness(bytes),
      sane: dets.isEmpty || saneGeometry(dets.first),
      sharpness: estimateSharpness(bytes),
    );
    if (q != FrameQuality.good) throw StateError(frameGuidance(q));
    final det = dets.first;
    final face = alignFace(letterboxSquare(decoded), det);
    final rgb = face.getBytes(order: img.ChannelOrder.rgb);
    // NCHW float32 [1,3,112,112]: channel c holds the 112×112 plane of
    // (x-127.5)/127.5 normalized RGB values.
    final input = [
      List.generate(
          3,
          (c) => List.generate(
              inputSize,
              (y) => List.generate(inputSize, (x) {
                    final o = (y * inputSize + x) * 3 + c;
                    return rgb[o] / 127.5 - 1.0;
                  }))),
    ];
    final output =
        List.generate(1, (_) => List.filled(embeddingDim, 0.0));
    it.run(input, output);
    return _l2normalize(output[0]);
  }

  @override
  Future<bool> checkLiveness(List<int> frameBytes, String prompt) async {
    // Presence is proven at capture time by the live loop (streak of sharp
    // detector-verified stills in FaceCaptureScreen). This single-frame API
    // cannot re-verify motion, so it stays a pass-through; do NOT treat it
    // as anti-spoof evidence.
    return true;
  }

  void close() {
    _interpreter?.close();
    _interpreter = null;
    _blaze.close();
  }
}

/// Production wiring for `main.dart`: loads the vendored EdgeFace-XS model
/// + BlazeFace detector once and returns the ready embedder for enrollment
/// + student drivers (its shared detector feeds the scan screen too).
///
/// Fail-closed: when a model file cannot load, the SAME (unloaded)
/// instance is returned, so every face check throws [FaceModelMissing]
/// instead of silently passing on a mock. SK never signs without a real
/// holder check.
Future<EdgeFaceEmbedder> loadFaceEmbedder() async {
  final embedder = EdgeFaceEmbedder();
  try {
    await embedder.load();
  } on FaceModelMissing {
    // Return unloaded: embed() throws FaceModelMissing (fail-closed).
  }
  return embedder;
}

List<double> _l2normalize(List<double> v) {
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  n = math.sqrt(n);
  if (n == 0) return v;
  return [for (final x in v) x / n];
}
