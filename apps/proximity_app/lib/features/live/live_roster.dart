// Live roster (prof live): waiting area + present (intersection) +
// partial + search + per-student per-round ticks (R1 ✓ · R2 ✗).
//
// Present rule (behavioral law): present = intersection of ALL windows
// taken. A student who marked R1 but missed R2 stays visible under
// Partial with per-round ticks instead of vanishing while the header
// still reads an intersection count.
//
// One section, two composable blocks sharing the same data: the take
// screen composes [WaitingListSection], then the manual inbox + direct
// add, then [MarkedRosterSection] (search + present + partial) — the
// inbox stays near the top where approvals happen mid-class. The search
// state lives in [MarkedRosterSection]; waiting joins are keyed so the
// 1s elapsed tick rebuilds without replaying their entrances.
//
// NOTE (settle): present rows deliberately carry NO stagger entrance.
// They sit below the fold and mount late (viewport cache edge); a delayed
// cascade there lands frames across the LIVE dot's 800ms pulse boundary,
// after which pumpAndSettle can never observe idle (stop-early/retake
// tests). Waiting joins keep their keyed fade/slide entrances — that is
// the meaningful presence feedback, and it mounts above the fold.
library;

import 'package:flutter/material.dart';
import 'package:proximity_storage/storage.dart';

import '../../core/host_driver.dart';
import '../../design/tokens.dart';
import '../../widgets/partial_list.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_states.dart';

/// Per-round ticks for one student ('R1 ✓ · R2 ✗', or 'R1 ✓' pre-round).
String rosterTicksFor(Set<int> wins, List<int> windowNos) {
  if (windowNos.isEmpty) return wins.isEmpty ? 'no rounds yet' : 'R1 ✓';
  return [
    for (final w in windowNos) 'R$w ${wins.contains(w) ? '✓' : '✗'}',
  ].join(' · ');
}

/// Waiting area: who is parked for the next window to open.
class WaitingListSection extends StatelessWidget {
  final List<WaitingRow> waitingRows;

  const WaitingListSection({super.key, required this.waitingRows});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ProxSectionHeader(title: 'Waiting area (${waitingRows.length})'),
        if (waitingRows.isEmpty)
          const ProxEmptyLine('No students in the waiting area yet.')
        else
          // Keyed entrances: a join fades/slides its row in; the 1s
          // elapsed tick rebuilds with stable keys so nothing replays.
          for (final w in waitingRows)
            ProxFadeSlideIn(
              key: ValueKey<String>('waiting-${w.email}'),
              child: ProxListTile(
                tileKey: ValueKey<String>('waiting-${w.email}-tile'),
                dense: true,
                leading:
                    const Icon(Icons.hourglass_top, size: 20),
                title: w.name.isNotEmpty ? w.name : w.email,
                subtitle: rosterSubtitle(w.roll, w.email),
              ),
            ),
      ],
    );
  }
}

/// Search + present (intersection) + partial. Owns the search field state.
class MarkedRosterSection extends StatefulWidget {
  final TallyStore tally;

  const MarkedRosterSection({super.key, required this.tally});

  @override
  State<MarkedRosterSection> createState() => _MarkedRosterSectionState();
}

class _MarkedRosterSectionState extends State<MarkedRosterSection> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final tally = widget.tally;
    final present = tally.confirmedCount;
    final windowNos = tally.windowNos;
    final windowsTaken = tally.windowCount;
    // Intersection + partials: search narrows the confirmed set but keeps
    // the intersection gate (a partial never promotes via search).
    final confirmedRows = _search.isEmpty
        ? tally.confirmed
        : tally.search(_search).where((r) {
            if (windowNos.isEmpty) return r.wins.isNotEmpty;
            for (final w in windowNos) {
              if (!r.wins.contains(w)) return false;
            }
            return true;
          }).toList();
    final partialRows = _search.isEmpty
        ? tally.presentAny.where((r) {
            if (windowNos.isEmpty) return false;
            var all = true;
            for (final w in windowNos) {
              if (!r.wins.contains(w)) {
                all = false;
                break;
              }
            }
            return !all;
          }).toList()
        : const <AttendanceRecord>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('prof-search'),
          decoration: const InputDecoration(
              labelText: 'Search by name, ID, or email',
              prefixIcon: Icon(Icons.search)),
          onChanged: (v) => setState(() => _search = v),
        ),
        const SizedBox(height: 8),
        ProxSectionHeader(
          title:
              'Present — all rounds ($present) · ${windowsTaken <= 1 ? '1 round' : '$windowsTaken rounds'}',
          padding: EdgeInsets.zero,
        ),
        if (confirmedRows.isEmpty)
          const ProxEmptyLine(
              'Nobody present in every round yet — partials stay listed below.')
        else
          for (var i = 0; i < confirmedRows.length; i++)
            // No staggerIndex (see the settle note above): same Card row,
            // instant mount — the cascade would only ever play below the
            // fold, late enough to break test settling while LIVE pulses.
            ProxListTile(
              title: confirmedRows[i].name,
              subtitle:
                  '${rosterTicksFor(confirmedRows[i].wins, windowNos)} · '
                  '${rosterSubtitle(confirmedRows[i].roll, confirmedRows[i].email)}'
                  '${confirmedRows[i].late ? ' · late' : ''}',
              leading: Icon(
                Icons.check_circle,
                color: ProxStateColors.of(context, ProxState.marked),
              ),
            ),
        if (partialRows.isNotEmpty) ...[
          const SizedBox(height: 8),
          ProxSectionHeader(
            title: 'Partial — some rounds (${partialRows.length})',
            padding: EdgeInsets.zero,
          ),
          for (final r in partialRows)
            ProxListTile(
              tileKey: ValueKey<String>('partial-${r.email}'),
              dense: true,
              leading: Icon(
                Icons.timelapse,
                color: ProxStateColors.of(context, ProxState.waiting),
              ),
              title: r.name,
              subtitle:
                  '${rosterTicksFor(r.wins, windowNos)} · '
                  '${rosterSubtitle(r.roll, r.email)}'
                  '${r.late ? ' · late' : ''}',
            ),
        ],
      ],
    );
  }
}
