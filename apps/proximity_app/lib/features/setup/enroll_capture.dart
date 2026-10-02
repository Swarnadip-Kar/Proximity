// EnrollCapture — CONTINUOUS multi-angle face session
// (Android-face-unlock-style). ONE camera session opened once and closed
// on done/cancel.
//
// (Post `## Enroll capture breakup` in INTEGRATION_LOG). This file owns
// build ONLY:
//   enroll_capture_session.dart — camera seam + session driver (open/close,
//     classify-fill loop, save, dispose, timers; relocated verbatim).
//   enroll_capture_sections.dart — section widgets (bare preview
//     surface, bottom bar, slot top-up, blocked card).// No driver state, no timers, no camera calls live here: the State mixes
// in [EnrollCaptureSessionDriver] and reads it through its public getters.
//
// Preview fidelity (squish fix, hardened 2026-09-10 — see
// `## Capture preview fidelity` in INTEGRATION_LOG): the surface is
// a BARE CameraPreview at its native aspect (zero treatment — no wrapper
// of any kind; the plugin self-maintains its ratio under the loose,
// centered Stack, so NO stretch, NO cover-crop, NO double-boxing).
// Everything else on the page (progress bar, oval+comet, prompt,
// fallback buttons) lives in the overlay layer above the untouched
// preview surface. Reduced-motion behavior preserved (sweep timer never
// starts; comet parks statically at the target).
// Edge-to-edge (see `## Edge-to-edge capture` in INTEGRATION_LOG): the
// Scaffold extends the body behind the status bar and a transparent overlay app bar, so the bare feed fills edge-to-edge with
// chrome floating above it (top bar clears the app bar via the overlay
// inset + SafeArea; toast + bottom bar are SafeArea-seated).
//
// Overlay contract (see `## Overlay redesign` in INTEGRATION_LOG): ONE
// slim progress bar filling the preview bottom edge (overall completion),
// ONE static oval + ONE glowing green comet —
// bright head plus short fading tail —
// (live head-position target for the next unfilled angle), ONE prompt
// below the oval (rotate slowly, follow the glow) — no dots, no labels,
// no extra rings/progress arcs. Provenance: Apple Face ID enrollment
// (one imperative + rim progress) and Tobii "follow the target"
// calibration (one target, 5 points, repeat missing).
// Under the paint, buckets keep filling opportunistically
// (EnrollBucketFill.classifyInto on one readPose per still); the bottom
// bar is the sole completion indicator. Rejects stay SILENT in-UI
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

import 'dart:async';

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
import 'flash_assist.dart';
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
  /// Single-flight for validated Continue: a double-tap never fires two
  /// stepper advances or two result pushes (the stepper drops overlaps
  /// via its own guard and EnrollFlow drops a second push while one
  /// result is open — this latch covers the gap before either engages).
  var _continueBusy = false;
  @override
  void initState() {
    super.initState();
    // Key restore happens inside the session open ([_openCamera] restores
    // before the camera permission prompt and the key gate), so a rescan
    // after restart — or the Accounts Re-scan entry — never meets a
    // keyless draft. No second reconcile here: one owner, no race.
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
    // Slot-naming refusal (liveness/Euler FAIL): the toast copy promises
    // single-slot recapture — the bottom bar offers it (other buckets
    // kept). Plain transient errors keep Try-again only.
    final recaptureSlot = saveError
        ? ref.read(enrollmentControllerProvider.notifier).lastFailedSlot
        : null;
    final total = slotTotal;
    final reduced = ProxMotion.reduced(context);
    // Message for the preview's fail branch (denied / failed / no-key).
    // Locked (enrollment doc found, key behind the lock) gets unlock +
    // retry copy instead of the generate-first copy — same distinction
    // the enrollFace key gate draws.
    final previewMessage = isFailed
        ? (isDenied
            ? 'Camera permission is needed for the face check — allow it in settings, then come back. Nothing is enrolled yet.'
            : 'The camera did not start — nothing is enrolled yet. Go back and try again.')
        : restoreLocked
            ? 'Couldn’t unlock this device’s key — approve the phone prompt, then try again.'
            : 'Generate the device key on the previous screen first — the face capture seals to it.';
    // Flash assist (dark room): graded ring-light level + window
    // brightness via the sync shell below (restored after). Live room
    // reading when a sensor reports (instant), capture-brightness
    // fallback otherwise — pure derivation, no new timers here.
    final assist = flashAssist;
    final level = flashLevel;
    // Fail-closed preview states (frozen copy): denied / failed / no-key
    // replace the feed; the opening spinner shows until open completes.
    final failMessage =
        isDenied || isFailed || (!isOpening && noKey) ? previewMessage : null;
    // Preview sits BELOW the app bar (opaque, default theme bar — the
    // feed never paints under chrome): body starts under the bar, and the
    // oval is derived from the undistorted video box only. Cancel stays
    // wired to [_cancel].
    return Scaffold(
      // No editable text lives on this screen (and entry unfocuses on the
      // way in): the keyboard must never resize/squish the preview.
      resizeToAvoidBottomInset: false,
      extendBodyBehindAppBar: false,
      extendBody: true,
      appBar: AppBar(
        title: const Text('Face capture'),
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
          // Brightness shell for the flash assist: maxes the window while
          // the session is dark, restores after (renders nothing itself).
          FlashAssistSync(
            active: assist,
            control: ref.read(enrollScreenBrightnessProvider),
          ),
          // Preview region (below the opaque app bar — no SafeArea in
          // either camera path (no double-apply); the body starts under
          // the bar so the feed never slides under chrome.
          // Squish fix (2026-09-10 breakup): the feed renders letterboxed
          // (AspectRatio on the controller's own ratio, plain bars) — never
          // stretched, never cover-cropped. Kept deviations, one line each:
          // (a) AppBar title 'Face capture' (flow-specific, same height).
          // (b) Preview message covers denied/failed/no-key (fail-closed gate).
          // (c) Null-controller placeholder (test fake only, never on-device).
          // (d) THE shared single-oval overlay + save-error toast — no
          //     dots, no per-angle labels.
          // (e) Mid-flow chrome lives in the overlay (bottom fill bar +
          //     oval + single prompt); the bottom bar stays empty mid-flow.
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
              // Dark stall (3 consecutive dark probes): the overlay prompt
              // becomes the move-to-light line — a dark room needs an
              // unmissable instruction, not the angle guidance (which
              // returns as soon as a bright probe lands). Faceless/no-fill
              // stall (pose blind, or spinning with no fills): the nudge
              // below. Bright/unknown sessions never take any branch.
              statusLine: darkStall
                  ? 'Too dark — move to brighter light'
                  : ((fillStall || blindStall)
                      ? 'No good capture yet — face the lens in brighter light'
                      : enrollTargetPrompt(targetSlot)),
              sweepAngle: reduced ? null : sweepValue,
              saveError: saveError,
              saveMessage: st.message,
              // Live guidance wheels: the ordered target + latest head
              // angles ride the overlay; capture verdicts stay in the
              // driver (wheels never accept, the loop does).
              targetSlot: targetSlot,
              liveYaw: liveYaw,
              livePitch: livePitch,
              // Locked key gate (not a missing key): in-place retry that
              // re-runs restore + camera open (re-prompts past cooldown).
              restoreLocked: restoreLocked && failMessage != null,
              onRetryRestore: () => retryRestoreAndOpen(),
              // Ring-light level while the session believes it is dark
              // (graded by measured darkness — see [flashLevel]; preview
              // geometry untouched).
              flashLevel: level,
              // The toast owns the message on error — hide the rotating
              // prompt so the two never stack on small preview areas.
              promptVisible: !saveError,
              // No inset: the bar is opaque and the body starts below it.
              overlayTopInset: 0.0,
            ),
          ),
          // Bottom bar: validated shows Continue, save-error shows
          // Try-again (+ slot recapture when a slot was named, + the
          // shared hidden top-up, back-nav stable).
          // Mid-flow stays empty — the overlay carries the single prompt.
          EnrollCaptureBottomBar(
            validated: validated,
            saveError: saveError,
            saving: isSaving,
            recaptureSlot: recaptureSlot,
            // Live vitality + target readout under the button slot.
            liveReadout: liveReadout,
            onRecapture: recaptureSlot == null
                ? null
                : (slot) => retrySlot(slot),
            onContinue: () {
              // STEP-SCOPE: inside SetupFlow, Continue advances the
              // stepper instead of pushing the standalone route.
              // Single-flight: validated double-tap never pushes two
              // result routes (see _continueBusy + EnrollFlow guard).
              if (_continueBusy) return;
              _continueBusy = true;
              final scope = SetupStepScope.of(context);
              if (scope != null) {
                unawaited(scope
                    .next()
                    .whenComplete(() => _continueBusy = false));
              } else {
                try {
                  final pushed = EnrollFlow.openResult(context);
                  unawaited(pushed.whenComplete(() {
                    if (mounted) _continueBusy = false;
                  }));
                } catch (_) {
                  _continueBusy = false;
                  rethrow;
                }
              }
            },
            onRetry: retrySave,
          ),
        ],
      ),
    );
  }
}
