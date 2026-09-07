// Browse classes (student mark): identity line, enroll/records entries,
// Join-by-IP, and the live-on-this-WiFi list.
//
// Discovery is passive (UDP beacons + BLE hints + typed IP) — pull-down
// only recomputes from local state, never scans the network (enterprise
// APs have kicked phones off WiFi under probe load). Navigation (enroll,
// records, live-tile tap) delegates to the mark screen via callbacks so
// this view stays navigation-agnostic; the screen logs the NAV reason.
library;

import 'package:flutter/material.dart';
import 'package:proximity_transport/transport.dart';

import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../mode.dart';
import '../../widgets/clock.dart';
import '../../widgets/ladder_line.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_states.dart';
import 'join_by_ip.dart';

class BrowseClassesView extends StatelessWidget {
  final LinkedIdentity? linked;
  final String identityLine;
  final Key ipFieldKey;
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

  const BrowseClassesView({
    super.key,
    required this.linked,
    required this.identityLine,
    required this.ipFieldKey,
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
  });

  @override
  Widget build(BuildContext context) {
    // Pull-down = instant local refresh (expiry pruning + recompute).
    // No network scan: discovery is passive (UDP beacons + BLE hints).
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: ClockHeader(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child:
                Text(identityLine, style: Theme.of(context).textTheme.bodyMedium),
          ),
          // Mobile-only enrollment (Track 5): records-only devices
          // (desktop/web) offer no enrollment entry point at all — no
          // dead route to it. Marking guidance lives below instead.
          if (linked == null && canUseFace())
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: ProxSecondaryButton(
                icon: const Icon(Icons.badge),
                label: const Text('Enroll this device (face + ID)'),
                onPressed: onEnroll,
                expanded: true,
              ),
            ),
          if (linked == null && !canUseFace())
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                  'Records view only here — enrollment and marking run in the mobile app (Android/iOS).'),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: ProxSecondaryButton(
              icon: const Icon(Icons.history),
              label: const Text('My attendance records (synced)'),
              onPressed: onViewRecords,
              expanded: true,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: JoinByIpSection(
              fieldKey: ipFieldKey,
              initial: ipInitial,
              onChanged: onIpChanged,
              onJoin: onJoin,
              joinError: joinError,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: ProxSectionHeader(
              title: 'Live on this WiFi',
              padding: EdgeInsets.zero,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: LadderLine(),
          ),
          if (broadcastBlocked)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                  'Classroom WiFi blocks discovery broadcasts — showing BLE-hinted classes only (hint+probe rung). Stay on the classroom WiFi.'),
            ),
          if (live.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                  'No live classes heard yet. Stay on the classroom WiFi — professors appear here when they start hosting. If nothing appears, type the IP shown on the professor\u2019s screen above (Bluetooth must be on for auto-discovery).'),
            )
          else
            for (var i = 0; i < live.length; i++)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                child: ProxListTile(
                  title: live[i].last.classLabel,
                  subtitle: [
                    if (live[i].last.prof.isNotEmpty) live[i].last.prof,
                    live[i].last.host,
                    if (live[i].last.display.isNotEmpty)
                      'Code ${live[i].last.display}',
                  ].join(' · '),
                  staggerIndex: i,
                  leading: ProxDot(
                    color: live[i].last.windowOpen
                        ? ProxStateColors.of(context, ProxState.active)
                        : ProxStateColors.of(context, ProxState.neutral),
                    pulse: live[i].last.windowOpen,
                    size: 12,
                  ),
                  trailing: live[i].last.windowOpen
                      ? const Icon(Icons.chevron_right)
                      : const Text('idle'),
                  onTap: () => onTapLive(live[i]),
                ),
              ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
                'Keep app in foreground. Backgrounding shows Paused — reopen.'),
          ),
        ],
      ),
    );
  }
}
