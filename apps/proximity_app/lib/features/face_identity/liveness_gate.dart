// LivenessGate: the ONE narrow on-device anti-spoof interface
// (PROXIMITY_SECURITY.md §4, F4 fix). Everything anti-spoof in the app goes
// through here — enrollment active challenges + marking passive check. No
// images ever leave the device: the gate owns its classifier; the app only
// sees {score, ver} and binds them into Sig_s via the extended face ticket
// (ProxCrypto.faceTicketHash with livenessScore/livenessVer — the host
// re-checks score>=Tl + the liveness allowlist, so transplanting a score
// across tickets fails as bad-sig/liveness-unbound, never a silent pass).
//
// Flows (spec §4):
//   enroll  = ACTIVE blink+smile (Fisher-Yates shuffled via
//             [shuffledActiveChallenges], offline) + PASSIVE centre-still
//             ([detectPassive] on the centre capture).
//   marking = PASSIVE only on the single check still (~1s budget, no
//             prompts — the holder just holds still).
//
// Backend: passive MiniFASNetV2-SE family. The pipeline tag [kLivenessVer]
// pins WHICH scorer produced the score; a scorer swap ships as a new tag
// and forces re-face via the stale-pipeline check (key kept) — same
// versioning contract as [kFaceVerifierVer].
// Heuristic-v1 honesty note: the vendored MiniFASNetV2-SE ONNX weights
// (~600KB, ~98.2% CelebA-Spoof target) need `tflite_flutter` (pubspec is
// 1B-owned — requested, not added here), so the native scorer below is an
// offline texture heuristic (Laplacian sharpness + chroma diversity +
// specular fraction, pure Dart + dart:ui decode, no network, no
// license-key SDK). It raises photo/screen-replay cost and FAILS CLOSED
// on unreadable/unsupported stills, but it is NOT photo-spoof immunity:
// a sharp print can still pass it. Same honesty contract as the pose
// gates (cost, not immunity) — see the residual in PROXIMITY_DESIGN.md §4.
// FAR/FRR for heuristic-v1 are UNMEASURED (no Proximity ROC yet); the
// face operating point note on face_verifier.dart still applies to the
// matcher half only. The adversarial drill + 2-phone relay (sec-verify)
// stay required.
//
// L1 mobile gate: [detectPassive] calls [requireMobileFace] first —
// desktop/web fail closed (records-only stub below throws before any
// decode; SK never signs without a real holder check).
library;

import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'liveness_gate_native.dart'
    if (dart.library.html) 'liveness_gate_stub.dart';

/// Opaque liveness pipeline tag stored on the ticket and bound into every
/// Sig_s ticket. Format: `liveness/<model>+<scorer>` (mirrors the
/// `face_verification/<pkgVer>+<assetHash8>` shape). The host allowlists on
/// the `liveness/` prefix; a stricter course pins the full tag. Bumping the
/// scorer suffix (e.g. `+heuristic-v1` → `+<weightsHash8>` when the ONNX
/// weights vendor) invalidates old tickets — re-face only, key kept.
const kLivenessVer = 'liveness/minifasnet-v2-se+heuristic-v1';

/// Active enroll challenges: blink + smile, prompted in shuffled order.
/// Passive only for marking (no prompts there — single still, ~1s).
enum LivenessAction { blink, smile }

/// Fisher-Yates shuffle of the enroll active challenges (offline, no
/// network). A seeded [Random] drives deterministic unit tests; production
/// passes none (Random.secure). The order is the anti-replay property: a
/// pre-recorded clip cannot predict which prompt comes first.
List<LivenessAction> shuffledActiveChallenges({Random? rng}) {
  final r = rng ?? Random.secure();
  final list = [...LivenessAction.values];
  for (var i = list.length - 1; i > 0; i--) {
    final k = r.nextInt(i + 1);
    final t = list[i];
    list[i] = list[k];
    list[k] = t;
  }
  return list;
}

/// Pure scorer core (no native calls, unit-tested): maps the three
/// heuristic-v1 texture features (each already 0..1 normalized by the
/// platform decoder) to one 0..1 vitality score on the same milli scale as
/// the face score. Weights are heuristic-v1 judgment (see the file header —
/// uncalibrated, pending ROC + ONNX scorer); the host threshold Tl=0.70
/// ([kLivenessThreshold]) applies to the OUTPUT, never to the features.
double combineLivenessFeatures({
  required double sharpness,
  required double chroma,
  required double specular,
}) {
  double c(double v) => v.clamp(0.0, 1.0);
  return (0.45 * c(sharpness) + 0.35 * c(chroma) + 0.20 * c(specular))
      .clamp(0.0, 1.0);
}

/// Result of one passive anti-spoof pass: vitality score + pipeline tag.
/// `ver` is [kLivenessVer] on real runs (the ticket binds it); fakes in
/// tests pin their own tag (allowlist-carrying tests set full tags).
class LivenessResult {
  final double score;
  final String ver;
  const LivenessResult({required this.score, required this.ver});
}

/// Narrow anti-spoof interface (one file, no wrappers).
abstract class LivenessGate {
  /// Passive anti-spoof on one still file (marking hot path, ~1s budget;
  /// enroll centre-still). Returns {score, ver}. Throws StateError when
  /// the still is unreadable/unsupported or the platform cannot run the
  /// classifier — fail-closed (callers map throws to inconclusive/rescan,
  /// never a pass, never a throw past them).
  Future<LivenessResult> detectPassive(String imagePath);
}

/// Test-only fake (same role FakeFaceVerifier plays): scripted score/ver,
/// records calls, optional fail-closed throw. Never shipped (DI wires the
/// platform gate / stub).
class FakeLivenessGate implements LivenessGate {
  double score;
  String ver;
  final List<String> calls = [];

  /// When true, [detectPassive] throws StateError (unreadable-still path).
  bool throwOnDetect;
  FakeLivenessGate({
    this.score = 0.92,
    this.ver = kLivenessVer,
    this.throwOnDetect = false,
  });

  @override
  Future<LivenessResult> detectPassive(String imagePath) async {
    calls.add(imagePath);
    if (throwOnDetect) {
      throw StateError(
          'Liveness check did not read clearly — adjust light and try again.');
    }
    return LivenessResult(score: score, ver: ver);
  }
}

/// DI seam: production wires [HeuristicLivenessGate] (resolving to the web
/// fail-closed stub on records builds via the conditional export above —
/// same pattern as faceVerifierProvider); tests override with
/// [FakeLivenessGate]. RealStudentDriver defaults to the platform gate so
/// main.dart needs no new override (2C-owned file, untouched).
final livenessGateProvider = Provider<LivenessGate>((ref) {
  throw UnimplementedError('Override in main / tests');
});
