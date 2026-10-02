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

  /// Edge-to-edge top inset (additive option, kept for any future
  /// overlay-bar caller with a byte-identical default): the bottom filling
  /// gauge needs no inset.
  final double overlayTopInset;

  /// Live head-pose wheels (all null = hidden): the guided target slot +
  /// latest holder-perspective angles, forwarded to the overlay.
  final String? targetSlot;
  final double? liveYaw;
  final double? livePitch;

  /// Locked key gate (vs a genuinely missing key): shows unlock-and-retry
  /// copy with a Try-again button that re-runs restore + camera open.
  /// False (default) keeps the static fail copy with no action.
  final bool restoreLocked;

  /// Retry action for [restoreLocked] (ignored unless locked and the fail
  /// branch is active).
  final Future<void> Function()? onRetryRestore;

  /// Ring-light flash assist level (dark session only — see flash_assist
  /// + the driver's graded [flashLevel]). Wired straight into the shared
  /// overlay's own ring painter (uniform light above the scrim). 0.0
  /// (default) paints nothing extra: the bare-surface preview + overlay
  /// contract is byte-identical to the no-assist path.
  final double flashLevel;

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
    this.targetSlot,
    this.liveYaw,
    this.livePitch,
    this.restoreLocked = false,
    this.onRetryRestore,
    this.flashLevel = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    final fail = failMessage;
    if (fail != null) {
      // Locked gate (key behind the lock): message + in-place retry.
      // Genuinely missing keys keep the static copy with no action.
      final retry = onRetryRestore;
      if (restoreLocked && retry != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(fail, textAlign: TextAlign.center),
                const SizedBox(height: ProxSpacing.md),
                ProxPrimaryButton(
                  label: const Text('Try again'),
                  onPressed: () => unawaited(retry()),
                ),
              ],
            ),
          ),
        );
      }
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
    // Overlay aspect: under full-bleed cover the video box IS the Stack,
    // so the overlay always takes the null (full size) path — deriving
    // from a bar box would shrink the guide off the visible feed. The
    // explicit test-seam value is accepted for signature compat and
    // ignored (the seam renders bare, same as the placeholder).
    // Full-bleed raw feed (user-directed edge-to-edge): the sensor frame
    // COVERS the Stack (center-cropped — never squished, no color
    // treatment, raw feed as the background) instead of letterboxing
    // with pillar/letter bars. No bars means no gap widths that can ever
    // differ between entries; the overlay derives from the full Stack
    // (aspect null below) so guide/wheels stay aligned with the visible
    // feed by construction. Capture stills are unaffected (takePicture
    // returns the full sensor frame, never the crop). Cover uses
    // explicit box math + OverflowBox centering (see [_CoverFeed]) —
    // deliberately NO transform anywhere (no FittedBox/Transform): the
    // platform texture paints exactly as the proven bare path did, only
    // larger. Null controller (test fake only, never on-device) renders
    // an undecorated spacer of the same place in the tree.
    Widget surface;
    final seam = preview;
    if (seam != null) {
      surface = seam;
    } else if (ctl == null) {
      surface = const SizedBox.expand();
    } else {
      double? ar;
      try {
        if (ctl.value.isInitialized) {
          final a = displayedPreviewAspect(ctl.value);
          if (a.isFinite && a > 0) ar = a;
        }
      } catch (_) {
        ar = null;
      }
      // Unknown ratio (should not happen — the controller gate above
      // requires initialized): proven bare path, never a garbage box.
      surface = ar == null
          ? CameraPreview(ctl)
          : _CoverFeed(aspectRatio: ar, child: CameraPreview(ctl));
    }
    // Below-app-bar layout: the Stack starts directly under the opaque
    // bar (no top offset — the old "rides low" Padding died with the
    // transparent overlay bar). The preview chain carries no SafeArea,
    // no fit transform, and no color filter — explicit cover math only.
    return Stack(
      alignment: Alignment.center,
      fit: StackFit.loose,
      children: [
        surface,
        // The overlay ACTUALLY renders above the preview: this
        // overlay is inside the preview Stack (not beside
        // it), pointer-transparent, repainting per shot.
        // THE shared single-oval overlay (override 2026-09-10 — bottom
        // bar = overall progress, oval + comet = live head target for the next
        // unfilled angle, one prompt below the oval; totalAngles comes from
        // the controller's own slot list, verified 5 via faceEnrollSlots,
        // never hardcoded).
        CaptureOverlay(
          progress: total <= 0 ? 0.0 : doneCount / total,
          currentAngle: nextAngle,
          totalAngles: totalAngles,
          statusLine: statusLine,
          sweepAngle: sweepAngle,          // Cover path (live controller): the video box IS the Stack, so
          // the overlay takes the null (full size) path — deriving from a
          // bar box would shrink the guide off the visible feed. Seam path
          // (tests): the bare test frame keeps its video box so the guide
          // stays aligned with it there too.
          previewAspectRatio: preview == null ? null : previewAspectRatio,
          topInset: overlayTopInset,
          showStatusLine: promptVisible,
          poseYaw: liveYaw,
          posePitch: livePitch,
          poseTargetSlot: targetSlot,
          flashLevel: flashLevel,
          // Save-error banner takes the prompt slot inside the overlay
          // (same geometry, zero layout effect on the feed). SafeArea
          // ancestor pinned (notch-aware) with all sides off: the slot is
          // geometry-placed mid-screen, so this moves zero pixels.
          errorBanner: saveError
              ? SafeArea(
                  top: false,
                  bottom: false,
                  left: false,
                  right: false,
                  child: IgnorePointer(
                    child:
                        EnrollNotice(message: saveMessage, isError: true),
                  ),
                )
              : null,
        ),
      ],
    );
  }
}

/// Full-bleed camera surface: explicit cover box, zero transforms.
/// [aspectRatio] is the orientation-adjusted sensor ratio
/// ([displayedPreviewAspect] — the exact size CameraPreview sizes itself
/// to), so the inner box matches the native frame pixel-for-pixel (no
/// squish); the outer box is the Stack area; [OverflowBox] centers the
/// oversized inner box and [ClipRect] crops the bleed. The texture
/// paints untransformed, exactly as the proven bare path — only larger.
class _CoverFeed extends StatelessWidget {
  final double aspectRatio;
  final Widget child;
  const _CoverFeed({required this.aspectRatio, required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      // Unbounded (should not happen — the Stack lives in an Expanded):
      // proven bare path, never a garbage box.
      if (!size.isFinite) return child;
      var w = size.width;
      var h = w / aspectRatio;
      if (h < size.height) {
        h = size.height;
        w = h * aspectRatio;
      }
      return ClipRect(
        child: SizedBox.fromSize(
          size: size,
          child: OverflowBox(
            maxWidth: w,
            maxHeight: h,
            child: SizedBox(width: w, height: h, child: child),
          ),
        ),
      );
    });
  }
}

/// Bottom action bar. Single purpose: terminal chrome only — validated
/// shows Continue, save-error shows ONE action (slot-naming refusal:
/// Recapture; plain transient: Try-again), mid-flow stays empty (the
/// overlay owns the single prompt; nothing here duplicates it).
/// Keyboard: N/A — this page has no editable text, so viewInsets stay
/// zero in every variant.
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
  /// `Recapture <slot>` INSTEAD of Try-again (retrying identical stills
  /// re-fails identically). Null hides it (plain transient-error chrome).
  final String? recaptureSlot;
  final Future<void> Function(String slot)? onRecapture;

  /// Live vitality readout for the bottom bar (null = hidden): the latest
  /// measured liveness score + guided target, rendered BELOW the button
  /// slot in every state (mid-flow, saving, terminal) so the bar height
  /// never moves between transitions. Test-only constructions leave null.
  final String? liveReadout;

  const EnrollCaptureBottomBar({
    super.key,
    required this.validated,
    required this.saveError,
    required this.saving,
    required this.onContinue,
    required this.onRetry,
    this.recaptureSlot,
    this.onRecapture,
    this.liveReadout,
  });

  @override
  Widget build(BuildContext context) {
    // Edge-to-edge: terminal chrome avoids the nav-bar/gesture inset while
    // the video fills under it (zero effect in tests — no notch there).
    // Mid-flow stays empty — the overlay carries the single prompt.
    // Terminal chrome is one action, never two: a slot-naming refusal
    // (liveness/Euler FAIL) offers Recapture only — Try-again would rerun
    // the identical stills into the identical refusal. Plain transient
    // errors (no slot) offer Try-again only.
    final hasRecapture = recaptureSlot != null && onRecapture != null;
    final terminalChrome = <Widget>[
      if (hasRecapture)
        ProxPrimaryButton(
          label: Text('Recapture $recaptureSlot'),
          onPressed: saving
              ? null
              : () {
                  final slot = recaptureSlot;
                  final fn = onRecapture;
                  if (slot != null && fn != null) {
                    unawaited(fn(slot));
                  }
                },
        )
      else
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
    ];
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
              ...terminalChrome,
            ] else if (saving) ...[
              // Terminal write in flight (5-still liveness re-score +
              // gallery write + self-checks take seconds): the button slot
              // shows a disabled Processing state with a spinner instead
              // of going empty — the set stays visibly "working", never
              // hung. Same subtree height as the terminal variant (plus
              // the shared top-up), so the feed never moves on the
              // saving → validated/error transition.
              ProxPrimaryButton(
                icon: const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                label: const Text('Processing…'),
                onPressed: null,
              ),
              const EnrollCaptureSlotTopUp(),
            ] else ...[
              // Area parity (field-verified 2026-09-13: terminal chrome
              // appearing visibly shifted the preview up under the oval
              // mid-positioning): a hidden replica of the terminal variant,
              // so the feed never moves on the mid-flow → terminal
              // transition. Same subtree ⇒ pixel-identical height at any
              // text scale; hit-test/semantics excluded while hidden, so
              // it reserves area and nothing else.
              Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: terminalChrome,
                ),
              ),
            ],
            // Live vitality readout (below the button slot, every state):
            // latest measured liveness + guided target in tabular mono so
            // digits never jitter the width. Always rendered when wired
            // (never only-terminal) so the bar height is identical across
            // mid-flow → saving → validated/error transitions.
            if (liveReadout != null) ...[
              const SizedBox(height: ProxSpacing.sm),
              Builder(builder: (context) {
                final c = ProximityColors.of(context);
                return Text(
                  liveReadout!,
                  style: ProxType.monoCaption(
                      color: c.contentSecondary),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                );
              }),
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
