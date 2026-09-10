// Browse classes (student mark): discovered classes as a lightweight
// StudentCard variant + fallback-weight IP entry + honest empty state.
//
// Presentation rebuild (§6.1); behavior frozen:
// - Discovery stays passive (UDP beacons + BLE hints + typed IP) —
//   pull-down only recomputes from local state, never scans the network
//   (enterprise APs have kicked phones off WiFi under probe load).
// - Typed-IP join keeps its exact parse/validate contract (`IpJoinField` +
//   `JoinByIpSection`, keys `ipfield`/`ipport`, `Join`, last-host prefill)
//   but renders as a `FallbackButton` → one-field sheet, never inline.
// - Every copy string on this screen is verbatim from the previous screen;
//   the one addition is the spec-mandated empty-state headline
//   ("Looking for a class…"), with the previous guidance kept as subline.
// - Signal strength is a 3-bar glyph derived from beacon/hint recency
//   (window-open → 3, heard within the discovery expiry → 2, else 1) —
//   never a raw dBm number.
// - The radar-sweep empty state + waiting-ring halo are the only
//   gradient/glow uses on this screen (`effect.glow.live`, §2.5).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:proximity_transport/transport.dart';

import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../mode.dart';
import '../../widgets/clock.dart';
import '../../widgets/details_expander.dart';
import '../../widgets/fallback_button.dart';
import '../../widgets/ladder_line.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/student_card.dart';
import '../../widgets/verdict_badge.dart';
import 'join_by_ip.dart';

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

class BrowseClassesView extends StatefulWidget {
  final LinkedIdentity? linked;
  final String identityLine;
  final String ipInitial;
  final ValueChanged<String?> onIpChanged;
  final VoidCallback onJoin;
  final String joinError;
  final List<LiveClass> live;
  final ValueChanged<LiveClass> onTapLive;
  final VoidCallback onEnroll;
  final VoidCallback onViewRecords;
  final Future<void> Function() onRefresh;

  /// Track 4 §2: true when UDP beacons deliver nothing but BLE-hinted
  /// classes list (isolating AP) — the list below is hint-only, said aloud.
  final bool broadcastBlocked;

  /// Gated prof emails by `host:port` (from the org-checked /window
  /// unicast — never beacons/BLE). Empty/absent renders exactly as before
  /// (no dangling separators).
  final Map<String, String> profEmailByHost;

  const BrowseClassesView({
    super.key,
    required this.linked,
    required this.identityLine,
    required this.ipInitial,
    required this.onIpChanged,
    required this.onJoin,
    required this.joinError,
    required this.live,
    required this.onTapLive,
    required this.onEnroll,
    required this.onViewRecords,
    required this.onRefresh,
    this.broadcastBlocked = false,
    this.profEmailByHost = const {},
  });

  @override
  State<BrowseClassesView> createState() => _BrowseClassesViewState();
}

class _BrowseClassesViewState extends State<BrowseClassesView> {
  // Radar-sweep ambient loop (presentation only — not a behavior timing):
  // 2400ms revolution advanced on a 50ms tick, timer-driven so widget
  // tests still settle (same pattern as the entry hero). Static under
  // reduce-motion.
  static const _radarPeriod = Duration(milliseconds: 2400);
  static const _radarTick = Duration(milliseconds: 50);
  Timer? _radar;
  var _sweep = 0.0;
  var _blockedDismissed = false;
  var _errorDismissed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_radar != null || ProxMotion.reduced(context)) return;
    _radar = Timer.periodic(_radarTick, (_) {
      if (!mounted) return;
      setState(() {
        _sweep += 2 *
            3.141592653589793 *
            _radarTick.inMilliseconds /
            _radarPeriod.inMilliseconds;
      });
    });
  }

  @override
  void didUpdateWidget(BrowseClassesView old) {
    super.didUpdateWidget(old);
    // A fresh join error re-shows its banner after a dismiss.
    if (old.joinError != widget.joinError) _errorDismissed = false;
  }

  @override
  void dispose() {
    _radar?.cancel();
    super.dispose();
  }

  /// Shared sheet content for the fallback button below (single instance).
  /// Errors surface as the thin banner on the browse list (the sheet
  /// closes on Join either way) — same verbatim strings, one place.
  Widget _ipSheet(BuildContext sheetContext) => JoinByIpSection(
        fieldKey: const ValueKey('ip-sheet'),
        initial: widget.ipInitial,
        onChanged: widget.onIpChanged,
        onJoin: () {
          widget.onJoin();
          Navigator.of(sheetContext).pop();
        },
        joinError: '',
      );

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    // Pull-down = instant local refresh (expiry pruning + recompute).
    // No network scan: discovery is passive (UDP beacons + BLE hints).
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          ProxSpacing.screenMargin,
          ProxSpacing.md,
          ProxSpacing.screenMargin,
          ProxSpacing.xxl,
        ),
        children: [
          _slim(const ClockHeader()),
          const SizedBox(height: ProxSpacing.xs),
          _slim(Text(
            widget.identityLine,
            style: ProxType.body(color: c.contentPrimary),
          )),
          if (widget.joinError.isNotEmpty && !_errorDismissed) ...[
            const SizedBox(height: ProxSpacing.sm),
            _slim(_ThinBanner(
              icon: Icons.error_outline,
              text: widget.joinError,
              onDismiss: () => setState(() => _errorDismissed = true),
            )),
          ],
          // Mobile-only enrollment: records-only devices (desktop/web)
          // offer no enrollment entry point at all — no dead route to it.
          // Marking guidance lives below instead.
          if (widget.linked == null && canUseFace())
            _slim(Padding(
              padding: const EdgeInsets.only(top: ProxSpacing.xs),
              child: ProxSecondaryButton(
                icon: const Icon(Icons.badge),
                label: const Text('Enroll this device (face + ID)'),
                onPressed: widget.onEnroll,
                expanded: true,
              ),
            )),
          if (widget.linked == null && !canUseFace())
            _slim(Padding(
              padding: const EdgeInsets.only(top: ProxSpacing.xs),
              child: Text(
                'Records view only here — enrollment and marking run in the mobile app (Android/iOS).',
                style: ProxType.body(color: c.contentSecondary),
              ),
            )),
          _slim(Padding(
            padding: const EdgeInsets.only(top: ProxSpacing.xs),
            child: ProxSecondaryButton(
              icon: const Icon(Icons.history),
              label: const Text('My attendance records (synced)'),
              onPressed: widget.onViewRecords,
              expanded: true,
            ),
          )),
          _slim(Padding(
            padding: const EdgeInsets.only(top: ProxSpacing.lg),
            child: Text(
              'Live on this WiFi',
              style: ProxType.title(color: c.contentPrimary),
            ),
          )),
          _slim(DetailsExpander(
            title: 'Details',
            child: Padding(
              padding: const EdgeInsets.only(bottom: ProxSpacing.xs),
              child: LadderLine(),
            ),
          )),
          if (widget.broadcastBlocked && !_blockedDismissed) ...[
            const SizedBox(height: ProxSpacing.xs),
            _slim(_ThinBanner(
              icon: Icons.wifi_off_outlined,
              text:
                  'Classroom WiFi blocks discovery broadcasts — showing BLE-hinted classes only (hint+probe rung). Stay on the classroom WiFi.',
              onDismiss: () => setState(() => _blockedDismissed = true),
            )),
          ],
          if (widget.live.isEmpty)
            _slim(_RadarEmptyState(
              // Reduce-motion: no sweep head — the static rings + soft halo
              // carry "scanning" without motion (§9 ambient-animation rule).
              sweepAngle: ProxMotion.reduced(context) ? null : _sweep,
            ))
          else
            for (var i = 0; i < widget.live.length; i++)
              _slim(Padding(
                padding: const EdgeInsets.only(top: ProxSpacing.sm),
                child: _BrowseTile(
                  live: widget.live[i],
                  profEmail:
                      widget.profEmailByHost[widget.live[i].last.key] ?? '',
                  onTap: () => widget.onTapLive(widget.live[i]),
                ),
              )),
          _slim(Padding(
            padding: const EdgeInsets.only(top: ProxSpacing.sm),
            child: Center(
              child: FallbackButton(
                label: 'Enter IP manually',
                sheetTitle: 'Enter IP manually',
                sheetBuilder: _ipSheet,
              ),
            ),
          )),
          _slim(Padding(
            padding: const EdgeInsets.only(top: ProxSpacing.sm),
            child: Text(
              'Keep app in foreground. Backgrounding shows Paused — reopen.',
              style: ProxType.caption(color: c.contentSecondary),
              textAlign: TextAlign.center,
            ),
          )),
        ],
      ),
    );
  }

  /// Centers list content at the wide/tablet max width (§10) instead of
  /// stretching tiles edge-to-edge.
  static Widget _slim(Widget child) => Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: ProxSpacing.maxContentWidth),
          child: child,
        ),
      );
}

/// Thin dismissible inline banner (§4.6): recoverable, non-blocking
/// conditions stay on-screen in words, never as a modal.
class _ThinBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onDismiss;

  const _ThinBanner({
    required this.icon,
    required this.text,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Container(
      padding: const EdgeInsets.all(ProxSpacing.md),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: ProxRadii.cardSpecRadius,
        border: Border.all(color: c.divider),
        boxShadow: [c.elevationRaised],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: c.statusError),
          const SizedBox(width: ProxSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: ProxType.body(color: c.contentPrimary),
            ),
          ),
          const SizedBox(width: ProxSpacing.sm),
          SizedBox(
            width: ProxSpacing.minTap,
            height: ProxSpacing.minTap,
            child: IconButton(
              tooltip: 'Dismiss',
              padding: EdgeInsets.zero,
              onPressed: onDismiss,
              icon: Icon(Icons.close, size: 20, color: c.contentSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty state (§6.1): centered illustration + "Looking for a class…"
/// headline with a radar-sweep loop and `effect.glow.live` behind it — the
/// one ambient animation allowed at rest, since it signals active scanning.
/// The previous guidance copy is kept verbatim as the subline.
class _RadarEmptyState extends StatelessWidget {
  /// Ambient sweep-head angle (radians). Null renders the static rings +
  /// halo only (reduce-motion path — callers pass null there).
  final double? sweepAngle;

  const _RadarEmptyState({required this.sweepAngle});

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

/// One discovered class: the lightweight `StudentCard` variant (§6.1) —
/// course name, professor display name when given, tap → waiting — with the
/// 3-bar recency glyph + open chevron / `idle` trailing it.
class _BrowseTile extends StatelessWidget {
  final LiveClass live;
  final String profEmail;
  final VoidCallback onTap;

  const _BrowseTile({
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
