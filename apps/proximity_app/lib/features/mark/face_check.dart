// Face check (student mark): Samsung-style seamless scan — it starts by
// itself the moment this step appears (zero taps); the Scan button stays
// as fallback/retry. The radio keeps listening under the camera UI (one
// small pulsing dot + caption, no radar dump).
//
// Presentation rebuild (§6.2): the old single `FaceOval` is replaced by the
// shared two-oval `CaptureOverlay` — small oval = live head-position
// target, large oval = overall progress, nothing else on the frame.
// Inconclusive scans ride the same two ovals (neutral pulse) plus the one
// short status line, never a dialog, and never burn an attempt. Readable
// mismatches route to needs-review (attempt burned there, not here), so
// this screen only ever shows the neutral/inconclusive signals.
// Zero-tap auto-scan + Scan fallback timing are unchanged (host-owned).
//
// Angle count: the verified capture controller sequences 5 angles
// (centre/left/right/up/down — gap 3 resolution), so the overlay defaults
// to a 5-angle sequence. Marking itself is a single-shot verify; progress
// stays at 0 until the pass routes onward.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../widgets/capture_overlay.dart';
import '../../widgets/prox_buttons.dart';

class FaceCheckView extends StatelessWidget {
  final String faceNotice;
  final bool canScan;
  final VoidCallback onScan;

  /// Total angles in the capture sequence (verified controller count).
  final int totalAngles;

  /// Live head-target angle index (single-shot marking: the first slot).
  final int currentAngle;

  /// Overall sequence progress 0..1 (single-shot: 0 until the pass leaves).
  final double progress;

  const FaceCheckView({
    super.key,
    required this.faceNotice,
    required this.canScan,
    required this.onScan,
    this.totalAngles = 5,
    this.currentAngle = 0,
    this.progress = 0.0,
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
    final c = ProximityColors.of(context);
    final signal = signalForNotice(faceNotice);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(ProxSpacing.screenMargin),
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: ProxSpacing.maxContentWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Ring-morph entrance (§6.2): the waiting presence ring grows
              // into the camera viewfinder frame over `ringMorph` (~300ms)
              // instead of hard-cutting. One-shot entrance, never gating
              // the auto-scan beneath it.
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.6, end: 1.0),
                duration: ProxMotion.effective(
                  context,
                  ProxDurations.ringMorph,
                ),
                curve: ProxCurves.emphasized,
                builder: (context, scale, child) => Opacity(
                  opacity: ProxMotion.reduced(context)
                      ? 1.0
                      : (scale - 0.6) / 0.4,
                  child: Transform.scale(scale: scale, child: child),
                ),
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: Container(
                    decoration: BoxDecoration(
                      color: c.surfaceRaised,
                      borderRadius: ProxRadii.cardSpecRadius,
                      border: Border.all(color: c.divider),
                      boxShadow: [c.elevationRaised],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: CaptureOverlay(
                      progress: progress,
                      currentAngle: currentAngle,
                      totalAngles: totalAngles,
                      signal: signal,
                      // The ONE allowed short line — the host notice, or
                      // nothing while the zero-tap scan runs.
                      statusLine:
                          faceNotice.isNotEmpty ? faceNotice : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: ProxSpacing.sm),
              Text(
                'Professor started marking — look at the camera, scanning starts by itself.',
                style: ProxType.body(color: c.contentSecondary),
                textAlign: TextAlign.center,
              ),
              // Ambient BLE indicator: the radio keeps listening under
              // the camera UI. One small pulsing dot + caption — visible
              // without distracting from the scan.
              const SizedBox(height: ProxSpacing.sm),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ListeningDot(),
                  const SizedBox(width: ProxSpacing.sm),
                  Text(
                    'BLE listening',
                    style: ProxType.caption(color: c.contentSecondary),
                  ),
                ],
              ),
              const SizedBox(height: ProxSpacing.sm),
              ProxPrimaryButton(
                icon: const Icon(Icons.face),
                label: const Text('Scan face'),
                onPressed: !canScan ? null : onScan,
                expanded: false,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small live dot proving the radio is still listening under the camera
/// UI (same accent that carries the live state elsewhere).
class _ListeningDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.accentBrand,
      ),
    );
  }
}
