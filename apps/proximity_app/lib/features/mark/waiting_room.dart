// Waiting room (student mark): Connected/status + heartbeat presence.
// Join never starts the face scan — it registers presence (professor sees
// n waiting), pre-warms BLE, and parks here. When the window opens the
// room auto-advances to face check with no new taps.
//
// `effect.glow.live` behind it) with `Connected` / `Not connected` as the
// only two states and the waiting line beneath; the per-round trail renders
// as pill chips; the manual fallback sits at the bottom at low emphasis.
// All status copy is verbatim from the previous screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/verdict_badge.dart';

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
            child: Text(
              '$m ✓',
              style: ProxType.caption(color: c.statusMarked),
            ),
          ),
      ],
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
  /// only by the org-checked unicast — never beacons/BLE.
  final String roomProfEmail;

  /// Institute org from the announcement / beacon target ('' = legacy).
  final String roomOrg;
  final List<String> roundMarks;
  final VoidCallback onRequestManual;
  final VoidCallback onCancel;

  const WaitingRoomView({
    super.key,
    required this.connected,
    required this.roomClass,
    this.roomProf = '',
    this.roomProfEmail = '',
    this.roomOrg = '',
    required this.roundMarks,
    required this.onRequestManual,
    required this.onCancel,
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
                  child: VerdictBadge(
                    key: ValueKey<bool>(connected),
                    status: ProxStatus.waiting,
                    label: connected ? 'Connected' : 'Not connected',
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
                const SizedBox(height: ProxSpacing.sm),
                Text(
                  'Attendance has not yet started for\n$roomClass.\nKeep this open — you will continue automatically when the professor starts marking.',
                  style: ProxType.body(color: c.contentSecondary),
                  textAlign: TextAlign.center,
                ),
                if (roomProf.isNotEmpty ||
                    roomProfEmail.isNotEmpty ||
                    roomOrg.isNotEmpty) ...[
                  const SizedBox(height: ProxSpacing.xs),
                  Text(
                    [
                      if (roomProf.isNotEmpty) 'Hosted by $roomProf',
                      if (roomProfEmail.isNotEmpty) roomProfEmail,
                      if (roomOrg.isNotEmpty) roomOrg,
                    ].join(' · '),
                    textAlign: TextAlign.center,
                    style: ProxType.caption(color: c.contentSecondary),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
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
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(64, ProxSpacing.minTap),
                  ),
                  onPressed: onRequestManual,
                  child: const Text('Request manual attendance'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(64, ProxSpacing.minTap),
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
