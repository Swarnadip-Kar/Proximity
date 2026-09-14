// Waiting room (student mark): Connected/status + heartbeat presence.
// Join never starts the face scan — it registers presence (professor sees
// n waiting), pre-warms BLE, and parks here. When the window opens the
// room auto-advances to face check with no new taps.
//
// A centered presence ring (96dp, `effect.glow.live` behind it) with
// `Connected` / `Not connected` as the only two states and the waiting line beneath; the per-round trail renders
// as pill chips; the manual fallback sits at the bottom at low emphasis.
// All status copy is verbatim from the previous screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/student_driver.dart'
    show ProfVerificationResult;
import '../../design/tokens.dart';
import '../../widgets/host_preview_card.dart';
import '../../widgets/prof_verified_badge.dart';
import '../../widgets/prox_motion.dart';

/// Connection pill for the waiting room (not a verdict).
///
/// Connected is transport state, not attendance — it must not reuse the
/// green Marked badge. Connected reads accentBrand with a pulsing dot;
/// Not connected reads contentSecondary static. Icon+text always carry
/// meaning; color never acts alone.

/// Per-round trail as pill chips (`R1 ✓ · R2 ✗` style glanceables carrying
/// the host's full verbatim trail strings, e.g. `R1 · KQ7 · 10:04:12`).
/// Shared by the waiting room and the marked/late verdict cards.
class RoundTrailPills extends StatelessWidget {
  /// Host trail entries, oldest first (`R<n> · <detail>`).
  final List<String> marks;

  const RoundTrailPills({super.key, required this.marks});

  @override
  Widget build(BuildContext context) {
    if (marks.isEmpty) return const SizedBox.shrink();
    final c = ProximityColors.of(context);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: ProxSpacing.sm,
      runSpacing: ProxSpacing.xs,
      children: [
        for (final m in marks)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: ProxSpacing.sm,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: c.statusMarked.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(ProxRadii.pill),
              border: Border.all(
                color: c.statusMarked.withValues(alpha: 0.4),
              ),
            ),
            // Icon+text (never text glyph alone): check icon carries the
            // shape, label carries the round detail.
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    m,
                    style: ProxType.caption(color: c.statusMarked),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.check,
                  size: 12,
                  color: c.statusMarked,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  final bool connected;

  const _ConnectionBadge({super.key, required this.connected});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final color = connected ? c.accentBrand : c.contentSecondary;
    final label = connected ? 'Connected' : 'Not connected';
    return Semantics(
      label: label,
      child: AnimatedContainer(
        duration: ProxDurations.small,
        curve: ProxCurves.standard,
        padding: const EdgeInsets.symmetric(
          horizontal: ProxSpacing.md,
          vertical: ProxSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(ProxRadii.pill),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: ProxSpacing.xs),
            Flexible(
              child: Text(
                label,
                style: ProxType.label(color: color),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WaitingRoomView extends StatelessWidget {
  final bool connected;
  final String roomClass;

  /// Professor display name from the tapped announcement ('' when the
  /// room was joined by typed IP — no announcement was heard). surfaced
  /// only, never fetched: the announcement already broadcasts it.
  final String roomProf;

  /// Hosting professor's Gmail from the GATED /window unicast ('' =
  /// unknown/legacy or typed-IP join before the gated fetch lands). Fed
  /// only by the org-checked unicast — never beacons/BLE. Retained as
  /// fetched state but never rendered (privacy: the shared host card
  /// shows display name + org only).
  final String roomProfEmail;

  /// Hosting professor's Gmail profile photo from the same GATED /window
  /// unicast ('' = unknown). Rendered with initials fallback; converges
  /// on the next room poll when the host publishes late.
  final String roomProfPhoto;

  /// Institute org from the announcement / beacon target ('' = unstamped).
  final String roomOrg;

  final List<String> roundMarks;
  final VoidCallback onRequestManual;
  final VoidCallback onCancel;

  /// Email→key pin verdict for the hosting professor (see
  /// ProfVerifiedBadge): verified (live/cache), unverified first-seen
  /// (queued for auto-verify online), or mismatch (no proof is sent).
  /// Null = unknown host — renders exactly as before.
  final ProfVerificationResult? profVerification;

  const WaitingRoomView({
    super.key,
    required this.connected,
    required this.roomClass,
    this.roomProf = '',
    this.roomProfEmail = '',
    this.roomProfPhoto = '',
    this.roomOrg = '',
    required this.roundMarks,
    required this.onRequestManual,
    required this.onCancel,
    this.profVerification,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(ProxSpacing.screenMargin),
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: ProxSpacing.maxContentWidth),
          child: ProxFadeSlideIn(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PresenceRing(connected: connected),
                const SizedBox(height: ProxSpacing.lg),
                ProxSwitcher(
                  child: _ConnectionBadge(
                    key: ValueKey<bool>(connected),
                    connected: connected,
                  ),
                ),
                const SizedBox(height: ProxSpacing.md),
                ProxSwitcher(
                  child: Text(
                    connected
                        ? 'Connected — waiting for professor to start marking'
                        : 'Not connected — check WiFi / IP',
                    key: ValueKey<bool>(connected),
                    style: ProxType.body(color: c.contentPrimary),
                    textAlign: TextAlign.center,
                  ),
                ),
                // Highlighted course name (title case, primary): the room
                // reads as THIS class first, status second. Hidden when
                // the class label is still unknown (typed-IP pre-fetch) —
                // the paragraph below reads fine without it.
                if (roomClass.trim().isNotEmpty) ...[
                  const SizedBox(height: ProxSpacing.sm),
                  Text(
                    roomClass,
                    style: ProxType.title(color: c.contentPrimary),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ],
                const SizedBox(height: ProxSpacing.xs),
                Text(
                  'Attendance has not yet started.\nKeep this open — you will continue automatically when the professor starts marking.',
                  style: ProxType.body(color: c.contentSecondary),
                  textAlign: TextAlign.center,
                ),
                // Trimmed to match the shared card's own trim semantics:
                // blank-but-non-empty strings must not force a stray empty
                // card (the card shrinks to nothing when title and lines
                // are both blank after trimming).
                if (roomProf.trim().isNotEmpty ||
                    roomProfEmail.trim().isNotEmpty ||
                    roomOrg.trim().isNotEmpty) ...[
                  const SizedBox(height: ProxSpacing.sm),
                  // Host identity: the SAME shared card the professor
                  // previews in setup — photo (initials fallback) +
                  // display name, falling back to the gated Gmail when
                  // unconfigured (plus org). The shared widget dedupes,
                  // so the address never renders twice — and the preview
                  // can never drift from this view.
                  HostPreviewCard(
                    displayName: roomProf,
                    email: roomProfEmail,
                    org: roomOrg,
                    photoUrl: roomProfPhoto,
                  ),
                  // Pin verdict for the gated email (verified live/cache,
                  // first-seen unverified with online auto-verify, or
                  // mismatch-blocked). Null/unknown renders nothing —
                  // the card above reads exactly as before. The sm gap
                  // above matches the card's own group rhythm (was 0 —
                  // the text touched the card while lg sat below it).
                  const SizedBox(height: ProxSpacing.sm),
                  ProfVerifiedBadge(verification: profVerification),
                ],
                if (!connected) ...[
                  const SizedBox(height: ProxSpacing.sm),
                  Text(
                    'Honestly unreachable right now — check the IP and that both devices are on the same WiFi. Presence retries every 2s; hosting that ended returns you to the live list.',
                    textAlign: TextAlign.center,
                    style: ProxType.caption(color: c.contentSecondary),
                  ),
                ],
                if (roundMarks.isNotEmpty) ...[
                  const SizedBox(height: ProxSpacing.sm),
                  RoundTrailPills(marks: roundMarks),
                ],
                const SizedBox(height: ProxSpacing.lg),
                // Hierarchy: manual request is the fallback path
                // (outlined pill, brand border), Cancel is quiet text.
                // Callbacks unchanged — direct POST + teardown.
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(64, ProxSpacing.minTap),
                    foregroundColor: c.accentBrand,
                    side: BorderSide(
                      color: c.accentBrand.withValues(alpha: 0.4),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(ProxRadii.pill),
                    ),
                  ),
                  onPressed: onRequestManual,
                  child: const Text('Request manual attendance'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(64, ProxSpacing.minTap),
                    foregroundColor: c.contentSecondary,
                  ),
                  onPressed: onCancel,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Centered presence indicator (§6.2): a pulsing ring with
/// `effect.glow.live` behind it. Pulses while connected; holds a static
/// soft halo when not (never removed — an inert ring would read as
/// "disconnected" rather than "working"). Timer-driven toggle + implicit
/// scale so widget tests still settle; static under reduce-motion.
class _PresenceRing extends StatefulWidget {
  final bool connected;

  const _PresenceRing({required this.connected});

  @override
  State<_PresenceRing> createState() => _PresenceRingState();
}

class _PresenceRingState extends State<_PresenceRing> {
  Timer? _pulse;
  var _dim = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(_PresenceRing old) {
    super.didUpdateWidget(old);
    if (old.connected != widget.connected) _syncPulse();
  }

  void _syncPulse() {
    final want = widget.connected && !ProxMotion.reduced(context);
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
    final ring = widget.connected ? c.accentBrand : c.contentTertiary;
    return AnimatedScale(
      scale: _dim ? 1.06 : 1.0,
      duration: ProxMotion.effective(context, ProxDurations.dotPulse),
      curve: ProxCurves.standard,
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.surfaceRaised,
          border: Border.all(color: ring, width: 3),
          boxShadow: [c.glowLive.toShadow()],
        ),
        alignment: Alignment.center,
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ring,
          ),
        ),
      ),
    );
  }
}
