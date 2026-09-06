// BlazeFace short-range detector runtime (TFLite, on-device).
//
// Native half of face_detect.dart: the pure geometry/decode/NMS helpers
// stay there; only this TFLite interpreter binding is platform-split (the
// web records build never detects faces and gets the throwing stub).
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'face_detect.dart';

class BlazeFaceDetector implements FaceDetector {
  static const modelAsset = 'assets/models/blaze_face_short_range.tflite';

  Interpreter? _interpreter;
  @override
  bool get isLoaded => _interpreter != null;

  @override
  Future<void> load() async {
    _interpreter = await Interpreter.fromAsset(modelAsset);
  }

  /// Detect faces in a JPEG still. Returns best-first detections
  /// (score ≥ [kBlazeMinScore]); empty when no readable face.
  @override
  Future<List<FaceDetection>> detect(Uint8List jpegBytes) async {
    final it = _interpreter;
    if (it == null) throw StateError('BlazeFace model not loaded.');
    img.Image? decoded;
    try {
      decoded = img.decodeImage(jpegBytes);
    } catch (_) {
      decoded = null;
    }
    if (decoded == null) return [];
    final sq = letterboxSquare(decoded);
    final small =
        img.copyResize(sq, width: blazeInputSize, height: blazeInputSize);
    final rgb = small.getBytes(order: img.ChannelOrder.rgb);
    final input = [
      List.generate(
          blazeInputSize,
          (y) => List.generate(blazeInputSize, (x) {
                final o = (y * blazeInputSize + x) * 3;
                return [
                  rgb[o] / 127.5 - 1.0,
                  rgb[o + 1] / 127.5 - 1.0,
                  rgb[o + 2] / 127.5 - 1.0,
                ];
              })),
    ];
    final boxesOut = List.generate(
        1, (_) => List.generate(896, (_) => List.filled(16, 0.0)));
    final scoresOut = List.generate(
        1, (_) => List.generate(896, (_) => List.filled(1, 0.0)));
    // Output tensor order varies by converter: identify by shape, then
    // copy each output tensor into its matching buffer by tensor index.
    final outTensors = it.getOutputTensors();
    final boxIndex = outTensors.indexWhere((t) => t.shape.last == 16);
    it.runForMultipleInputs([
      input
    ], {
      boxIndex: boxesOut,
      1 - boxIndex: scoresOut,
    });
    final rawBoxes = boxesOut[0];
    final rawScores = [for (final r in scoresOut[0]) r[0]];
    return blazeNms(decodeBlaze(rawBoxes, rawScores));
  }

  @override
  void close() {
    _interpreter?.close();
    _interpreter = null;
  }
}
