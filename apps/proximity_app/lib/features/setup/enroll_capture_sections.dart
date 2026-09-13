// EnrollCapture section widgets — one purpose per widget.
//
// SPLIT from enroll_capture.dart (2026-09-10 breakup): the composer
// (enroll_capture.dart) owns NO layout below the Scaffold/Column level:
// every region below is one of these sections. The session driver lives in
// enroll_capture_session.dart and is never touched here (pure props in,
// widgets out — sections read no providers).
//
// SQUISH FIX (preview fidelity, hardened 2026-09-10): the preview surface
// is a BARE `CameraPreview` — zero treatment, no Container/Box/decoration/
// effect/fit of any kind around it. `CameraPreview` self-maintains its
// native aspect internally, so the Stack uses a loose fit and centers it:
// loose constraints let it letterbox itself, while `StackFit.expand` (or
// any `FittedBox`/`BoxFit`) would force-fill it and stretch the faces.
// Everything else on the page (progress bar, oval + comet, prompt,
// fallback buttons) lives in the overlay layer ABOVE the untouched
// surface. Retired chains: `FittedBox(BoxFit.cover)` cropped the face
// area; full-bleed sizing stretched it; an outer `AspectRatio` wrapper
// around `CameraPreview` double-boxed it against the plugin's own
// orientation-adjusted ratio — all three banned here by test pin.
// Reduced-motion behavior is preserved (the sweep timer still never starts
// under [ProxMotion.reduced]; the comet parks statically at the target —
// that contract lives in the driver + CaptureOverlay, untouched).
//
// capture`): the composer extends the body behind the status bar + a
// transparent overlay app bar; this file only threads the top inset
// through ([EnrollCapturePreview.overlayTopInset] → overlay `topInset`)
// and seats bottom chrome (toast + bottom bar) in SafeAreas so it avoids
// the notch/nav bar while the video fills under it. The preview surface
// itself is untouched (bare/native-aspect, loose Stack).
//
// Frozen (do NOT change here): all copy (fail messages, Continue /
// Try again / Back, the single enroll prompt), the save-error toast widget
// + message, STEP-SCOPE navigation (owned by the composer), auto-capture
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/tokens.dart';
import '../../features/face_identity/face_blocked.dart';
import '../../widgets/capture_overlay.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_scaffold.dart';
import 'enroll_widgets.dart';

/// Displayed preview ratio — the aspect `CameraPreview` actually paints.
/// Mirrors the plugin's own orientation adjustment (`landscape ? raw :
/// 1/raw`, resolved from recording/locked/pause/device orientation in the
/// same precedence) using only public [CameraValue] fields, so the overlay
/// derives its oval/comet from the TRUE video box. (Passing the raw sensor
/// ratio instead double-boxes against the plugin internals and re-squishes
/// the guide on portrait phones.) Pure for unit tests.
double displayedPreviewAspect(CameraValue value) {
  final raw = value.aspectRatio;
  final orientation = value.isRecordingVideo
      ? value.recordingOrientation!
      : (value.previewPauseOrientation ??
          value.lockedCaptureOrientation ??
          value.deviceOrientation);
  final landscape = orientation == DeviceOrientation.landscapeLeft ||
      orientation == DeviceOrientation.landscapeRight;
  return landscape ? raw : 1 / raw;
}

/// Preview region in every state: fail message / opening spinner / bare
/// live feed with the shared overlay + save-error toast layered above it.
/// Single purpose: everything inside the preview area.
///
/// Layering: the bare preview is a DIRECT Stack child (zero treatment —
/// no wrapper of any kind); the overlay paints above it in the same Stack
/// (not beside it), pointer-transparent; the save-error Notice rides as a
/// toast overlay (zero layout) so message length never moves the feed;
/// retry lives in the bottom bar.
class EnrollCapturePreview extends StatelessWidget {
  /// Live preview source (null until open completes / always null in the
  /// test fake → undecorated spacer, never on-device).
  final CameraController? controller;

  /// Test seam (the camera plugin has no test double): when non-null,
  /// this widget IS the preview surface (rendered bare, as a direct Stack
  /// child) instead of `CameraPreview(controller)`. Null on-device.
  final Widget? preview;

  /// Test seam for [preview]: the overlay derives its oval/comet from this
  /// video box. Null resolves from the controller via
  /// [displayedPreviewAspect] (uninitialized/test fake → full-size
  /// fallback, same as the placeholder).
  final double? previewAspectRatio;

  /// Camera still opening (spinner branch).
  final bool isOpening;

  /// Fail-closed message replacing the preview (denied / failed / no-key
  /// copy, owned verbatim by the composer). Null while capturing.
  final String? failMessage;

  /// Accepted-still count + slot total (overlay progress = done/total).
  final int doneCount;
  final int total;

  /// Overlay head-position target (next unfilled slot) + slot count.
  final int nextAngle;
  final int totalAngles;

  /// The ONE prompt line (frozen `enrollCapturePrompt`).
  final String statusLine;

  /// Beacon travel angle, or null under reduced motion (static target).
  final double? sweepAngle;

  /// Fail-closed save-error chrome (toast + bottom-bar retry).
  final bool saveError;
  final String saveMessage;

  /// Prompt-line visibility for the overlay (default true): the composer
  /// hides the rotating prompt while the save-error toast owns the
  /// message, so the two never stack on small preview areas.
  final bool promptVisible;

  /// Edge-to-edge top inset forwarded to the overlay's top bar so it
  /// clears the transparent overlay app bar (composer passes the app-bar
  final double overlayTopInset;

  const EnrollCapturePreview({
    super.key,
    required this.controller,
    required this.isOpening,
    required this.failMessage,
    required this.doneCount,
    required this.total,
    required this.nextAngle,
    required this.totalAngles,
    required this.statusLine,
    required this.sweepAngle,
    required this.saveError,
    required this.saveMessage,
    this.preview,
    this.previewAspectRatio,
    this.overlayTopInset = 0.0,
    this.promptVisible = true,
  });

  @override
  Widget build(BuildContext context) {
    final fail = failMessage;
    if (fail != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(fail, textAlign: TextAlign.center),
        ),
      );
    }
    if (isOpening) {
      return const Center(child: CircularProgressIndicator());
    }
    final ctl = controller;
    // Displayed video-box aspect for the overlay: the overlay MUST derive
    // its oval/comet from this same box, never the full Stack size —
    // otherwise the guide drifts off the undistorted feed whenever the
    // screen differs from the sensor. Explicit test-seam value wins;
    // otherwise resolve from the live controller (orientation-adjusted via
    // [displayedPreviewAspect]); uninitialized/test fake → null keeps the
    // full-size fallback with zero visual change on the placeholder.
    double? previewAspect = previewAspectRatio;
    if (previewAspect == null && ctl != null) {
      try {
        if (ctl.value.isInitialized) {
          final a = displayedPreviewAspect(ctl.value);
          if (a.isFinite && a > 0) previewAspect = a;
        }
      } catch (_) {
        previewAspect = null;
      }
    }
    // ZERO treatment: the preview surface is a DIRECT Stack child — bare
    // `CameraPreview` (which self-maintains its native aspect internally),
    // with no Container/Box/decoration/effect/fit of any kind around it.
    // The Stack stays loose + centered so nothing ever force-fills the
    // frame (`StackFit.expand` would stretch faces again). Null
    // controller (test fake only, never on-device) renders an undecorated
    // spacer of the same place in the tree.
    final surface =
        preview ?? (ctl != null ? CameraPreview(ctl) : const SizedBox.expand());
    // Preview rides low: top offset drops the whole feed + overlay block
    // (Padding is layout-neutral for the path pins — no SafeArea, aspect,
    // fit, constraint, or container in the preview chain).
    return Padding(
      padding: const EdgeInsets.only(top: ProxSpacing.xxl),
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.loose,
      children: [
        surface,
        // The overlay ACTUALLY renders above the preview: this
        // overlay is inside the preview Stack (not beside
        // it), pointer-transparent, repainting per shot.
        // THE shared single-oval overlay (override 2026-09-10 — top bar =
        // overall progress, oval + comet = live head target for the next
        // unfilled angle, one prompt below the oval; totalAngles comes from
        // the controller's own slot list, verified 5 via faceEnrollSlots,
        // never hardcoded).
        CaptureOverlay(
          progress: total <= 0 ? 0.0 : doneCount / total,
          currentAngle: nextAngle,
          totalAngles: totalAngles,
          statusLine: statusLine,
          sweepAngle: sweepAngle,
          previewAspectRatio: previewAspect,
          topInset: overlayTopInset,
          showStatusLine: promptVisible,
        ),
        // Fail-closed error banner (save-error only):
        // toast-pattern overlay — same Notice widget and
        // message, zero layout effect, so the feed area
        // never moves on the error transition and long
        // messages wrap without resizing anything.
        // Touch-transparent (info only; retry lives in
        // the bottom bar); semantics kept so readers
        // still announce the error.
        if (saveError)
          Positioned(
            left: 16,
            right: 16,
            bottom: 12,
            // Edge-to-edge: the toast avoids the nav-bar/gesture inset
            // while the video fills under it (zero effect in tests).
            child: SafeArea(
              top: false,
              child: IgnorePointer(
                child: EnrollNotice(message: saveMessage, isError: true),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom action bar. Single purpose: terminal chrome only — validated
/// shows Continue, save-error shows Try-again (+ the shared hidden top-up
/// so back-nav stays stable), mid-flow stays empty (the overlay owns the
/// single prompt; nothing here duplicates it). Keyboard: N/A — this page
/// has no editable text, so viewInsets stay zero in every variant.
class EnrollCaptureBottomBar extends StatelessWidget {
  /// Set validated (faceDone/uploaded) — Continue replaces the bar.
  final bool validated;

  /// Terminal gallery write failed with progress kept — retry offered.
  final bool saveError;

  /// Terminal write in flight (disables Try-again, shows its spinner).
  final bool saving;

  final VoidCallback onContinue;
  final Future<void> Function() onRetry;

  /// Slot recapture after a slot-naming refusal (controller.lastFailedSlot):
  /// secondary `Recapture <slot>` next to Try-again. Null hides it (plain
  /// transient-error chrome).
  final String? recaptureSlot;
  final Future<void> Function(String slot)? onRecapture;

  const EnrollCaptureBottomBar({
    super.key,
    required this.validated,
    required this.saveError,
    required this.saving,
    required this.onContinue,
    required this.onRetry,
    this.recaptureSlot,
    this.onRecapture,
  });

  @override
  Widget build(BuildContext context) {
    // Edge-to-edge: terminal chrome avoids the nav-bar/gesture inset while
    // the video fills under it (zero effect in tests — no notch there).
    // Mid-flow stays empty — the overlay carries the single prompt.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (validated) ...[
              ProxPrimaryButton(
                label: const Text('Continue'),
                onPressed: onContinue,
              ),
              const EnrollCaptureSlotTopUp(),
            ] else if (saveError) ...[
              // Slot-naming refusal (liveness/Euler FAIL): the toast names
              // the slot and the copy promises single-slot recapture —
              // this is that action (other buckets kept). Plain transient
              // errors show Try-again only.
              if (recaptureSlot != null && onRecapture != null) ...[
                ProxSecondaryButton(
                  label: Text('Recapture $recaptureSlot'),
                  expanded: true,
                  onPressed: saving
                      ? null
                      : () {
                          final slot = recaptureSlot;
                          final fn = onRecapture;
                          if (slot != null && fn != null) {
                            unawaited(fn(slot));
                          }
                        },
                ),
                const SizedBox(height: 8),
              ],
              ProxPrimaryButton(
                icon: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                label: const Text('Try again'),
                onPressed: saving ? null : onRetry,
              ),
              const EnrollCaptureSlotTopUp(),
            ] else ...[
              // Mid-flow: overlay owns the prompt — nothing here.
              const SizedBox.shrink(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Hidden 52px top-up (prompt-height + gap + status-height + gap) shared by
/// the terminal bottom variants so every variant totals the mid-flow slot.
/// Same line heights as the visible pieces, hidden, no semantics, no
/// buttons — pure boundary parity, zero visible or interactive effect.
/// (Pre-split name `_SlotTopUp`; renamed public for the section library —
class EnrollCaptureSlotTopUp extends StatelessWidget {
  const EnrollCaptureSlotTopUp({super.key});
  @override
  Widget build(BuildContext context) {
    return Visibility(
      visible: false,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'X',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: ProxSpacing.xs),
            const Text('X'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Records-only blocked card (L2: non-mobile devices never reach the
/// camera). Single purpose: the no-camera path. Back steps back inside
/// SetupFlow, else pops (same STEP-SCOPE rule as Cancel).
class EnrollCaptureBlocked extends StatelessWidget {
  final VoidCallback onBack;

  const EnrollCaptureBlocked({super.key, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return ProxScreen(
      title: 'Face capture',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const FaceBlockedCard(flow: 'Face enrollment'),
          const SizedBox(height: ProxSpacing.md),
          ProxSecondaryButton(
            label: const Text('Back'),
            onPressed: onBack,
          ),
        ],
      ),
    );
  }
}
