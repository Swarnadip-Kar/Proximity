// PluginFaceVerifier: production `face_verification` backend (native
// Android/iOS only). Split out of face_verifier.dart so the web
// face_verifier.dart includes THIS file on native and
// face_verifier_plugin_stub.dart on web. No logic lives here that the
// stub does not mirror as fail-closed.
//
// M1 threshold notes (Spark-free, no behavior change):
//   - distances unavailable: the plugin returns identity only (matched id
//     or null), never an embedding distance — a match carries the decision
//     threshold as its score (honest boundary value; the host re-checks
//     score >= T=0.70). No FAR/FRR is quoted: T is the plugin default,
//     UNCALIBRATED on Proximity captures — field ROC required per
//     `test/liveness_calibration_test.dart` (`sweepTl`/`recommendTl`) before
//     changing T or claiming rates (same procedure as Tl).
//   - unified still-readability gates (fail closed BEFORE scoring, same
//     outcome as the liveness native gate — different layer, same law):
//     empty path → blank; missing file → unreadable; zero-byte → blank;
//     tiny/corrupt frames and non-image magic surface as detector throws
//     mapped to the same rescan-safe StateErrors below (never a pass).
//     The gate in `face_gate.dart` never sees an unreadable still.
//   - budgets: [verifyTimeout] (10s, ML Kit detect + FaceNet + compare) +
//     [initTimeout] (30s, one-time model/store load); past budget the call
//     fails closed as a rescan-safe error (driver maps to inconclusive,
//     burns nothing), never a hang, never a pass.
library;

import 'dart:async';
import 'dart:io';

import 'package:face_verification/face_verification.dart';
import 'package:proximity_protocol/protocol.dart';

import '../../core/platformx.dart';
import 'face_verifier.dart';

/// Main-isolate verify delegate: exactly the signature of the plugin's
/// supported main-isolate verify
/// (`FaceVerification.verifyFromImagePath`), injected only by tests so the
/// crash fix (no isolate variant), timeout, and fail-closed mapping are
/// unit-testable without native channels. Production always passes null
/// and reaches the real plugin below.
typedef MainIsolateVerify = Future<String?> Function({
  required String imagePath,
  required double threshold,
  required String? staffId,
});

/// Production backend: the `face_verification` plugin. Mobile-only —
/// every method gates on [requireMobileFace] (L1).
class PluginFaceVerifier implements FaceVerifier {
  final FaceVerification? _plugin;

  /// Test-only override for the main-isolate verify call (see
  /// [MainIsolateVerify]). Null in production.
  final MainIsolateVerify? _verifyForTest;
  bool _ready = false;

  /// Upper bound for one main-isolate verify (ML Kit detect on the still +
  /// FaceNet embedding + gallery compare). The device log for the crash
  /// showed detection alone at ~290ms, so this is generous on slow
  /// devices; anything slower is infrastructure failure and degrades to
  /// the rescan-safe error below (driver maps it to inconclusive, burns
  /// nothing) instead of hanging the face-check UI.
  final Duration verifyTimeout;

  /// Upper bound for the one-time bundled-model + store load.
  final Duration initTimeout;

  PluginFaceVerifier({
    MainIsolateVerify? verifyForTest,
    this.verifyTimeout = const Duration(seconds: 10),
    this.initTimeout = const Duration(seconds: 30),
  })  : _verifyForTest = verifyForTest,
        _plugin = verifyForTest == null ? FaceVerification.instance : null;

  @override
  Future<void> init() async {
    requireMobileFace();
    if (_ready) return;
    // Test seam: with an injected verify delegate there is no real plugin
    // to initialize (flutter_test has no native channels).
    if (_verifyForTest != null) {
      _ready = true;
      return;
    }
    // Quick-Demo pattern: init loads the bundled FaceNet TFLite + store.
    try {
      await _plugin!.init().timeout(initTimeout);
    } on TimeoutException catch (e) {
      // Hung model load (stuck native call): fail closed with a
      // rescan-safe StateError (callers map this to inconclusive/error,
      // never a throw past them), never a hang of the face-check UI.
      throw StateError(
          'Face engine timed out loading — retry in good light, holding still ($e)');
    } catch (e) {
      // Missing/corrupt model: fail closed with a rescan-safe StateError
      // (callers map this to inconclusive/error, never a throw past them).
      throw StateError('Face engine unavailable — reinstall and try again ($e)');
    }
    _ready = true;
  }

  /// Fail-closed still validation BEFORE any native call: empty paths,
  /// missing files and zero-byte frames crash the native detector below
  /// the Dart catch, so they throw here as rescan-safe StateErrors the
  /// driver/controller map to inconclusive/error (never a throw past them,
  /// never a false pass). Native-only file (dart:io never reaches web).
  void _requireReadableStill(String imagePath, String slot) {
    if (imagePath.trim().isEmpty) {
      throw StateError(
          'The $slot still came out blank — recapture in good light, holding still.');
    }
    late final File f;
    try {
      f = File(imagePath);
      if (!f.existsSync()) {
        throw StateError(
            'The $slot still is unreadable (file missing) — recapture in good light, holding still.');
      }
      if (f.lengthSync() == 0) {
        throw StateError(
            'The $slot still came out blank — recapture in good light, holding still.');
      }
    } on StateError {
      rethrow;
    } catch (e) {
      throw StateError(
          'The $slot still is unreadable — recapture in good light, holding still ($e)');
    }
  }

  @override
  Future<void> enroll(String faceId, List<String> imagePaths) async {
    requireMobileFace();
    if (faceId.trim().isEmpty) {
      throw ArgumentError('enroll needs a non-empty faceId');
    }
    if (imagePaths.length != faceEnrollSlots.length) {
      throw ArgumentError(
          'enroll needs ${faceEnrollSlots.length} stills (centre/left/right/up/down), got ${imagePaths.length}');
    }
    for (var i = 0; i < imagePaths.length; i++) {
      _requireReadableStill(imagePaths[i], faceEnrollSlots[i]);
    }
    await init();
    // Clean re-enroll: previous faces for this id go first so a changed
    // appearance never matches against a stale still.
    try {
      await _plugin!.deleteUserFaces(faceId);
    } catch (_) {
      // No previous enrollment — nothing to clear.
    }
    for (var i = 0; i < imagePaths.length; i++) {
      // Slot context on failure: the plugin reports 'No face detected'
      // without saying which still — the wrapper names it so the UI can
      // point the rescan at the right angle.
      try {
        await _plugin!.registerFromImagePath(
          id: faceId,
          imagePath: imagePaths[i],
          imageId: faceEnrollSlots[i],
        );
      } catch (e) {
        throw StateError(
            'The ${faceEnrollSlots[i]} still did not read clearly — recapture just that angle in good light, holding still ($e)');
      }
    }
  }

  @override
  Future<FaceVerifyResult> verify(String faceId, String imagePath,
      {double threshold = kFaceThreshold}) async {
    requireMobileFace();
    // Empty-frame guard first: never hand empty bytes to native.
    _requireReadableStill(imagePath, 'captured');
    await init();
    // Marking hot path: the MAIN-ISOLATE verify — the plugin's supported
    // path. The isolate variant (`verifyFromImagePathIsolate`) is NEVER
    // used here: it runs ML Kit face detection on a background isolate via
    // BackgroundIsolateBinaryMessenger, and the success reply on that
    // background response handle aborts the engine with
    // `FATAL platform_message_response_dart_port.cc Check failed: did_send`
    // → SIGABRT (temp.log 2026-09-10, uncatchable in Dart — no try/catch,
    // no timeout, no driver mapping can survive it). Main-isolate
    // detection measured ~290ms in that same log; the existing busy UI
    // covers it, so no new user-visible step is needed.
    //
    // Exactly ONE plugin call per verify (no retry loop here): a second
    // in-flight MethodChannel reply for the same response handle is the
    // same crash class, so single-invocation is load-bearing, not style.
    // It returns the matched id or null — never a distance.
    late final String? hit;
    try {
      final call = _verifyForTest != null
          ? _verifyForTest(
              imagePath: imagePath, threshold: threshold, staffId: faceId)
          : _plugin!.verifyFromImagePath(
              imagePath: imagePath, threshold: threshold, staffId: faceId);
      hit = await call.timeout(verifyTimeout);
    } on TimeoutException catch (e) {
      // Hung native call (stuck detector/embedder): fail closed as a
      // rescan-safe error — the driver maps this to inconclusive (rescan
      // path, burns nothing), never a hang, never a mis-mark.
      throw StateError(
          'Face check timed out — adjust light and try again ($e)');
    } catch (e) {
      // ANY infrastructure throw (unreadable still, closed store, native
      // error): fail closed as a rescan-safe error — the driver maps this
      // to inconclusive (rescan path, burns nothing), never a crash,
      // never a mis-mark. A readable null below stays the only non-match.
      throw StateError(
          'Face check did not read clearly — adjust light and try again ($e)');
    }
    // Nullable plugin result, guarded WITHOUT `!`: null covers no-face,
    // unreadable and below-threshold alike — all non-match. (The driver
    // maps unreadable throws to inconclusive before this; a readable null
    // here is a conservative non-match that never auto-presents.)
    final match = hit != null && hit == faceId;
    // Plugin returns identity only, not a distance: carry the decision
    // boundary on match (see file header + face_verifier.dart header —
    // honest, host re-checks score >= T). A measured distance is
    // unavailable by plugin contract, so the boundary is kept with this
    // note rather than an invented similarity; field ROC (see header) is
    // the procedure that may move T, never a constant tweak.
    return FaceVerifyResult(score: match ? threshold : 0.0, match: match);
  }

  @override
  Future<void> remove(String faceId) async {
    requireMobileFace();
    await init();
    await _plugin!.deleteUserFaces(faceId);
  }

  @override
  Future<List<double>> embeddingFor(String faceId) async {
    requireMobileFace();
    if (faceId.trim().isEmpty) {
      throw ArgumentError('embeddingFor needs a non-empty faceId');
    }
    await init();
    // The plugin API is identity-only for VERIFY, but the gallery records
    // (512-d FaceNet embeddings per enroll slot) are readable via
    // getFacesForUser — no fork needed. Member access is inference-only on
    // purpose: FaceRecord is not re-exported by the plugin's public
    // library, so this couples to the method + `.embedding` member (breaks
    // loudly on plugin upgrade, same as any API drift).
    final records = await _plugin!.getFacesForUser(faceId);
    if (records.isEmpty) {
      throw StateError(
          'No enrolled face found on this phone — recapture in good light, holding still.');
    }
    try {
      return faceMeanEmbedding([
        for (final r in records)
          (r.embedding as List).map((e) => (e as num).toDouble()).toList(),
      ]);
    } catch (_) {
      throw StateError(
          'Enrolled face data was unreadable — re-enroll this device from the home screen, then join again.');
    }
  }

  @override
  String get verifierVer => kFaceVerifierVer;
}
