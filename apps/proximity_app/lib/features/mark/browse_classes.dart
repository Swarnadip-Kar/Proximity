// Browse classes (student mark): discovered classes as a lightweight
// StudentCard variant + fallback-weight IP entry + honest empty state.
//
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
//
// Mark slim-down: the Attendance-records section and the Enroll-this-device
// entry are GONE from this screen (records live in Courses, enrollment in
// Setup/Account; the Mark gate already routes unenrolled users). Kept:
// live-classes list, fallback-weight IP entry (button → sheet), the
// broadcast-blocked banner, the empty state, and the system-log entry
// (host scaffold action).
//
// Modularity: single-purpose widgets live in sibling files —
// `browse_banner.dart` (thin banner), `browse_empty.dart` (radar empty
// state), `browse_list.dart` (live tile + signal glyph). This file owns
// only the browse composition.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:proximity_transport/transport.dart';

import '../../design/tokens.dart';
import '../../widgets/clock.dart';
import '../../widgets/details_expander.dart';
import '../../widgets/fallback_button.dart';
import '../../widgets/student_card.dart' show ProxAvatar;
import 'browse_banner.dart';
import 'browse_empty.dart';
import 'browse_list.dart';
import 'join_by_ip.dart';

class BrowseClassesView extends StatefulWidget {
  /// Joining student's own name for the top-left avatar initials ('' =
  /// unknown → the avatar renders nothing, never a blank disc).
  final String avatarName;

  /// Joining student's volunteered Gmail photo ('' = initials fallback).
  final String avatarPhotoUrl;

  /// Joining student's identity lines (`name · roll\ngmail`, or the
  /// not-enrolled guidance) — the exact previous browse identity string,
  /// now rendered BESIDE the avatar instead of below the clock. '' =
  /// nothing to show (clock still renders).
  final String identityLine;

  /// Split identity lines for the Mark header: time on top, then name, ID,
  /// then email. When [identityName] is non-empty these win over the legacy
  /// combined [identityLine]; legacy callers keep passing the single string
  /// and render exactly as before.
  final String identityName;
  final String identityId;
  final String identityEmail;
  final String ipInitial;
  final ValueChanged<String?> onIpChanged;
  final VoidCallback onJoin;
  final String joinError;
  final List<LiveClass> live;
  final ValueChanged<LiveClass> onTapLive;
  final Future<void> Function() onRefresh;

  /// classes list (isolating AP) — the list below is hint-only, said aloud.
  final bool broadcastBlocked;

  /// Gated prof emails by `host:port` (from the org-checked /window
  /// unicast — never beacons/BLE). Empty/absent renders exactly as before
  /// (no dangling separators).
  final Map<String, String> profEmailByHost;

  /// Gated prof photos by `host:port` (same unicast as [profEmailByHost]).
  /// Empty/absent renders the class-letter disc (no blank avatar).
  final Map<String, String> profPhotoByHost;

  const BrowseClassesView({
    super.key,
    this.avatarName = '',
    this.avatarPhotoUrl = '',
    this.identityLine = '',
    this.identityName = '',
    this.identityId = '',
    this.identityEmail = '',
    required this.ipInitial,
    required this.onIpChanged,
    required this.onJoin,
    required this.joinError,
    required this.live,
    required this.onTapLive,
    required this.onRefresh,
    this.broadcastBlocked = false,
    this.profEmailByHost = const {},
    this.profPhotoByHost = const {},
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
    final hasAvatar = widget.avatarName.trim().isNotEmpty ||
        widget.avatarPhotoUrl.trim().isNotEmpty;
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
          // Joining-as header: enlarged avatar (volunteered Gmail photo in
          // the Accounts-page glowing gradient ring, photo → initials,
          // nothing when unknown) with metadata BESIDE it: ClockHeader on
          // top, then name, ID, email — each ellipsized on its own line.
          _slim(Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _BrowseAvatar(
                name: widget.avatarName,
                photoUrl: widget.avatarPhotoUrl,
              ),
              if (hasAvatar) const SizedBox(width: ProxSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Time on top, then name, ID, email — each on its own
                    // line. Legacy single-string callers render below the
                    // clock exactly as before.
                    const ClockHeader(),
                    if (widget.identityName.isNotEmpty) ...[
                      const SizedBox(height: ProxSpacing.xs),
                      Text(
                        widget.identityName,
                        style: ProxType.title(color: c.contentPrimary),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      if (widget.identityId.isNotEmpty)
                        Text(
                          widget.identityId,
                          style: ProxType.body(color: c.contentSecondary)
                              .copyWith(fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      if (widget.identityEmail.isNotEmpty)
                        Text(
                          widget.identityEmail,
                          style: ProxType.label(color: c.contentSecondary),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                    ] else if (widget.identityLine.isNotEmpty) ...[
                      const SizedBox(height: ProxSpacing.xs),
                      Text(
                        widget.identityLine,
                        style: ProxType.body(color: c.contentPrimary),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          )),
          if (widget.joinError.isNotEmpty && !_errorDismissed) ...[
            const SizedBox(height: ProxSpacing.sm),
            _slim(BrowseBanner(
              icon: Icons.error_outline,
              text: widget.joinError,
              onDismiss: () => setState(() => _errorDismissed = true),
            )),
          ],
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
              child: Text(
                'Join the same network as your professor and keep Bluetooth on. '
                'If your class is not visible, ask the professor to announce the IP '
                'verbally and enter it with “Enter IP manually”. '
                'Bars show how recently the class was heard: 3 = open now, '
                '2 = heard momentarily, 1 = listed from history.',
                // Same size as the previous ladder line (bodySmall).
                style: ProxType.caption(color: c.contentSecondary),
              ),
            ),
          )),
          if (widget.broadcastBlocked && !_blockedDismissed) ...[
            const SizedBox(height: ProxSpacing.xs),
            _slim(BrowseBanner(
              icon: Icons.wifi_off_outlined,
              text:
                  'Classroom WiFi blocks discovery broadcasts — showing BLE-hinted classes only (hint+probe rung). Stay on the classroom WiFi.',
              onDismiss: () => setState(() => _blockedDismissed = true),
              isError: false,
            )),
          ],
          if (widget.live.isEmpty)
            _slim(BrowseEmptyState(
              // Reduce-motion: no sweep head — the static rings + soft halo
              // carry "scanning" without motion (§9 ambient-animation rule).
              sweepAngle: ProxMotion.reduced(context) ? null : _sweep,
            ))
          else
            for (var i = 0; i < widget.live.length; i++)
              _slim(Padding(
                padding: const EdgeInsets.only(top: ProxSpacing.sm),
                child: BrowseTile(
                  live: widget.live[i],
                  profEmail:
                      widget.profEmailByHost[widget.live[i].last.key] ?? '',
                  profPhotoUrl: gatedPhotoFor(widget.profPhotoByHost,
                      widget.live[i].last.key),
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

/// Joining-as avatar for the browse top-left (visual only): the
/// volunteered Gmail photo in the Accounts-page glowing gradient ring.
/// Photo → initials fallback (shared `studentInitials` helper, same
/// contract as the roster/host avatars); unknown renders nothing, never
/// a blank disc. Static — no sweep timer, no implicit-animation loop —
/// settle-safe.
class _BrowseAvatar extends StatelessWidget {
  final String name;
  final String photoUrl;

  const _BrowseAvatar({required this.name, required this.photoUrl});

  @override
  Widget build(BuildContext context) {
    // Thin alias over the shared component — one avatar assembly left.
    return ProxAvatar(name: name, photoUrl: photoUrl, size: 56);
  }
}
