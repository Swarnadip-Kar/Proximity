// 2026-09-10, supersedes PROXIMITY_UI_REDESIGN.md §6.2 two-oval rule and the
// previous CaptureOverlay two-oval contract — logged as deviation in
//
// Full-bleed camera preview with exactly three overlay elements, nothing
// else — shared by `mark/face` and `enroll/capture` (one overlay design,
// not two):
//  1. ONE slim progress bar pinned just BELOW the top app bar (angle
//     completion 0..1).
//  2. ONE static oval centered as the face guide with ONE glowing green
//     COMET that travels along/around it indicating the current target
//     direction: a bright head dot plus a short fading tail streaming
//     behind it (opposite the travel direction). Under reduce-motion the
//     comet holds static at the target with a minimal tail.
//  3. ONE short guiding prompt line below the oval (rotate with the beacon).
//
// No dots, no labels, no extra rings/progress arcs stacked on the preview.
// Inconclusive vs mismatch ride on the beacon + progress-bar tone (neutral
// pulse vs `status.error`) plus the ONE line, never a dialog — modals would
// interrupt a flow that must keep listening on radio.
//
// Angle-count-agnostic: [currentAngle]/[totalAngles] take whatever the
// actual capture controller does (3, 5, or any N work identically; nothing
// here hardcodes a count). The default target direction places angle `i`
// of `N` around a circle; callers with semantic directions (left/right/up/
// down) may pass [targetDirection] explicitly.
//
// `## Face-check single-shot`): callers pass `showProgress: false` +
// `showBeacon: false` to hide the multi-angle guidance (slim progress bar
// + travelling comet) and keep the static framing oval + one prompt line
//
// the top bar clear a transparent overlay app bar, and the bar rides
// inside a SafeArea so chrome avoids the notch while the video + scrim
// paint fullscreen under it. Beacon/progress semantics, prompt copy, and
// reduce-motion behavior are unchanged.
//
// Overlay-only: pointer-transparent, zero layout effect on the preview.
// Glow + scrim stay token-sourced (§2.5): scrim via `gradientScrim`, beacon
// halo via `glowMarked` blur/opacity, no hand-authored gradients.
// Reduce-motion: the beacon holds static at the target direction (the
// sweep timer never advances it — callers pass null under reduce-motion,
// and the widget ignores [sweepAngle] when `ProxMotion.reduced`).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// shown when the caller passes no explicit [CaptureOverlay.statusLine]
/// (e.g. mark/face at rest). Enroll passes its own frozen prompt
/// (`enrollCapturePrompt`) explicitly, so this string renders in exactly
/// one consumer — minimal new copy, one line.
const captureGuidePrompt = 'Rotate your face slowly with the green beacon.';

/// Frame-level capture signal, carried by beacon + progress-bar tone (plus
/// one short line — never a dialog).
enum CaptureSignal {
  /// Normal capture: green beacon + green progress bar.
  neutral,

  /// Unreadable frame (inconclusive, burns nothing): neutral pulse on the
  /// beacon + `Hold still, retrying`-style line. Automatic, no user action.
  inconclusive,

  /// Readable wrong-person frame (mismatch, burns one): error tone on the
  /// beacon + progress bar + one short line.
  mismatch,
}

/// Single-oval capture overlay. See file docs for the contract.
class CaptureOverlay extends StatefulWidget {
  /// Overall progress 0..1 (captured / total). Drives the slim top bar.
  final double progress;

  /// Index of the live head-position target angle.
  final int currentAngle;

  /// Total angles in the controller's sequence (any N, never hardcoded).
  final int totalAngles;

  /// Explicit target direction (-1..1 x/y). Defaults to
  /// [directionForAngle] circular placement.
  final Offset? targetDirection;

  /// Frame signal (beacon + progress-bar tone).
  final CaptureSignal signal;

  /// ONE short line of copy (e.g. `Hold still, retrying`, or the enroll
  /// prompt). Null/empty shows [captureGuidePrompt].
  final String? statusLine;

  /// Beacon travel angle on the oval (radians). Null renders statically at
  /// the target direction — callers pass null under reduce-motion (and the
  /// widget forces the static path when `ProxMotion.reduced` regardless).
  final double? sweepAngle;

  /// Native sensor aspect (width / height) of the letterboxed preview
  /// behind this overlay (e.g. `controller.value.aspectRatio`). When
  /// non-null, the oval/beacon/prompt are derived from the ACTUAL video
  /// box (the largest centered [aspectRatio] rect inside the Stack), never
  /// from the full Stack size — so the guide stays aligned with the
  /// undistorted feed when letterbox bars are present. Null (unknown /
  /// placeholder surface) falls back to the full size (legacy behavior,
  /// zero visual change when there are no bars).
  final double? previewAspectRatio;

  /// Single-shot flags (additive, default true = multi-angle guidance).
  /// `showProgress: false` hides the slim top angle-completion bar;
  /// `showBeacon: false` hides the travelling comet, leaving the static
  /// framing oval only. Mark/face passes both false (instant single-shot
  /// check — progress/beacon are meaningless there); enroll leaves the
  final bool showProgress;
  final bool showBeacon;

  /// Top chrome inset (additive edge-to-edge option, default 0 =
  /// clears a transparent overlay app bar when the preview extends behind
  /// it (enroll passes the app-bar height). Callers without an overlay app
  /// bar leave 0. Pure layout — zero effect on beacon/progress semantics,
  /// prompt copy, signal tones, or motion.
  final double topInset;

  const CaptureOverlay({
    super.key,
    required this.progress,
    required this.currentAngle,
    required this.totalAngles,
    this.targetDirection,
    this.signal = CaptureSignal.neutral,
    this.statusLine,
    this.sweepAngle,
    this.previewAspectRatio,
    this.showProgress = true,
    this.showBeacon = true,
    this.topInset = 0.0,
  });

  /// Default target direction for angle [index] of [total]: spread around
  /// a circle starting at the top. Pure for unit tests. Works for any
  /// total (1..N).
  static Offset directionForAngle(int index, int total) {
    if (total <= 0) return Offset.zero;
    final i = index.clamp(0, total - 1);
    if (total == 1) return Offset.zero;
    final a = 2 * math.pi * i / total - math.pi / 2;
    return Offset(math.cos(a), math.sin(a));
  }

  /// THE face-guide oval framing rect: one static centered oval, fractions
  /// of the preview size. Pure for unit tests.
  static Rect guideRectFor(Size size) => guideRectForAspect(size, null);

  /// Actual video box behind the overlay: the largest centered rect with
  /// [aspectRatio] (width / height) that fits inside [size]. Null /
  /// non-finite / non-positive ratios fall back to the full [size] (no
  /// bars — legacy behavior). Pure for unit tests. This is the box the
  /// letterboxed preview surface (`AspectRatio` + `Center` over plain
  /// bars) actually paints the camera frame into — the overlay MUST derive
  /// from here, never from the full Stack size, or the guide drifts off
  /// the undistorted feed whenever bars are present.
  static Rect previewRectFor(Size size, double? aspectRatio) {
    if (aspectRatio == null ||
        !aspectRatio.isFinite ||
        aspectRatio <= 0 ||
        size.isEmpty) {
      return Offset.zero & size;
    }
    final sizeAspect = size.width / size.height;
    if ((sizeAspect - aspectRatio).abs() < 1e-9) {
      return Offset.zero & size;
    }
    double w;
    double h;
    if (sizeAspect > aspectRatio) {
      // Box wider than the feed: height constrains, bars left/right.
      h = size.height;
      w = h * aspectRatio;
    } else {
      // Box taller than the feed: width constrains, bars top/bottom.
      w = size.width;
      h = w / aspectRatio;
    }
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: w,
      height: h,
    );
  }

  /// Face-guide oval derived from the ACTUAL preview box (see
  /// [previewRectFor]): the same 0.70w x 0.52h fractions applied to the
  /// video rect, not the full Stack size. Null aspect == [guideRectFor]
  /// legacy behavior. Pure for unit tests.
  static Rect guideRectForAspect(Size size, double? aspectRatio) {
    final preview = previewRectFor(size, aspectRatio);
    return Rect.fromCenter(
      center: preview.center,
      width: preview.width * 0.70,
      height: preview.height * 0.52,
    );
  }

  /// Beacon position for travel/target [angle] on [oval] (east = 0,
  /// clockwise on screen). Pure for unit tests.
  static Offset beaconPointFor(Rect oval, double angle) => Offset(
        oval.center.dx + oval.width / 2 * math.cos(angle),
        oval.center.dy + oval.height / 2 * math.sin(angle),
      );

  /// Target angle (radians) for a direction vector. Zero vector defaults
  /// to the top (-pi/2) so the beacon still parks somewhere meaningful.
  static double angleForDirection(Offset direction) {
    if (direction == Offset.zero) return -math.pi / 2;
    return math.atan2(direction.dy, direction.dx);
  }

  /// Large (progress) oval framing rect: fractions of the preview size.
  /// Kept for test compatibility (geometry helpers stay pure); the painter
  /// now draws the single [guideRectFor] oval.
  static Rect largeRectFor(Size size) => Rect.fromCenter(
        center: size.center(Offset.zero),
        width: size.width * 0.78,
        height: size.height * 0.64,
      );

  /// Small (head-position target) oval framing rect: smaller, center
  /// shifted toward [direction] (max ±8% of the preview size).
  /// Kept for test compatibility; the painter no longer draws it.
  static Rect smallRectFor(Size size, Offset direction) {
    final d = Offset(
      direction.dx.clamp(-1.0, 1.0),
      direction.dy.clamp(-1.0, 1.0),
    );
    final center = size.center(Offset.zero) +
        Offset(d.dx * size.width * 0.08, d.dy * size.height * 0.08);
    return Rect.fromCenter(
      center: center,
      width: size.width * 0.44,
      height: size.height * 0.34,
    );
  }

  /// Beacon + progress-bar tone for a signal. Neutral = completion green
  /// (the glowing beacon spec); inconclusive = neutral pulse tone;
  /// mismatch = error flash.
  static Color signalColorFor(CaptureSignal signal, ProximityColors c) =>
      switch (signal) {
        CaptureSignal.mismatch => c.statusError,
        CaptureSignal.inconclusive => c.contentSecondary,
        CaptureSignal.neutral => c.statusMarked,
      };

  /// Comet tail length while sweeping (radians of oval arc behind the
  /// head — short by design, well under a quarter revolution, so no
  /// remnant survives to the next pass).
  static const double cometTailSpan = 0.55;

  /// Comet tail length when static (reduce-motion or null sweep — the
  /// head parks at the target direction with this minimal tail so it
  /// still reads as a comet without implying motion).
  static const double cometMinTailSpan = 0.22;

  /// Comet tail paint slices (paint-only, zero layout effect).
  static const int cometSlices = 8;

  /// Comet tail alpha profile: quadratic 0 (tail tip, fully transparent)
  /// → 1 (head, bright), head-ward monotonic. Pure for unit tests
  /// (tip-fully-faded invariant: no remnant survives to the next pass).
  static List<double> cometTailAlphas([int slices = cometSlices]) {
    final n = slices.clamp(1, 64);
    return [
      for (var i = 0; i < n; i++)
        n == 1 ? 1.0 : (i / (n - 1)) * (i / (n - 1)),
    ];
  }

  @override
  State<CaptureOverlay> createState() => _CaptureOverlayState();
}

class _CaptureOverlayState extends State<CaptureOverlay> {
  Timer? _pulse;
  var _dim = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(CaptureOverlay old) {
    super.didUpdateWidget(old);
    if (old.signal != widget.signal) _syncPulse();
  }

  void _syncPulse() {
    // Pulse only for non-neutral signals with a visible beacon (and never
    // under reduce-motion — the beacon then holds its signal color
    // statically). Single-shot mode (showBeacon false) has no beacon to
    // pulse, so no timer there — enroll path unchanged.
    final want = widget.signal != CaptureSignal.neutral &&
        widget.showBeacon &&
        !ProxMotion.reduced(context);
    if (want && _pulse == null) {
      _pulse = Timer.periodic(ProxDurations.dotPulse, (_) {
        if (!mounted) return;
        setState(() => _dim = !_dim);
      });
    } else if (!want && _pulse != null) {
      _pulse?.cancel();
      _pulse = null;
      _dim = false;
    }
  }

  @override
  void dispose() {
    _pulse?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final reduced = ProxMotion.reduced(context);
    final direction = widget.targetDirection ??
        CaptureOverlay.directionForAngle(
          widget.currentAngle,
          widget.totalAngles,
        );
    final tone = CaptureOverlay.signalColorFor(widget.signal, c);
    final line = (widget.statusLine != null &&
            widget.statusLine!.isNotEmpty)
        ? widget.statusLine!
        : captureGuidePrompt;
    // Reduce-motion: beacon static at the target direction even when a
    // sweep angle is supplied.
    final sweeping = !reduced && widget.sweepAngle != null;
    final beaconAngle = sweeping
        ? widget.sweepAngle!
        : CaptureOverlay.angleForDirection(direction);
    // Comet tail: full short tail while travelling, minimal static tail
    // when parked (reduce-motion or null sweep) — same head + tone either
    // way, only the tail length changes.
    final tailSpan = sweeping
        ? CaptureOverlay.cometTailSpan
        : CaptureOverlay.cometMinTailSpan;

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Preview Stack is always bounded (Expanded body); fall back to
          // bottom-anchored copy on unbounded constraints rather than
          // producing infinite rects.
          final bounded = constraints.hasBoundedWidth &&
              constraints.hasBoundedHeight;
          final size = bounded
              ? Size(constraints.maxWidth, constraints.maxHeight)
              : const Size(400, 800);
          // Fidelity fix: the oval is derived from the ACTUAL preview box
          // (letterboxed video rect), never the full Stack size — so the
          // guide/beacon stay aligned with the undistorted feed when bars
          // are present. Null aspect == legacy full-size behavior.
          final oval = CaptureOverlay.guideRectForAspect(
              size, widget.previewAspectRatio);
          final promptTop = bounded
              ? (oval.bottom + ProxSpacing.md)
                  .clamp(0.0, size.height - ProxSpacing.xxl)
              : null;
          return Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _CaptureOverlayPainter(
                  scrim: c.gradientScrim,
                  guideRing: c.contentPrimary,
                  guideHalo: tone,
                  beaconColor: tone,
                  beaconGlow: c.glowMarked,
                  oval: oval,
                  beaconAngle: beaconAngle,
                  tailSpan: tailSpan,
                  dim: _dim,
                  showBeacon: widget.showBeacon,
                ),
                child: const SizedBox.expand(),
              ),
              // (1) ONE slim progress bar, pinned just below the top app
              // bar. Edge-to-edge: the bar clears a transparent overlay app
              // bar via [topInset] plus the notch via SafeArea (the video +
              // scrim paint fullscreen under both); standalone callers keep
              // topInset 0 so this stays pinned at the top. Hidden in
              // single-shot mode (mark/face) — angle completion is
              // meaningless for an instant check.
              if (widget.showProgress)
                Positioned(
                  top: widget.topInset + ProxSpacing.sm,
                  left: ProxSpacing.screenMargin,
                  right: ProxSpacing.screenMargin,
                  child: SafeArea(
                    bottom: false,
                    child: ClipRRect(
                      borderRadius: ProxRadii.chipRadius,
                      child: LinearProgressIndicator(
                        value: widget.progress.clamp(0.0, 1.0),
                        minHeight: 4,
                        backgroundColor: c.divider,
                        valueColor: AlwaysStoppedAnimation<Color>(tone),
                      ),
                    ),
                  ),
                ),
              // (3) ONE short guiding prompt line below the oval.
              if (promptTop != null)
                Positioned(
                  top: promptTop,
                  left: ProxSpacing.screenMargin,
                  right: ProxSpacing.screenMargin,
                  child: Text(
                    line,
                    style: ProxType.label(color: c.contentPrimary),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                )
              else
                Positioned(
                  left: ProxSpacing.screenMargin,
                  right: ProxSpacing.screenMargin,
                  bottom: ProxSpacing.xl,
                  child: Text(
                    line,
                    style: ProxType.label(color: c.contentPrimary),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CaptureOverlayPainter extends CustomPainter {
  final LinearGradient scrim;
  final Color guideRing;

  /// Head-position guide halo: concentric pulse rings around the oval in
  /// the signal tone. Alpha breathes with [dim] (existing pulse timer).
  final Color guideHalo;
  final Color beaconColor;
  final ProxGlow beaconGlow;
  final Rect oval;
  final double beaconAngle;

  /// Comet tail length (radians of oval arc behind the head, opposite the
  /// travel direction). Short by contract; the minimal static span parks
  /// under reduce-motion.
  final double tailSpan;
  final bool dim;

  /// Single-shot mode: false hides the comet entirely (static framing oval
  final bool showBeacon;

  _CaptureOverlayPainter({
    required this.scrim,
    required this.guideRing,
    required this.guideHalo,
    required this.beaconColor,
    required this.beaconGlow,
    required this.oval,
    required this.beaconAngle,
    required this.tailSpan,
    required this.dim,
    this.showBeacon = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Camera surround: the scrim token's own shader (never a hand-authored
    // dim) so the preview stays legible behind the oval.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = scrim.createShader(Offset.zero & size),
    );

    final alpha = dim ? 0.55 : 1.0;
    // (2a) ONE static face-guide oval (always drawn — the single-shot
    // screen keeps this framing guide) plus two concentric guide halos
    // in the signal tone that breathe with the pulse timer.
    canvas.drawOval(
      oval,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = guideRing.withValues(alpha: 0.95 * alpha),
    );
    for (final pad in [7.0, 14.0]) {
      canvas.drawOval(
        oval.inflate(pad),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = guideHalo.withValues(
            alpha: (pad > 10 ? 0.18 : 0.30) * alpha,
          ),
      );
    }
    // (2b) ONE glowing COMET travelling on the oval (static at the target
    // under reduce-motion — the angle is resolved in build): bright head
    // dot + halo, with a short fading tail streaming behind it, opposite
    // the travel direction (travel is increasing angle, so the tail is the
    // arc ending at the head). Skipped entirely in single-shot mode
    // (showBeacon false — mark/face keeps the static oval only).
    // Target-direction semantics, tone, and pulse cadence are unchanged —
    // only the tail is new.
    if (!showBeacon) return;
    final at = CaptureOverlay.beaconPointFor(oval, beaconAngle);
    final alphas = CaptureOverlay.cometTailAlphas();
    final slice = tailSpan / alphas.length;
    for (var i = 0; i < alphas.length; i++) {
      final a = alphas[i];
      if (a <= 0) continue; // tail tip fully transparent — no remnant.
      canvas.drawArc(
        oval,
        beaconAngle - tailSpan + i * slice,
        slice,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.butt
          ..color = beaconColor.withValues(alpha: a * alpha),
      );
    }
    final halo = beaconGlow.copyWith(color: beaconColor);
    canvas.drawCircle(
      at,
      14,
      Paint()
        ..color = halo.glowColor.withValues(alpha: halo.opacity * alpha)
        ..maskFilter =
            MaskFilter.blur(BlurStyle.normal, halo.blurSigma / 3),
    );
    canvas.drawCircle(
      at,
      6,
      Paint()..color = beaconColor.withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(_CaptureOverlayPainter old) =>
      old.beaconAngle != beaconAngle ||
      old.tailSpan != tailSpan ||
      old.dim != dim ||
      old.oval != oval ||
      old.beaconColor != beaconColor ||
      old.showBeacon != showBeacon ||
      old.guideRing != guideRing ||
      old.guideHalo != guideHalo;
}
