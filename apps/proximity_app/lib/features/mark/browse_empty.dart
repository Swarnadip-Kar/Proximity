// Browse empty state (student mark, §6.1): centered illustration +
// "Looking for a class…" headline with a radar-sweep loop and
// `effect.glow.live` behind it — the one ambient animation allowed at
// rest, since it signals active scanning. The previous guidance copy is
// kept verbatim as the subline.
//
// Single-purpose split from `browse_classes.dart` (Mark slim-down).
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';

/// Empty state (§6.1): centered illustration + "Looking for a class…"
/// headline with a radar-sweep loop and `effect.glow.live` behind it — the
/// one ambient animation allowed at rest, since it signals active scanning.
/// The previous guidance copy is kept verbatim as the subline.
class BrowseEmptyState extends StatelessWidget {
  /// Ambient sweep-head angle (radians). Null renders the static rings +
  /// halo only (reduce-motion path — callers pass null there).
  final double? sweepAngle;

  const BrowseEmptyState({super.key, required this.sweepAngle});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: ProxSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.surfaceRaised,
              boxShadow: [c.glowLive.toShadow()],
            ),
            child: CustomPaint(
              painter: _RadarPainter(
                sweepAngle: sweepAngle,
                ring: c.divider,
                sweep: c.accentBrand,
              ),
            ),
          ),
          const SizedBox(height: ProxSpacing.md),
          Text(
            'Looking for a class…',
            style: ProxType.title(color: c.contentPrimary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: ProxSpacing.xs),
          Text(
            'No live classes heard yet. Stay on the classroom WiFi — professors appear here when they start hosting. If nothing appears, type the IP shown on the professor\u2019s screen above (Bluetooth must be on for auto-discovery).',
            style: ProxType.caption(color: c.contentSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double? sweepAngle;
  final Color ring;
  final Color sweep;

  _RadarPainter({
    required this.sweepAngle,
    required this.ring,
    required this.sweep,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 8;
    for (final f in [1.0, 0.66, 0.33]) {
      canvas.drawCircle(
        center,
        radius * f,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = ring,
      );
    }
    // Sweep head on the outer ring (same element, not another one).
    // Null (reduce-motion) skips the head — static rings + halo remain.
    final head = sweepAngle;
    if (head != null) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        head,
        1.047,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..color = sweep,
      );
    }
    canvas.drawCircle(
      center,
      4,
      Paint()..color = sweep,
    );
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.sweepAngle != sweepAngle || old.ring != ring || old.sweep != sweep;
}
