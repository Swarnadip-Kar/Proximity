// CaptureOverlay — THE two-oval face-scan overlay (§6.2).
//
// Full-bleed camera preview with exactly two overlay elements, nothing
// else — shared by `mark/face` and `enroll/capture` (one overlay design,
// not two):
// - SMALL oval — the live head-position target. Its center shifts toward
//   the current capture angle's direction, so it is the only element
//   telling the user *what to do right now*.
// - LARGE oval — the overall progress ring around the capture frame,
//   filling as each angle is captured. The only element telling the user
//   *how far along they are*.
//
// No corner brackets, no separate progress bar, no per-angle text labels,
// no extra chrome. Inconclusive vs mismatch ride on these same two ovals
// (neutral pulse vs `status.error` flash) plus ONE short line of copy
// ([statusLine]), never a dialog — modals would interrupt a flow that must
// keep listening on radio.
//
// Angle-count-agnostic: [currentAngle]/[totalAngles] take whatever the
// actual capture controller does (gap 3 stays open — 3, 5, or any N work
// identically; nothing here hardcodes a count). The default target
// direction places angle `i` of `N` around a circle; callers with semantic
// directions (left/right/up/down) may pass [targetDirection] explicitly.
//
// Overlay-only: pointer-transparent, zero layout effect on the preview.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Frame-level capture signal, carried by oval color (plus one short
/// line — never a dialog).
enum CaptureSignal {
  /// Normal capture: target ring + progress ring.
  neutral,

  /// Unreadable frame (inconclusive, burns nothing): neutral pulse on the
  /// ovals + `Hold still, retrying`-style line. Automatic, no user action.
  inconclusive,

  /// Readable wrong-person frame (mismatch, burns one): error flash on
  /// the ovals + one short line.
  mismatch,
}

/// Two-oval capture overlay. See file docs for the contract.
class CaptureOverlay extends StatefulWidget {
  /// Overall progress 0..1 (captured / total). Drives the large oval arc.
  final double progress;

  /// Index of the live head-position target angle.
  final int currentAngle;

  /// Total angles in the controller's sequence (any N, never hardcoded).
  final int totalAngles;

  /// Explicit target direction (-1..1 x/y). Defaults to
  /// [directionForAngle] circular placement.
  final Offset? targetDirection;

  /// Frame signal (oval color pulse/flash + status line tone).
  final CaptureSignal signal;

  /// ONE short line of copy (e.g. `Hold still, retrying`). Null hides it.
  final String? statusLine;

  /// Ambient sweep-head angle on the small oval (radians). Null renders
  /// statically — callers pass null under reduce-motion.
  final double? sweepAngle;

  const CaptureOverlay({
    super.key,
    required this.progress,
    required this.currentAngle,
    required this.totalAngles,
    this.targetDirection,
    this.signal = CaptureSignal.neutral,
    this.statusLine,
    this.sweepAngle,
  });

  /// Default target direction for angle [index] of [total]: spread around
  /// a circle starting at the top. Pure for unit tests. Works for any
  /// total (1..N) — the agnosticism gap 3 requires.
  static Offset directionForAngle(int index, int total) {
    if (total <= 0) return Offset.zero;
    final i = index.clamp(0, total - 1);
    if (total == 1) return Offset.zero;
    final a = 2 * math.pi * i / total - math.pi / 2;
    return Offset(math.cos(a), math.sin(a));
  }

  /// Large (progress) oval framing rect: fractions of the preview size.
  static Rect largeRectFor(Size size) => Rect.fromCenter(
        center: size.center(Offset.zero),
        width: size.width * 0.78,
        height: size.height * 0.64,
      );

  /// Small (head-position target) oval framing rect: smaller, center
  /// shifted toward [direction] (max ±8% of the preview size).
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

  /// Oval accent color for a signal. Neutral = brand target ring;
  /// inconclusive = neutral pulse tone; mismatch = error flash.
  static Color signalColorFor(CaptureSignal signal, ProximityColors c) =>
      switch (signal) {
        CaptureSignal.mismatch => c.statusError,
        CaptureSignal.inconclusive => c.contentSecondary,
        CaptureSignal.neutral => c.accentBrand,
      };

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
    // Pulse only for non-neutral signals (and never under reduce-motion —
    // the ovals then hold their signal color statically).
    final want =
        widget.signal != CaptureSignal.neutral &&
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
    final direction = widget.targetDirection ??
        CaptureOverlay.directionForAngle(
          widget.currentAngle,
          widget.totalAngles,
        );
    final accent =
        CaptureOverlay.signalColorFor(widget.signal, c);
    final line = widget.statusLine;

    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _CaptureOverlayPainter(
              scrim: c.gradientScrim,
              baseRing: c.contentPrimary,
              progressColor: widget.signal == CaptureSignal.neutral
                  ? c.statusMarked
                  : accent,
              targetColor: accent,
              progress: widget.progress,
              direction: direction,
              sweepAngle: widget.sweepAngle,
              dim: _dim,
            ),
            child: const SizedBox.expand(),
          ),
          // The ONE allowed short line — never a dialog, never stacked.
          if (line != null && line.isNotEmpty)
            Positioned(
              left: ProxSpacing.screenMargin,
              right: ProxSpacing.screenMargin,
              bottom: ProxSpacing.xl,
              child: Text(
                line,
                style: ProxType.label(color: accent),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
        ],
      ),
    );
  }
}

class _CaptureOverlayPainter extends CustomPainter {
  final LinearGradient scrim;
  final Color baseRing;
  final Color progressColor;
  final Color targetColor;
  final double progress;
  final Offset direction;
  final double? sweepAngle;
  final bool dim;

  _CaptureOverlayPainter({
    required this.scrim,
    required this.baseRing,
    required this.progressColor,
    required this.targetColor,
    required this.progress,
    required this.direction,
    required this.sweepAngle,
    required this.dim,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Camera surround: the scrim token's own shader (never a hand-authored
    // dim) so the preview stays legible behind the ovals.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = scrim.createShader(Offset.zero & size),
    );

    final alpha = dim ? 0.55 : 1.0;
    final large = CaptureOverlay.largeRectFor(size);
    final small = CaptureOverlay.smallRectFor(size, direction);

    // LARGE oval — overall progress ring (base ring + completion arc).
    canvas.drawOval(
      large,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = baseRing.withValues(alpha: 0.85 * alpha),
    );
    final p = progress.clamp(0.0, 1.0);
    if (p > 0) {
      canvas.drawArc(
        large,
        -math.pi / 2,
        2 * math.pi * p,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..color = progressColor.withValues(alpha: alpha),
      );
    }

    // SMALL oval — live head-position target ring.
    canvas.drawOval(
      small,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = targetColor.withValues(alpha: alpha),
    );
    // Ambient sweep head on the small oval (same element, not another one).
    final sweep = sweepAngle;
    if (sweep != null) {
      canvas.drawArc(
        small,
        sweep,
        1.047,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round
          ..color = targetColor.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_CaptureOverlayPainter old) =>
      old.progress != progress ||
      old.direction != direction ||
      old.sweepAngle != sweepAngle ||
      old.dim != dim ||
      old.progressColor != progressColor ||
      old.targetColor != targetColor;
}
