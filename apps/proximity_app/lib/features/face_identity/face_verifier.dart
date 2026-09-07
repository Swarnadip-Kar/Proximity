// FaceVerifier: the ONE narrow on-device face-identity interface
// (Tracks 2+3). Everything face in the app goes through here — enrollment,
// marking, and the SK-use stamp. No embeddings, templates, or images ever
// leave the device: the plugin owns its FaceNet store; the app only sees
// {score, match} and binds them into Sig_s via the face ticket.
//
// Backend: `face_verification` plugin (^0.3.9, MIT, Android/iOS, bundled
// FaceNet TFLite, offline) following its example/ Quick Demo pattern:
// init() once → registerFromImagePath(id, imagePath, imageId) per still →
// verifyFromImagePath/verifyFromImagePathIsolate(imagePath, threshold,
// staffId). Passive only: no blink/turn-head prompts, no second ticket
// key — the match binds into the ALREADY-SIGNED Sig_s ticket, not a new
// key. Marking hot path uses the isolate variant.
//
// L1 mobile gate: every method calls [requireMobileFace] first
// (isAndroid||isIOS via platformx) — desktop/web fail closed through
// [UnavailableFaceVerifier] (wired by DI, never the plugin).
//
// Score semantics (plugin reality, documented not hidden): the plugin's
// verify API returns the matched id (or null), not a distance. A match is
// therefore carried at exactly the decision [threshold] — the honest
// boundary value, bound into the ticket and re-checked host-side
// (score>=T). The exact-1.000-repeat anomaly flag can never false-fire on
// these (it keys on >=1.0). Calibration note: FAR~0.01%/FRR<2% at the
// 0.70 default is the plugin's published operating point, not a
// Proximity-measured ROC — see residual risks.
library;

import 'package:face_verification/face_verification.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_protocol/protocol.dart';

import '../../core/platformx.dart';

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

/// Enrollment still slots, in capture order: centre + slight left/right.
/// Three stills, not five guided poses — the plugin owns pose tolerance.
const faceEnrollSlots = ['centre', 'left', 'right'];

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

  /// Enrolls [faceId] from exactly the 3 slot stills (centre/left/right).
  /// Replaces any previous faces for [faceId] (clean re-enroll).
  Future<void> enroll(String faceId, List<String> imagePaths);

  /// Verifies one still against [faceId]. Marking hot path uses the
  /// isolate variant internally. Returns {score, match}.
  Future<FaceVerifyResult> verify(String faceId, String imagePath,
      {double threshold = kFaceThreshold});

  /// Removes all faces for [faceId] (account switch / explicit reset).
  Future<void> remove(String faceId);

  /// Opaque pipeline tag (`face_verification/<pkgVer>+<assetHash8>`).
  String get verifierVer;
}

/// Production backend: the `face_verification` plugin. Mobile-only —
/// every method gates on [requireMobileFace] (L1).
class PluginFaceVerifier implements FaceVerifier {
  final FaceVerification _plugin;
  bool _ready = false;

  PluginFaceVerifier({FaceVerification? plugin})
      : _plugin = plugin ?? FaceVerification.instance;

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
    // boundary on match (see file header — honest, host re-checks).
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
  String get verifierVer => 'unavailable';
}

/// Test-only fake (mirrors the FakeFaceCamera precedent): scripted
/// match/score, records calls. Never shipped (DI wires plugin/stub).
class FakeFaceVerifier implements FaceVerifier {
  bool match;
  double score;
  final List<String> calls = [];
  String version;
  FakeFaceVerifier(
      {this.match = true,
      this.score = 0.85,
      this.version = kFaceVerifierVer});

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
  String get verifierVer => version;
}

final faceVerifierProvider = Provider<FaceVerifier>((ref) {
  throw UnimplementedError('Override in main / tests');
});
