// Web records-only stub for face_verifier_plugin.dart: identical public
// API (PluginFaceVerifier), every op throws. The web app never verifies
// (records only, UnavailableFaceVerifier is DI-wired); this exists so the
// shared face_verifier.dart compiles for web without dart:ffi.
// Native builds use face_verifier_plugin.dart. Mirror the class members
// here or the web build fails loudly (by design).
library;

import 'package:proximity_protocol/protocol.dart';

import 'face_verifier.dart';

/// Fail-closed plugin stand-in: construction is harmless (DI never picks
/// it on web), every op refuses — SK never signs without a holder check.
class PluginFaceVerifier implements FaceVerifier {
  PluginFaceVerifier();

  static StateError _blocked([String op = 'Face verification']) => StateError(
      '$op needs the mobile app (Android/iOS) — this device is records-only.');

  @override
  Future<void> init() async => throw _blocked();

  @override
  Future<void> enroll(String faceId, List<String> imagePaths) async =>
      throw _blocked('Face enrollment');

  @override
  Future<FaceVerifyResult> verify(String faceId, String imagePath,
          {double threshold = kFaceThreshold}) async =>
      throw _blocked('Face check');

  @override
  Future<void> remove(String faceId) async => throw _blocked();

  @override
  Future<List<double>> embeddingFor(String faceId) async =>
      throw _blocked('Face enrollment');

  @override
  String get verifierVer => 'unavailable';
}
