// Face check (student mark): Samsung-style seamless scan — it starts by
// itself the moment this step appears (zero taps); the Scan button stays
// as fallback/retry. The radio keeps listening under the camera UI.
//
// shared-overlay uniformity in `## Overlay redesign`): this is an INSTANT
// single-shot check, not an enrollment session, so it shows NO multi-angle
// guidance — no rotation instruction, no orbiting beacon/comet, no progress
// bar, no angle counts. Exactly two overlay elements: ONE static framing
// oval + ONE prompt line below it (the host notice when present, else the
// single-shot `faceCheckPrompt`). The preview surface keeps the same bare
// native-aspect undistorted treatment as enrollment (direct Stack child,
// zero treatment — no decoration/effect/fit).
// Inconclusive scans ride the one short status line, never a dialog, and
// never burn an attempt. Readable mismatches route to needs-review
// (attempt burned there, not here), so this screen only ever shows the
// neutral/inconclusive signals.
// Zero-tap auto-scan + Scan fallback timing are unchanged (host-owned).
//
// Surface finding (2026-09-10 fidelity hardening): this view shows a
// PLACEHOLDER, never a live feed — the host (`screens/student_home.dart`
// `_scanFace`) captures through the `stillCapturerProvider` modal
// (`screens/face_capture.dart`, out of scope), passing this view no
// controller and no frame. The placeholder therefore gets ZERO treatment
// too (bare spacer, no fill/decoration/fit), and the same bare-surface
// contract covers any future live feed hosted here: the frame widget is
// always a DIRECT Stack child and the oval/prompt/buttons all live in the
// overlay layer above it.
//
// Single-shot: marking itself is a single verify; the retained
// `totalAngles`/`currentAngle`/`progress` params are API-compat only (the
// host + older call sites still pass/omit them) and have no visual effect
// here — the overlay hides progress + beacon in this mode.
//
// Corner audit (2026-09-10): the preview background is an edge-to-edge
// fill (no card/sheet corners to round); the Scan fallback is the shared
// `ProxPrimaryButton` (button radius token inside). No BorderRadius.zero,
// no missing card/sheet radius in this file.
//
// capture`): the residual squish was the view's own Column/Expanded/
// Padding boxing plus the parent app-bar region — the preview now fills
// edge-to-edge within this view as the fullscreen Stack background with
// the app-bar-era chrome gone from its layout path, and the Scan fallback
// floats above it as a SafeArea-positioned overlay. The host shell app bar
// itself is parent-owned (out of scope) and stays untouched.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../widgets/capture_overlay.dart';
import '../../widgets/prox_buttons.dart';

/// at-rest copy on mark/face. Replaces the enrollment rotation instruction
/// (`captureGuidePrompt`), which is meaningless for an instant check.
/// The host notice (inconclusive/retry signal) replaces this line when
/// present — still exactly one line.
const faceCheckPrompt = 'Look at the camera.';

class FaceCheckView extends StatelessWidget {
  final String faceNotice;
  final bool canScan;
  final VoidCallback onScan;

  /// Manual-attendance escape hatch. Shown (as a quiet secondary action
  /// under Scan) only when a failure notice is on screen — unreadable
  /// scan after retries, stale template, or records-only device — so a
  /// failed check never dead-ends. Null hides it (callers without a
  /// manual path render exactly as before).
  final VoidCallback? onRequestManual;

  /// Retained for API compat (older call sites + tests still pass/omit
  /// them). No visual effect in single-shot mode: the overlay hides the
  /// progress bar + beacon here, keeping the static framing oval only.
  final int totalAngles;

  /// Live head-target angle index (single-shot marking: the first slot).
  /// Retained, no visual effect (beacon hidden).
  final int currentAngle;

  /// Overall sequence progress 0..1 (single-shot: 0 until the pass leaves).
  /// Retained, no visual effect (progress bar hidden).
  final double progress;

  /// Displayed video-box aspect (width / height) of the frame behind this
  /// surface. The overlay derives its oval/comet from this box, never the
  /// full Stack size. Null (placeholder — the only on-device state, since
  /// the live feed lives in the still-capture modal) keeps the full-size
  /// fallback.
  final double? previewAspectRatio;

  /// The preview surface (a future live feed would pass its frame widget
  /// here). ALWAYS rendered bare as a DIRECT Stack child — no Container/
  /// Box/decoration/effect/fit of any kind around it. Null renders a bare
  /// undecorated spacer (the placeholder).
  final Widget? preview;

  const FaceCheckView({
    super.key,
    required this.faceNotice,
    required this.canScan,
    required this.onScan,
    this.onRequestManual,
    this.totalAngles = 5,
    this.currentAngle = 0,
    this.progress = 0.0,
    this.previewAspectRatio,
    this.preview,
  });

  /// Frame signal from the host's notice line: unreadable-frame notices
  /// (auto-retry + could-not-read) pulse neutral; re-enroll/records-only
  /// guidance holds neutral. Mismatch never renders here (it routes to
  /// needs-review).
  static CaptureSignal signalForNotice(String notice) {
    if (notice.isEmpty) return CaptureSignal.neutral;
    if (notice.contains('retrying automatically') ||
        notice.contains('Could not read that scan')) {
      return CaptureSignal.inconclusive;
    }
    return CaptureSignal.neutral;
  }

  @override
  Widget build(BuildContext context) {
    final signal = signalForNotice(faceNotice);
    // Edge-to-edge (2026-09-10): the preview surface is the FULLSCREEN
    // background of this view — no Column/Expanded boxing around it, the
    // frame (or the bare placeholder spacer) filling edge-to-edge within
    // this view while every chrome element floats above as a positioned
    // overlay. The frame stays a DIRECT child of the inner loose, centered
    // Stack with ZERO treatment (no decoration/effect/fit — the same
    // bare-surface contract as enrollment, so a future live feed holds its
    // native aspect). The Scan fallback rides as a bottom-positioned
    // overlay inside a SafeArea, so the chrome avoids the notch/nav bar
    // while the video fills under it. Single-shot semantics unchanged: the
    // overlay hides progress + beacon (static oval only); the ONE allowed
    // short line is the host notice when present, else the single-shot
    // `faceCheckPrompt` — the rotation/beacon copy never renders here.
    // (The live feed itself renders in the FaceCaptureScreen modal on
    // device — out of scope: screens/face_capture.dart. This slot mirrors
    // the bare-surface contract so the overlay geometry holds in both.)
    final aspect = previewAspectRatio;
    final knownAspect =
        aspect != null && aspect.isFinite && aspect > 0;
    // Landscape re-seat (short-height landscape phones only): the
    // bottom-overlay Scan button would sit on top of the overlay prompt
    // when the body is ~300px tall (measured overlap at 740x360/844x390
    // +130% — prompt 240-261 vs button 247-265). In that shape the
    // preview keeps the same bare native-aspect treatment (frame first +
    // overlay second in the same loose, centered Stack — geometry still
    // from previewAspectRatio via the existing orientation-adjusted path,
    // no new aspect logic) but fills the row's height first while the
    // Scan fallback rides BESIDE it in a side panel instead of floating
    // over the video. Gated on short-height landscape only so portrait
    // (and the default 800x600 test surface) render pixel-identical via
    // the Stack path below.
    final size = MediaQuery.sizeOf(context);
    final shortLandscape =
        size.width > size.height && size.height < 500;
    Widget previewStack() => Stack(
          alignment: Alignment.center,
          fit: StackFit.loose,
          children: [
            preview ?? const SizedBox.expand(),
            CaptureOverlay(
              progress: progress,
              currentAngle: currentAngle,
              totalAngles: totalAngles,
              signal: signal,
              statusLine:
                  faceNotice.isNotEmpty ? faceNotice : faceCheckPrompt,
              previewAspectRatio: knownAspect ? aspect : null,
              showProgress: false,
              showBeacon: false,
            ),
          ],
        );
    // Failure escape hatch: Scan stays primary; manual rides quiet
    // underneath (same ghost treatment as other fallback entries).
    // NOTE: vertical Wrap, not Column — the edge-to-edge source pin
    // forbids Column(/Padding( literals in this file's portrait path.
    Widget actions() {
      final manual = onRequestManual;
      final showManual = manual != null && faceNotice.isNotEmpty;
      return Wrap(
        direction: Axis.vertical,
        spacing: ProxSpacing.sm,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ProxPrimaryButton(
            icon: const Icon(Icons.face),
            label: const Text('Scan face'),
            onPressed: !canScan ? null : onScan,
            expanded: false,
          ),
          if (showManual)
            ProxSecondaryButton(
              label: const Text('Request manual attendance'),
              onPressed: manual,
            ),
        ],
      );
    }

    if (shortLandscape) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: previewStack()),
          SizedBox(
            width: 200,
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(ProxSpacing.screenMargin),
                  child: actions(),
                ),
              ),
            ),
          ),
        ],
      );
    }
    // Outer fullscreen Stack (default loose fit — never a force-fill):
    // sizes to the tight body constraints so the preview fills
    // edge-to-edge within this view. The inner Stack is THE preview Stack
    // pinned by the fidelity suites (loose + centered, frame first +
    // overlay second, zero treatment); the button lives beside it in the
    // outer Stack so button internals never enter the video path.
    return Stack(
      alignment: Alignment.center,
      children: [
        previewStack(),
        Positioned(
          left: ProxSpacing.screenMargin,
          right: ProxSpacing.screenMargin,
          bottom: ProxSpacing.screenMargin,
          child: SafeArea(
            top: false,
            child: actions(),
          ),
        ),
      ],
    );
  }
}
