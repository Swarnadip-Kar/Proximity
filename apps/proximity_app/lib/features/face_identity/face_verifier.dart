// FaceVerifier: the ONE narrow on-device face-identity interface
// (Tracks 2+3). Everything face in the app goes through here — enrollment,
// marking, and the SK-use stamp. No embeddings, templates, or images ever
// leave the device: the plugin owns its FaceNet store; the app only sees
// {score, match} and binds them into Sig_s via the face ticket.
//
// Backend: `face_verification` plugin (^0.3.9, MIT, Android/iOS, bundled
// FaceNet TFLite, offline) following its example/ Quick Demo pattern:
// init() once → registerFromImagePath(id, imagePath, imageId) per still →
// verifyFromImagePath(imagePath, threshold, staffId) on the MAIN isolate.
// Passive only: no blink/turn-head prompts, no second ticket
// key — the match binds into the ALREADY-SIGNED Sig_s ticket, not a new
// key. The isolate variant (`verifyFromImagePathIsolate`) is BANNED here:
// its background-isolate ML Kit reply aborts the engine (SIGABRT,
// temp.log 2026-09-10) — see face_verifier_plugin.dart.
//
// L1 mobile gate: every method calls [requireMobileFace] first
// (isAndroid||isIOS via platformx) — desktop/web fail closed through
// [UnavailableFaceVerifier] (wired by DI, never the plugin).
//
// Liveness ordering (security §4, F4 fix): this verifier is a PASSIVE
// matcher only — it never judges vitality. Callers (StudentDriver.checkFace)
// MUST run LivenessGate.detectPassive on the still BEFORE verify(): a
// below-threshold liveness fails as mismatch without ever reaching the
// matcher, and only a gated pass carries (livenessScore, livenessVer) into
// the extended Sig_s ticket. Calling verify() without a prior liveness
// gate is a contract violation (photo-spoof would match).
//
// Score semantics (plugin reality, documented not hidden): the plugin's
// verify API returns the matched id (or null), not a distance. A match is
// therefore carried at exactly the decision [threshold] — the honest
// boundary value, bound into the ticket and re-checked host-side
// (score>=T). The exact-1.000-repeat anomaly flag can never false-fire on
// these (it keys on >=1.0). The professor grades strength from the GRADED
// liveness score (0..1 MiniFASNet live-prob, same ticket — a 0.95 pass
// reads stronger than a 0.86 pass), not from this boundary value.
// Calibration note: T=0.70 is the plugin default AND matches an
// independent FaceNet512 deployment study (cosine-similarity 0.7 accept,
// 2026) — the best available tuning without a Proximity ROC; do not move
// it without one. System operating point WITH the §4 liveness gate
// (minifasnet-v2-27 scorer at 2.7x crop, Tl=0.70 field-relaxed): UNMEASURED on
// Proximity captures — no Proximity FAR/FRR ROC exists yet for the
// combined matcher+liveness decision (spoof FAR is strictly lower than
// face-only — a print must now also clear the vitality gate — but the FRR
// cost of the strict vitality gate on genuine dim/blurry stills is
// unquantified, and the shipped weights' upstream accuracy number is not
// a Proximity ROC). The adversarial drill + 2-phone relay stay required
// (sec-verify); never quote the plugin numbers as system numbers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_protocol/protocol.dart';

export 'face_verifier_plugin.dart'
    if (dart.library.html) 'face_verifier_plugin_stub.dart';

/// Plugin version pinned in pubspec — part of [verifierVer].
const kFacePluginVer = '0.3.9';

/// First 8 hex of the plugin archive SHA-256 (pub.dev 0.3.9:
/// b45ab893ef…). Pins WHICH bundled asset the version string refers to;
/// a model swap ships as a new hash, forcing re-face via the stale
/// pipeline check (key kept).
const kFacePluginAssetHash8 = 'b45ab893';

/// Opaque pipeline tag stored on enrollment and bound into every Sig_s
/// ticket. Format: `face_verification/<pkgVer>+<assetHash8>`.
const kFaceVerifierVer = 'face_verification/$kFacePluginVer+$kFacePluginAssetHash8';

/// Enrollment still slots, in capture order: frontal centre + slight
/// left/right turns + slight up/down tilts. Five pose-diverse stills buy
/// genuine-match robustness and raise the spoof cost (one frontal print no
/// longer suffices) — but NOT photo-spoof immunity against the passive
/// matcher (see the residual below and PROXIMITY_DESIGN.md §4). Each slot's
/// angle is really gated at capture time by the PoseGate (ML Kit euler
/// windows on the still file); the plugin owns detection + matching
/// passively and never sees the angles.
const faceEnrollSlots = ['centre', 'left', 'right', 'up', 'down'];

/// Opaque face identity: SHA-256(lowercased Gmail || installId) hex.
/// Never the raw Gmail — the plugin store is keyed by this, so the
/// account address never lands in a third-party (plugin-owned) table.
String faceIdOf(String gmailLower, String installId) =>
    hexEncode(ProxCrypto.sha256Sync(
        [...gmailLower.trim().toLowerCase().codeUnits, ...installId.codeUnits]));

/// Result of one on-device verify: decision-boundary score + match bit.
/// `match` true means the plugin identified [faceId] at [threshold].
class FaceVerifyResult {
  final double score;
  final bool match;
  const FaceVerifyResult({required this.score, required this.match});
}

/// Narrow face-identity interface (one file, no wrappers).
abstract class FaceVerifier {
  /// Loads the bundled model + store. Idempotent.
  Future<void> init();

  /// Enrolls [faceId] from exactly the 5 slot stills
  /// (centre/left/right/up/down). Replaces any previous faces for [faceId]
  /// (clean re-enroll).
  Future<void> enroll(String faceId, List<String> imagePaths);

  /// Verifies one still against [faceId]. Runs on the main isolate
  /// internally (the plugin isolate variant is banned — SIGABRT, see
  /// above), bounded by a timeout that surfaces as a throw the callers
  /// map to inconclusive. Returns {score, match}.
  Future<FaceVerifyResult> verify(String faceId, String imagePath,
      {double threshold = kFaceThreshold});

  /// Removes all faces for [faceId] (account switch / explicit reset).
  Future<void> remove(String faceId);

  /// Mean embedding over [faceId]'s enrolled stills (one 512-d vector for
  /// the local-session duplicate check — see protocol face_print.dart; the privacy
  /// flag there applies). Throws StateError when nothing is enrolled
  /// (fail-closed recapture, never an empty vector).
  Future<List<double>> embeddingFor(String faceId);

  /// Opaque pipeline tag (`face_verification/<pkgVer>+<assetHash8>`).
  String get verifierVer;
}

/// Fail-closed stub for desktop/web (L3 DI wires this wherever
/// [canUseFace] is false). Every method throws — SK never signs without a
/// real holder check, and UI shows [FaceBlockedCard] instead.
class UnavailableFaceVerifier implements FaceVerifier {
  const UnavailableFaceVerifier();

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

/// Test-only fake (same role the old FakeFaceCamera played): scripted
/// match/score, records calls. Never shipped (DI wires plugin/stub).
class FakeFaceVerifier implements FaceVerifier {
  bool match;
  double score;
  final List<String> calls = [];
  String version;

  /// Scripted mean embedding for [embeddingFor] (dup-check tests set
  /// explicit vectors; defaults to a fixed non-zero vector).
  List<double> scriptedEmbedding;
  FakeFaceVerifier(
      {this.match = true,
      this.score = 0.85,
      this.version = kFaceVerifierVer,
      List<double>? scriptedEmbedding})
      : scriptedEmbedding = scriptedEmbedding ??
            List<double>.filled(512, 0.044);

  @override
  Future<void> init() async => calls.add('init');

  @override
  Future<void> enroll(String faceId, List<String> imagePaths) async =>
      calls.add('enroll:$faceId:${imagePaths.length}');

  @override
  Future<FaceVerifyResult> verify(String faceId, String imagePath,
          {double threshold = kFaceThreshold}) async {
    calls.add('verify:$faceId');
    return FaceVerifyResult(score: match ? score : 0.2, match: match);
  }

  @override
  Future<void> remove(String faceId) async => calls.add('remove:$faceId');

  @override
  Future<List<double>> embeddingFor(String faceId) async {
    calls.add('embeddingFor:$faceId');
    return List<double>.from(scriptedEmbedding);
  }

  @override
  String get verifierVer => version;
}

final faceVerifierProvider = Provider<FaceVerifier>((ref) {
  throw UnimplementedError('Override in main / tests');
});
