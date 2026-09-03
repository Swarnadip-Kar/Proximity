// Face package: EdgeFace-XS (TFLite Android / CoreML iOS), MLKit/Vision detect,
// cosine 0.60, challenge-bound liveness, SK gate faceValid<5min. (§4)
//
// Face templates never leave the phone (Keystore-wrapped AES-GCM).
// Server receives only {matchScore, livenessPass} inside signed payload.
// This pure-Dart core is platform-independent; platform adapters supply
// embeddings from the on-device model. Mock adapter drives tests/P0.
library proximity_face;

import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';

/// Platform embedding source (TFLite/CoreML behind this interface).
abstract class FaceEmbedder {
  /// Detect + crop/align + embed. Returns embedding vector.
  Future<List<double>> embed(List<int> frameBytes);
  Future<bool> checkLiveness(List<int> frameBytes, String prompt);
}

/// Mock embedder: returns canned vectors (pins holder vs stranger).
class MockFaceEmbedder implements FaceEmbedder {
  final List<double> enrolled;
  final List<double> probe;
  final bool liveness;
  MockFaceEmbedder(
      {required this.enrolled, required this.probe, this.liveness = true});

  @override
  Future<List<double>> embed(List<int> frameBytes) async => probe;

  @override
  Future<bool> checkLiveness(List<int> frameBytes, String prompt) async =>
      liveness;
}

/// High-level face session: holds enrollment template in memory (encrypted
/// at rest by platform secure storage in production).
class FaceSession {
  final FaceEmbedder embedder;
  final FaceGate gate;
  List<double>? _template;

  FaceSession({required this.embedder, FaceGate? gate})
      : gate = gate ?? FaceGate();

  void enroll(List<double> template) => _template = List.of(template);

  bool get isEnrolled => _template != null;

  /// ~1s oval UI check: embed probe, cosine vs template, liveness w/ prompt
  /// derived from C_j. Returns score; updates SK gate.
  Future<({double score, bool liveness, FaceDecision decision})> verify(
    List<int> frameBytes, {
    required Uint8List challenge,
    DateTime? now,
  }) async {
    final t = _template;
    if (t == null) throw StateError('not enrolled');
    final probe = await embedder.embed(frameBytes);
    final score = cosineSimilarity(t, probe);
    final prompt = ProxCrypto.livenessPrompt(challenge);
    final live = await embedder.checkLiveness(frameBytes, prompt);
    final d = gate.evaluate(score: score, livenessPass: live, now: now);
    return (score: score, liveness: live, decision: d);
  }
}
