// Browse live list (student mark, §6.1): discovered classes as a
// lightweight `StudentCard` variant with the 3-bar recency glyph.
//
// Single-purpose split from `browse_classes.dart` (Mark slim-down):
// - [signalBarsFor] is the pure recency→bars mapping (unit-testable):
//   window-open → 3, heard within the discovery expiry → 2, else 1 —
//   never a raw dBm number.
// - [BrowseTile] is one discovered class: course name, professor display
//   name when given, tap → waiting — with the 3-bar recency glyph + open
//   chevron / `idle` trailing it.
library;

import 'package:flutter/material.dart';
import 'package:proximity_transport/transport.dart';

import '../../design/tokens.dart';
import '../../widgets/student_card.dart';
import '../../widgets/verdict_badge.dart';

/// Signal bars (3-bar glyph) from beacon/hint recency — never raw dBm.
///
/// 3 = window open right now; 2 = heard within [kDiscoveryExpiry] (the same
/// 6s budget the listener prunes on); else 1 (session-acked hint listing,
/// idle). Pure for unit tests.
int signalBarsFor({
  required bool windowOpen,
  required DateTime lastSeen,
  required DateTime now,
}) {
  if (windowOpen) return 3;
  if (now.difference(lastSeen) <= kDiscoveryExpiry) return 2;
  return 1;
}

/// One discovered class: the lightweight `StudentCard` variant (§6.1) —
/// course name, professor display name when given, tap → waiting — with the
/// 3-bar recency glyph + open chevron / `idle` trailing it.
class BrowseTile extends StatelessWidget {
  final LiveClass live;
  final String profEmail;
  final VoidCallback onTap;

  const BrowseTile({
    super.key,
    required this.live,
    required this.profEmail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final a = live.last;
    final bars = signalBarsFor(
      windowOpen: a.windowOpen,
      lastSeen: live.lastSeen,
      now: DateTime.now().toUtc(),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: StudentCard(
            // Gated prof Gmail (org-checked /window unicast only — never
            // beacons/BLE). Empty on legacy/unknown: the card reads as
            // before. Institute org rides the announcement already.
            name: a.classLabel,
            subtitle: [
              if (a.prof.isNotEmpty) a.prof,
              if (profEmail.isNotEmpty) profEmail,
              a.host,
              if (a.display.isNotEmpty) 'Code ${a.display}',
              if (a.org.isNotEmpty) a.org,
            ].join(' · '),
            status: a.windowOpen
                ? const VerdictBadge(
                    status: ProxStatus.waiting,
                    label: 'Open',
                  )
                : null,
            onTap: onTap,
          ),
        ),
        const SizedBox(width: ProxSpacing.sm),
        _SignalCluster(bars: bars, windowOpen: a.windowOpen),
      ],
    );
  }
}

/// 3-bar recency glyph + open chevron / `idle` caption. Glyph only — no
/// numbers, never raw dBm.
//
// Corners note: the 2px radius below is the glyph-bar rounding on a 4px
// bar (fully rounded sides), not a card — cards use the radius tokens.
class _SignalCluster extends StatelessWidget {
  final int bars;
  final bool windowOpen;

  const _SignalCluster({required this.bars, required this.windowOpen});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final active = windowOpen ? c.statusMarked : c.contentSecondary;
    final idle = c.contentTertiary;
    return IgnorePointer(
      child: Semantics(
        label: '$bars of 3 bars',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 1; i <= 3; i++)
                  Container(
                    width: 4,
                    height: 6.0 + (i - 1) * 4,
                    margin: EdgeInsets.only(
                      left: i == 1 ? 0 : 2,
                    ),
                    decoration: BoxDecoration(
                      color: i <= bars ? active : idle.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: ProxSpacing.xs),
            if (windowOpen)
              Icon(Icons.chevron_right, size: 20, color: c.contentSecondary)
            else
              Text(
                'idle',
                style: ProxType.caption(color: c.contentTertiary),
              ),
          ],
        ),
      ),
    );
  }
}
