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
import '../../widgets/class_ordinal.dart';
import '../../widgets/student_card.dart';
import '../../widgets/verdict_badge.dart';

/// Signal bars (3-bar glyph) from beacon/hint recency — never raw dBm.
///
/// 3 = window open right now; 2 = heard within [kDiscoveryExpiry] (the same
/// 12s budget the listener prunes on — one missed 10s rotation + margin);
/// else 1 (session-acked hint listing, idle). Pure for unit tests.
int signalBarsFor({
  required bool windowOpen,
  required DateTime lastSeen,
  required DateTime now,
}) {
  if (windowOpen) return 3;
  if (now.difference(lastSeen) <= kDiscoveryExpiry) return 2;
  return 1;
}

/// Avatar ring for a browse tile (pure, unit-testable): the ring mirrors
/// the idle indicator exactly — window open (non-idle) gets the gradient
/// ring treatment shared with the selection/identity rings (`StudentCard`
/// ring, `AccountChip` header, `ProxIdentityHeader`); idle rows stay flat
/// even when recently heard (2 bars), since recency is not openness.
/// Pure for unit tests.
bool browseRingFor({required bool windowOpen}) => windowOpen;

/// Gated photo lookup for one host key: the trimmed URL, or '' when the
/// host never published one (opted-out / unknown / legacy → the
/// class-letter disc). Pure for unit tests.
String gatedPhotoFor(Map<String, String> byHost, String key) =>
    (byHost[key] ?? '').trim();

/// Verification TAG for a browse tile (footer pill — green Verified on a
/// prove-time key match, yellow Unverified while unmatched
/// (first-seen included: the caption + Details explainer carry the
/// first-scan honesty), red Blocked on mismatch). 'known' (pins cached
/// but unmatched yet) stays caption-only: a cached pin is not a match.
/// ''/unknown renders nothing. Pure for unit tests.
Widget? browseVerifyTag(String label) => switch (label) {
      'verified' || 'verified-live' =>
        const VerdictBadge(status: ProxStatus.marked, label: 'Verified'),
      'unverified' || 'first-seen' =>
        const VerdictBadge(status: ProxStatus.review, label: 'Unverified'),
      'mismatch' =>
        const VerdictBadge(status: ProxStatus.wrongOrg, label: 'Blocked'),
      _ => null,
    };

/// One discovered class: the lightweight `StudentCard` variant (§6.1) —
/// course name, professor display name when given, tap → waiting — with the
/// 3-bar recency glyph + open chevron / `idle` trailing it. The card avatar
/// shows the professor's gated photo when published, else the class-letter
/// disc; non-idle tiles carry the gradient ring (+ live glow while open).
/// Verification caption for a browse tile (offline-first, honest):
/// '' = unknown host (no email — no claim); 'known' = a pin is cached for
/// this email (verifies against the presented key on join); 'first-seen' =
/// no pin cached (TOFU — allowed with an unverified banner, auto-verifies
/// online); 'verified-live' / 'verified' / 'mismatch' = the last join/prove
/// verdict for this host (live fetch vs cache; mismatch sent no proof).
String browseVerifyCaption(String label) => switch (label) {
      'verified-live' => 'Verified · live',
      'verified' => 'Verified',
      'known' => 'Known host — verifies on join',
      'first-seen' => 'First seen — verifies on join',
      'unverified' => 'Unverified — verifies on join',
      'mismatch' => 'Blocked earlier — key mismatch',
      _ => '',
    };

class BrowseTile extends StatelessWidget {
  final LiveClass live;
  final String profEmail;

  /// Gated prof Gmail photo (same org-checked /window unicast as the
  /// email — never beacons/BLE). '' = opted-out/unknown/legacy: the avatar
  /// falls back to the class-letter disc, exactly as before.
  final String profPhotoUrl;

  /// Verification label for [profEmail] (see [browseVerifyCaption]).
  /// '' renders exactly as before (no extra line).
  final String verifyLabel;

  final VoidCallback onTap;

  /// Live round number for the ordinal under the course disc (0/negative
  /// = unknown/closed → disc renders exactly as before, no caption).
  final int classNo;

  const BrowseTile({
    super.key,
    required this.live,
    required this.profEmail,
    this.profPhotoUrl = '',
    this.verifyLabel = '',
    this.classNo = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final a = live.last;
    final bars = signalBarsFor(
      windowOpen: a.windowOpen,
      lastSeen: live.lastSeen,
      now: DateTime.now().toUtc(),
    );
    // Pills live TOGETHER on the footer line below the card row — never
    // beside the course name: even one pill squeezed the title out on
    // narrow phones, so line 1 carries no status at all (same clean
    // title rule as every other `StudentCard`; the Open pill used to
    // sit there). Order: verify tag first, then Open.
    final tag = browseVerifyTag(verifyLabel);
    final openTag = a.windowOpen
        ? const VerdictBadge(
            status: ProxStatus.waiting,
            label: 'Open',
          )
        : null;
    final card = StudentCard(
      // Course-titled card: the avatar disc is a COURSE disc
      // ([courseInitials] — `DSL506 - Intro…` → `DS`), with the prof's
      // gated Gmail photo on top when published.
      isCourse: true,
      // Gated prof Gmail (org-checked /window unicast only — never
      // beacons/BLE). Empty on legacy/unknown: the card reads as
      // before. Institute org rides the announcement already.
      //
      // Gated prof photo on the same channel: non-empty renders the
      // photo, empty renders the class-letter disc (the card's own
      // initials fallback — never blank, never a network spinner).
      //
      // Mark tiles use the large 56 avatar (rosters/records keep 40).
      // Live round ordinal tucks under the disc, inside the avatar
      // column only ("1st Class") — never the title section.
      avatarSize: 56,
      avatarCaption: classOrdinalLabel(classNo),
      photoUrl: profPhotoUrl,
      name: a.classLabel,
      // No host IP, no org on the card (join + org gate still use them
      // internally; manual entry has its own field). Keeps the tile
      // scannable.
      subtitle: [
        if (a.prof.isNotEmpty) a.prof,
        if (a.display.isNotEmpty) 'Code ${a.display}',
      ].join(' · '),
      // Email + verify caption below (two lines — the caption would
      // truncate after the email at maxLines 1). The pin verdict rides
      // under it (never as verified without a key match — see
      // browseVerifyCaption).
      subtitle2: (profEmail.isNotEmpty &&
              profEmail.toLowerCase() != a.prof.toLowerCase())
          ? (browseVerifyCaption(verifyLabel).isEmpty
              ? profEmail
              : '$profEmail\n${browseVerifyCaption(verifyLabel)}')
          : (browseVerifyCaption(verifyLabel).isEmpty
              ? null
              : browseVerifyCaption(verifyLabel)),
      subtitle2MaxLines: 2,
      status: null,
      // Both pills share one footer line (never beside the title):
      // verify tag first, Open just right of it, left-aligned below
      // the email/caption lines. Both absent renders exactly as
      // before — no extra line.
      footer: (tag == null && openTag == null)
          ? null
          : Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tag != null) tag,
                  if (tag != null && openTag != null)
                    const SizedBox(width: ProxSpacing.xs),
                  if (openTag != null) openTag,
                ],
              ),
            ),
      onTap: onTap,
    );
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: card),
        const SizedBox(width: ProxSpacing.sm),
        _SignalCluster(bars: bars, windowOpen: a.windowOpen),
      ],
    );
    // Non-idle ring (window open only — mirrors the `idle` caption /
    // `Open` badge source of truth): the same gradient + glow idiom as
    // the avatar rings elsewhere (`gradientBrand` outline, `glowLive`
    // while the window is open). Static — no sweep timer — so browse
    // lists stay pumpAndSettle-safe; motion lives only in the
    // selection/identity rings. Idle rows return the plain row above
    // (pixel-identical).
    if (!browseRingFor(windowOpen: a.windowOpen)) return row;
    return Container(
      key: const ValueKey('browse-ring'),
      decoration: BoxDecoration(
        borderRadius: ProxRadii.cardSpecRadius,
        gradient: c.gradientBrand,
        boxShadow: a.windowOpen ? [c.glowLive.toShadow()] : null,
      ),
      padding: const EdgeInsets.all(1.5),
      child: row,
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
