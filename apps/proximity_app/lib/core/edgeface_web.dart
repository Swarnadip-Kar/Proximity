// EdgeFace stub for the web records build: identical public API, every
// call throws. The web app never embeds faces (records only); this exists
// so enrollment/drivers compile for web. Native builds use
// edgeface_native.dart (TFLite). kFacePipelineVer MUST equal the native
// value (it tags stored templates); the web build never writes templates,
// but keep them identical by inspection. Mirror new shared-code members
// here or the web build fails loudly (by design).
library;

import 'package:proximity_face/face.dart';

import 'face_detect.dart';

class FaceModelMissing implements Exception {
  final String message;
  const FaceModelMissing(this.message);
  @override
  String toString() => 'FaceModelMissing: $message';
}

/// MUST equal edgeface_native.dart's value.
const kFacePipelineVer = 'edgeface-xs-g06-tflite-alignfix1';

Never _web() => throw const FaceModelMissing('records-only web build');

class EdgeFaceEmbedder implements FaceEmbedder {
  EdgeFaceEmbedder({FaceDetector? detector});

  /// The detector backing this embedder (never loaded on web).
  FaceDetector get detector => _web();

  bool get isLoaded => false;

  Future<void> load() => _web();

  @override
  Future<List<double>> embed(List<int> frameBytes) => _web();

  @override
  Future<bool> checkLiveness(List<int> frameBytes, String prompt) => _web();

  void close() {}
}

/// Production wiring for `main.dart`: the web build never calls this with
/// a usable result (records only), but the call compiles and fails closed.
Future<EdgeFaceEmbedder> loadFaceEmbedder() async => EdgeFaceEmbedder();
