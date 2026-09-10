// EnrollCapture — CONTINUOUS multi-angle face session
// (Android-face-unlock-style). ONE camera session opened once and closed
// on done/cancel.
//
// THIN COMPOSER (2026-09-10 breakup — see INTEGRATION_LOG.md
// `## Enroll capture breakup`). This file owns build ONLY:
//   enroll_capture_session.dart — camera seam + session driver (open/close,
//     classify-fill loop, save, dispose, timers; relocated verbatim).
//   enroll_capture_sections.dart — section widgets (bare preview
//     surface, bottom bar, slot top-up, blocked card).
// No driver state, no timers, no camera calls live here: the State mixes
// in [EnrollCaptureSessionDriver] and reads it through its public getters.
//
// Preview fidelity (squish fix, hardened 2026-09-10 — see
// INTEGRATION_LOG.md `## Capture preview fidelity`): the feed renders as
// a BARE CameraPreview at its native aspect (zero treatment — no wrapper
// of any kind; the plugin self-maintains its ratio under the loose,
// centered Stack, so NO stretch, NO cover-crop, NO double-boxing).
// Everything else on the page (progress bar, oval+comet, prompt,
// fallback buttons) lives in the overlay layer above the untouched
// preview surface. Reduced-motion behavior preserved (sweep timer never
// starts; comet parks statically at the target).
// Edge-to-edge (2026-09-10 — see INTEGRATION_LOG.md `## Edge-to-edge
// capture`): the Scaffold extends the body behind the status bar and a
// transparent overlay app bar, so the bare feed fills edge-to-edge with
// chrome floating above it (top bar clears the app bar via the overlay
// inset + SafeArea; toast + bottom bar are SafeArea-seated).
//
// Guidance is the shared single-oval overlay (PRODUCT-OWNER OVERRIDE
// 2026-09-10, supersedes §6.2 two-oval rule — see INTEGRATION_LOG.md
// `## Overlay redesign`): ONE slim progress bar pinned below the app bar
// (overall completion), ONE static oval + ONE glowing green comet —
// bright head plus short fading tail —
// (live head-position target for the next unfilled angle), ONE prompt
// below the oval (rotate slowly, follow the glow) — no dots, no labels,
// no extra rings/progress arcs. Provenance: Apple Face ID enrollment
// (one imperative + rim progress) and Tobii "follow the target"
// calibration (one target, 5 points, repeat missing).
// Under the paint, buckets keep filling opportunistically
// (EnrollBucketFill.classifyInto on one readPose per still); the top bar
// is the sole completion indicator. Rejects stay SILENT in-UI
// (BleLog only). Under reduced motion the sweep timer never starts and
// the comet parks statically at the target with a minimal tail.
//
// Gallery write is single + terminal (controller.enrollFace → plugin
// enroll + centre self-check); marking verify untouched. HONESTY: five
// pose-diverse templates buy robustness + spoof cost, NOT photo-spoof
// immunity (passive matcher residual, §4). Mobile-only (L2, blocked
// card); fail-closed save; cancel enrolls nothing and disposes camera.
//
// Re-export: the camera seam still resolves through this library so
// existing overrides (`enrollSessionCameraProvider`,
// `FakeEnrollSessionCamera`) keep compiling untouched.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enrollment.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../features/face_identity/face_verifier.dart';
import 'enroll_capture_sections.dart';
import 'enroll_capture_session.dart';
import 'enroll_flow.dart';
import 'enroll_widgets.dart';
import 'setup_step_scope.dart';

export 'enroll_capture_session.dart';

class EnrollCaptureScreen extends ConsumerStatefulWidget {
  const EnrollCaptureScreen({super.key});

  @override
  ConsumerState<EnrollCaptureScreen> createState() =>
      _EnrollCaptureScreenState();
}

/// Thin composer: lifecycle delegates to the driver, build composes the
/// sections. The ONLY method owned here is [_cancel] (navigation); every
/// other body lives in [EnrollCaptureSessionDriver] verbatim.
class _EnrollCaptureScreenState extends ConsumerState<EnrollCaptureScreen>
    with EnrollCaptureSessionDriver {
  @override
  void initState() {
    super.initState();
    initCaptureSession();
  }

  @override
  void dispose() {
    disposeCaptureSession();
    super.dispose();
  }

  void _cancel() {
    EnrollLog.face(
        'session cancelled — nothing enrolled ($doneCount/$slotTotal filled, discarded)');
    // STEP-SCOPE: inside SetupFlow, Cancel steps back instead of popping
    // the shell tab route (standalone pop preserved).
    final scope = SetupStepScope.of(context);
    if (scope != null) {
      scope.back();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(enrollmentControllerProvider);
    // L2 assert: records-only devices never reach the camera.
    if (!canUseFace()) {
      return EnrollCaptureBlocked(
        onBack: () {
          // STEP-SCOPE: inside SetupFlow, Back steps back instead of
          // popping (standalone pop preserved).
          final scope = SetupStepScope.of(context);
          if (scope != null) {
            scope.back();
          } else {
            Navigator.of(context).pop();
          }
        },
      );
    }
    final validated =
        st.phase == EnrollPhase.faceDone || st.phase == EnrollPhase.uploaded;
    final noKey = st.pkHex.isEmpty;
    final saveError = st.phase == EnrollPhase.error &&
        st.message.isNotEmpty &&
        doneCount == slotTotal;
    final total = slotTotal;
    final reduced = ProxMotion.reduced(context);
    // Message for the preview's fail branch (denied / failed / no-key).
    final previewMessage = isFailed
        ? (isDenied
            ? 'Camera permission is needed for the face check — allow it in settings, then come back. Nothing is enrolled yet.'
            : 'The camera did not start — nothing is enrolled yet. Go back and try again.')
        : 'Generate the device key on the previous screen first — the face capture seals to it.';
    // Fail-closed preview states (frozen copy): denied / failed / no-key
    // replace the feed; the opening spinner shows until open completes.
    final failMessage =
        isDenied || isFailed || (!isOpening && noKey) ? previewMessage : null;
    // Edge-to-edge (2026-09-10 — see INTEGRATION_LOG.md
    // `## Edge-to-edge capture`): the preview extends behind the status
    // bar and the app bar — transparent overlay app bar, body fullscreen
    // behind it. Cancel stays wired to the existing [_cancel] nav
    // (STEP-SCOPE intact); the overlay top bar clears the app bar via
    // `overlayTopInset` + SafeArea while the video paints under it.
    return Scaffold(
      extendBodyBehindAppBar: true,
      extendBody: true,
      appBar: AppBar(
        title: const Text('Face capture'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          // Cancel is label-truthful in every state: dispose the session
          // camera and enroll nothing (fail-closed). Dispose-safe: pop
          // latches _cancelled, the loop/awaits all re-check it.
          TextButton(
            onPressed: _cancel,
            child: const Text('Cancel'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Preview region (audit vs FaceCaptureScreen in
          // lib/screens/face_capture.dart — no SafeArea in either camera
          // path (no double-apply); THIS screen now extends behind the
          // status bar + transparent overlay app bar (extendBody +
          // extendBodyBehindAppBar true, same AppBar height, Cancel
          // unchanged) so the preview fills edge-to-edge — the still
          // modal keeps its own opaque chrome (out of scope, untouched).
          // Squish fix (2026-09-10 breakup): the feed renders letterboxed
          // (AspectRatio on the controller's own ratio, plain bars) — never
          // stretched, never cover-cropped. Kept deviations, one line each:
          // (a) AppBar title 'Face capture' (flow-specific, same height).
          // (b) Preview message covers denied/failed/no-key (fail-closed gate).
          // (c) Null-controller placeholder (test fake only, never on-device).
          // (d) THE shared single-oval overlay + save-error toast — no
          //     dots, no per-angle labels.
          // (e) Mid-flow chrome lives in the overlay (top bar + oval +
          //     single prompt); the bottom bar stays empty mid-flow.
          // (f) Validated Continue / save-error Try-again + shared hidden
          //     top-up (back-nav stable).
          // (g) Blocked path uses ProxScreen (no camera, shared shell).
          // Save-error Notice rides as a toast overlay (same widget/message,
          // zero layout) so message length never moves the feed.
          // Layering (researched, deliberate): chrome stays OVERLAY — the
          // overlay paints inside the preview Stack, prompt/buttons in the
          // bottom bar — never inline above the feed. Native viewfinders
          // composite chrome the same way (CameraX PreviewView overlay
          // siblings; iOS AVCaptureVideoPreviewLayer with sibling overlay
          // views, never subviews), and the original screen used overlay +
          // bottom bar too.
          Expanded(
            child: EnrollCapturePreview(
              controller: previewController,
              isOpening: isOpening,
              failMessage: failMessage,
              doneCount: doneCount,
              total: total,
              nextAngle: nextAngle,
              // Verified 5 via faceEnrollSlots, never hardcoded.
              totalAngles: faceEnrollSlots.length,
              statusLine: enrollCapturePrompt,
              sweepAngle: reduced ? null : sweepValue,
              saveError: saveError,
              saveMessage: st.message,
              // Clears the transparent overlay app bar above.
              overlayTopInset: kToolbarHeight,
            ),
          ),
          // Bottom bar: validated shows Continue, save-error shows
          // Try-again (+ the shared hidden top-up, back-nav stable).
          // Mid-flow stays empty — the overlay carries the single prompt.
          EnrollCaptureBottomBar(
            validated: validated,
            saveError: saveError,
            saving: isSaving,
            onContinue: () {
              // STEP-SCOPE: inside SetupFlow, Continue advances the
              // stepper instead of pushing the standalone route.
              final scope = SetupStepScope.of(context);
              if (scope != null) {
                scope.next();
              } else {
                EnrollFlow.openResult(context);
              }
            },
            onRetry: retrySave,
          ),
        ],
      ),
    );
  }
}
