// PluginFaceVerifier: production `face_verification` backend (native
// Android/iOS only). Split out of face_verifier.dart so the web
// records-only build never imports dart:ffi (Track 4 §3 platformx-clean):
// face_verifier.dart includes THIS file on native and
// face_verifier_plugin_stub.dart on web. No logic lives here that the
// stub does not mirror as fail-closed.
library;

import 'package:face_verification/face_verification.dart';
import 'package:proximity_protocol/protocol.dart';

import '../../core/platformx.dart';
import 'face_verifier.dart';

/// Production backend: the `face_verification` plugin. Mobile-only —
/// every method gates on [requireMobileFace] (L1).
class PluginFaceVerifier implements FaceVerifier {
  final FaceVerification _plugin;
  bool _ready = false;

  PluginFaceVerifier() : _plugin = FaceVerification.instance;

  @override
  Future<void> init() async {
    requireMobileFace();
    if (_ready) return;
    // Quick-Demo pattern: init loads the bundled FaceNet TFLite + store.
    await _plugin.init();
    _ready = true;
  }

  @override
  Future<void> enroll(String faceId, List<String> imagePaths) async {
    requireMobileFace();
    if (imagePaths.length != faceEnrollSlots.length) {
      throw ArgumentError(
          'enroll needs ${faceEnrollSlots.length} stills (centre/left/right), got ${imagePaths.length}');
    }
    await init();
    // Clean re-enroll: previous faces for this id go first so a changed
    // appearance never matches against a stale still.
    try {
      await _plugin.deleteUserFaces(faceId);
    } catch (_) {
      // No previous enrollment — nothing to clear.
    }
    for (var i = 0; i < imagePaths.length; i++) {
      await _plugin.registerFromImagePath(
        id: faceId,
        imagePath: imagePaths[i],
        imageId: faceEnrollSlots[i],
      );
    }
  }

  @override
  Future<FaceVerifyResult> verify(String faceId, String imagePath,
      {double threshold = kFaceThreshold}) async {
    requireMobileFace();
    await init();
    // Marking hot path: the isolate variant (per approved spec).
    final hit = await _plugin.verifyFromImagePathIsolate(
      imagePath: imagePath,
      threshold: threshold,
      staffId: faceId,
    );
    final match = hit == faceId;
    // Plugin returns identity only, not a distance: carry the decision
    // boundary on match (see face_verifier.dart header — honest, host
    // re-checks).
    return FaceVerifyResult(score: match ? threshold : 0.0, match: match);
  }

  @override
  Future<void> remove(String faceId) async {
    requireMobileFace();
    await init();
    await _plugin.deleteUserFaces(faceId);
  }

  @override
  String get verifierVer => kFaceVerifierVer;
}
