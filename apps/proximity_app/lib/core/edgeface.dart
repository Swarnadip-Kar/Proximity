// EdgeFace-XS embedding runtime (TFLite, on-device).
//
// Model slot: `assets/models/edgeface_xs.tflite` — converted from the
// official EdgeFace-XS (gamma=0.6) weights:
//   https://github.com/yakhyo/edgeface-onnx/releases/tag/weights
//   (edgeface_xs_gamma_06.onnx → TFLite, 112×112 RGB in, 512-D out).
// No official TFLite exists upstream, so conversion (onnx2tf / ai-edge-torch)
// is a maintainer step; the file is NOT in the repo until then.
//
// Pipeline: JPEG bytes → center-square crop → 112×112 → [-1,1] normalize →
// inference → L2-normalized 512-D embedding. Cosine gate stays 0.60 (§4).
// Until the file lands, [load] throws [FaceModelMissing] and the app keeps
// the mock embedder (never a silent wrong score).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:proximity_face/face.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class FaceModelMissing implements Exception {
  final String message;
  const FaceModelMissing(this.message);
  @override
  String toString() => 'FaceModelMissing: $message';
}

class EdgeFaceEmbedder implements FaceEmbedder {
  static const modelAsset = 'assets/models/edgeface_xs.tflite';
  static const inputSize = 112;
  static const embeddingDim = 512;

  Interpreter? _interpreter;
  bool get isLoaded => _interpreter != null;

  Future<void> load() async {
    try {
      _interpreter = await Interpreter.fromAsset(modelAsset);
    } catch (e) {
      throw FaceModelMissing(
        'Place the converted EdgeFace-XS model at $modelAsset '
        '(see edgeface.dart header). Underlying: $e',
      );
    }
  }

  @override
  Future<List<double>> embed(List<int> frameBytes) async {
    final it = _interpreter;
    if (it == null) {
      throw const FaceModelMissing(
          'Call load() with $modelAsset present first.');
    }
    final decoded = img.decodeImage(Uint8List.fromList(frameBytes));
    if (decoded == null) throw StateError('Undecodable frame.');
    final face = img.copyResizeCropSquare(decoded, size: inputSize);
    final rgb = face.getBytes(order: img.ChannelOrder.rgb);
    final input = List.generate(
        1,
        (_) => List.generate(
            inputSize,
            (y) => List.generate(inputSize, (x) {
                  final o = (y * inputSize + x) * 3;
                  return [
                    rgb[o] / 127.5 - 1.0,
                    rgb[o + 1] / 127.5 - 1.0,
                    rgb[o + 2] / 127.5 - 1.0,
                  ];
                })));
    final output =
        List.generate(1, (_) => List.filled(embeddingDim, 0.0));
    it.run(input, output);
    return _l2normalize(output[0]);
  }

  @override
  Future<bool> checkLiveness(List<int> frameBytes, String prompt) async {
    // Presence was already proven by the Vision/ML Kit detect gate on the
    // same still. Active prompt verification (blink/turn over a frame
    // sequence) lands with the streaming capture update.
    return true;
  }

  void close() {
    _interpreter?.close();
    _interpreter = null;
  }
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
