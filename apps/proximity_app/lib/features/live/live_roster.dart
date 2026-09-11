// Live roster (prof live, §7.1): waiting area + present (intersection) +
// partial + dup flags + search + per-student per-round ticks (R1 ✓ · R2 ✗).
//
// render as the one shared `StudentCard` (§4.1) with round-tick pills
// instead of screen-local tiles and raw tick strings. Present rule,
// intersection gate (partials never promote via search), search filter,
//
// Present rule (behavioral law): present = intersection of ALL windows
// taken. A student who marked R1 but missed R2 stays visible under
// Partial with per-round ticks instead of vanishing while the header
// still reads an intersection count.
//
// One roster, single-purpose blocks sharing the same data: [LiveRosterBody]
// composes [WaitingListSection], [DupFlagSection], then
// [MarkedRosterSection] (search + [PresentSection] + [PartialSection]).
// Manual inbox + direct add NEVER compose here — they live behind the
// sub-nav as their own sections (the inbox/add screens composing the
// `features/manual_attendance/` module, §4.8). The search
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
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/student_card.dart';
import '../../widgets/verdict_badge.dart';

/// Round-tick pills for one student (per-round R1/R2 trail).
List<RoundTick> rosterTickPills(Set<int> wins, List<int> windowNos) {
  if (windowNos.isEmpty) {
    return wins.isEmpty ? const [] : const [RoundTick('R1', present: true)];
  }
  return [
    for (final w in windowNos)
      RoundTick('R$w', present: wins.contains(w)),
  ];
}

/// Swipe-to-remove row: professor eject with a confirm step. Renders the
/// plain [child] when [onRemove] is null (tests/read-only surfaces).
/// Delete affordance is a trailing red wash + icon (end-to-start swipe),
/// confirmed via dialog — never a bare tap target mid-lecture.
class RemovableRosterRow extends StatelessWidget {
  final String email;
  final String displayName;
  final Future<bool> Function(String email)? onRemove;
  final Widget child;

  const RemovableRosterRow({
    super.key,
    required this.email,
    required this.displayName,
    required this.onRemove,
    required this.child,
  });

  Future<bool?> _confirm(BuildContext context) {
    final c = ProximityColors.of(context);
    return showDialog<bool>(
      context: context,
      // Dialog-local context for pops: the row's own context may unmount
      // while the dialog is open (live list rebuilds every second), which
      // strands taps on a route that never closes.
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'Remove $displayName?',
          style: ProxType.title(color: c.contentPrimary),
        ),
        content: Text(
          'They leave the waiting list and the marked roster for this '
          'session. Saved history is untouched, and they can rejoin or '
          're-mark afterwards.',
          style: ProxType.body(color: c.contentSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: c.statusError,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final remove = onRemove;
    if (remove == null) return child;
    final c = ProximityColors.of(context);
    return Dismissible(
      key: ValueKey<String>('roster-remove-$email'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        final confirmed = await _confirm(context);
        if (confirmed != true) return false;
        try {
          return await remove(email);
        } catch (_) {
          return false;
        }
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: ProxSpacing.lg),
        decoration: BoxDecoration(
          color: c.statusError.withValues(alpha: 0.12),
          borderRadius: ProxRadii.cardSpecRadius,
        ),
        child: Icon(Icons.delete_outline, color: c.statusError),
      ),
      child: child,
    );
  }
}

/// Waiting area: who is parked for the next window to open.
class WaitingListSection extends StatelessWidget {
  final List<WaitingRow> waitingRows;

  /// Professor eject sink (null = read-only, no swipe affordance).
  final Future<bool> Function(String email)? onRemove;

  const WaitingListSection(
      {super.key, required this.waitingRows, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            // Breathing presence halo: the waiting area is live. The dot
            // itself stays static — ProxDot(pulse:true) runs a continuous
            // implicit animation that pumpAndSettle can never outlast
            // (same reason roster badges are static). The halo steps on a
            // settle-safe timer instead.
            ProxPulseGlow(
              color: ProxStateColors.of(context, ProxState.waiting),
              blurRadius: 12,
              child: ProxDot(
                color: ProxStateColors.of(context, ProxState.waiting),
              ),
            ),
            const SizedBox(width: ProxSpacing.sm),
            Expanded(
              child: Text(
                'Waiting area (${waitingRows.length})',
                style: ProxType.title(color: c.contentPrimary),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: ProxSpacing.sm),
        if (waitingRows.isEmpty)
          const ProxEmptyLine('No students in the waiting area yet.')
        else
          // Keyed entrances: a join fades/slides its row in; the 1s
          // elapsed tick rebuilds with stable keys so nothing replays.
          for (final w in waitingRows)
            Padding(
              key: ValueKey<String>('waiting-${w.email}'),
              padding: const EdgeInsets.only(bottom: ProxSpacing.sm),
              child: ProxFadeSlideIn(
                child: RemovableRosterRow(
                  email: w.email,
                  displayName: w.name.isNotEmpty ? w.name : w.email,
                  onRemove: onRemove,
                  child: StudentCard(
                    name: w.name.isNotEmpty ? w.name : w.email,
                    subtitle: rosterSubtitle(w.roll, w.email),
                    photoUrl: w.photoUrl,
                    // Static badge: meaning rides on icon + word, and a
                    // pulsing badge would keep tests from settling.
                    status:
                        const VerdictBadge(status: ProxStatus.waiting),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}

/// Thin roster-only composer: waiting + dup flags + marked (search +
/// present + partial). Manual inbox + direct add never compose here —
/// they are their own sections behind the sub-nav (the inbox/add screens
/// composing the `features/manual_attendance/` module).
class LiveRosterBody extends StatelessWidget {
  final List<WaitingRow> waitingRows;

  /// Symmetric email → peer emails, from [HostDriver.dupGroups].
  final Map<String, Set<String>> groups;

  /// Email → display name (falls back to the email).
  final Map<String, String> names;

  /// Called with ONE member email; the driver clears the whole group.
  final Future<void> Function(String email) onResolve;

  final TallyStore tally;

  /// Professor eject sink (null = read-only roster, no swipe affordance).
  final Future<bool> Function(String email)? onRemoveStudent;

  const LiveRosterBody({
    super.key,
    required this.waitingRows,
    required this.groups,
    required this.names,
    required this.onResolve,
    required this.tally,
    this.onRemoveStudent,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WaitingListSection(
            waitingRows: waitingRows, onRemove: onRemoveStudent),
        const SizedBox(height: ProxSpacing.sm),
        DupFlagSection(
          groups: groups,
          names: names,
          onResolve: onResolve,
        ),
        const SizedBox(height: ProxSpacing.sm),
        MarkedRosterSection(tally: tally, onRemove: onRemoveStudent),
      ],
    );
  }
}

/// Controlled-by-parent search field for the marked roster. The text state
/// lives in [MarkedRosterSection] (via [onChanged]); this widget is only
/// the field — same key, label, and icon as before.
class RosterSearchField extends StatelessWidget {
  final ValueChanged<String> onChanged;

  const RosterSearchField({super.key, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('prof-search'),
      decoration: const InputDecoration(
          labelText: 'Search by name, ID, or email',
          prefixIcon: Icon(Icons.search)),
      onChanged: onChanged,
    );
  }
}

/// Present (intersection) rows: every round taken. Single purpose — header
/// + present rows only; the intersection gate and search narrowing stay in
/// [MarkedRosterSection], which passes the already-filtered rows down.
class PresentSection extends StatelessWidget {
  final int present;
  final int windowsTaken;
  final List<AttendanceRecord> confirmedRows;
  final List<int> windowNos;

  /// Professor eject sink (null = read-only, no swipe affordance).
  final Future<bool> Function(String email)? onRemove;

  const PresentSection({
    super.key,
    required this.present,
    required this.windowsTaken,
    required this.confirmedRows,
    required this.windowNos,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Present — all rounds ($present) · ${windowsTaken <= 1 ? '1 round' : '$windowsTaken rounds'}',
          style: ProxType.title(color: c.contentPrimary),
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
        const SizedBox(height: ProxSpacing.sm),
        if (confirmedRows.isEmpty)
          const ProxEmptyLine(
              'Nobody present in every round yet — partials stay listed below.')
        else
          // No entrance motion on present rows (see the settle note
          // above): same card row, instant mount — the cascade would
          // only ever play below the fold, late enough to break test
          // settling while LIVE pulses. Status slot carries the STATIC
          // Late badge only: the marked elastic pop must not mount
          // under the take screen's 1s ticking parent (it never
          // settles in widget tests, and replaying transition motion
          // on every mount violates "updates in place"). Presence is
          // already stated by the section header + round-tick pills.
          // Same StudentCard contract as waiting/inbox (name-or-email
          // title + volunteered Gmail photo, initials fallback).
          for (final r in confirmedRows)
            Padding(
              padding: const EdgeInsets.only(bottom: ProxSpacing.sm),
              child: RemovableRosterRow(
                email: r.email,
                displayName: r.name.isNotEmpty ? r.name : r.email,
                onRemove: onRemove,
                child: StudentCard(
                  name: r.name.isNotEmpty ? r.name : r.email,
                  subtitle:
                      '${rosterSubtitle(r.roll, r.email)}${r.late ? ' · late' : ''}',
                  photoUrl: r.photoUrl,
                  status: r.late
                      ? const VerdictBadge(status: ProxStatus.late)
                      : null,
                  roundTrail: rosterTickPills(r.wins, windowNos),
                ),
              ),
            ),
      ],
    );
  }
}

/// Partial rows: some (but not all) rounds taken. Single purpose — header
/// + partial rows only; renders nothing when there are no partials.
class PartialSection extends StatelessWidget {
  final List<AttendanceRecord> partialRows;
  final List<int> windowNos;

  /// Professor eject sink (null = read-only, no swipe affordance).
  final Future<bool> Function(String email)? onRemove;

  const PartialSection({
    super.key,
    required this.partialRows,
    required this.windowNos,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    if (partialRows.isEmpty) return const SizedBox.shrink();
    final c = ProximityColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: ProxSpacing.xs),
        Text(
          'Partial — some rounds (${partialRows.length})',
          style: ProxType.title(color: c.contentPrimary),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        const SizedBox(height: ProxSpacing.sm),
        // Same StudentCard contract as waiting/inbox (name-or-email
        // title + volunteered Gmail photo, initials fallback).
        for (final r in partialRows)
          Padding(
            key: ValueKey<String>('partial-${r.email}'),
            padding: const EdgeInsets.only(bottom: ProxSpacing.sm),
            child: RemovableRosterRow(
              email: r.email,
              displayName: r.name.isNotEmpty ? r.name : r.email,
              onRemove: onRemove,
              child: StudentCard(
                name: r.name.isNotEmpty ? r.name : r.email,
                subtitle:
                    '${rosterSubtitle(r.roll, r.email)}${r.late ? ' · late' : ''}',
                photoUrl: r.photoUrl,
                roundTrail: rosterTickPills(r.wins, windowNos),
              ),
            ),
          ),
      ],
    );
  }
}

/// Search + present (intersection) + partial. Owns the search field state
/// and the intersection-gated filtering; renders via [RosterSearchField],
/// driver reads and filtering are unchanged).
class MarkedRosterSection extends StatefulWidget {
  final TallyStore tally;

  /// Professor eject sink, threaded to present + partial rows.
  final Future<bool> Function(String email)? onRemove;

  const MarkedRosterSection(
      {super.key, required this.tally, this.onRemove});

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
        RosterSearchField(
          onChanged: (v) => setState(() => _search = v),
        ),
        const SizedBox(height: ProxSpacing.sm),
        PresentSection(
          present: present,
          windowsTaken: windowsTaken,
          confirmedRows: confirmedRows,
          windowNos: windowNos,
          onRemove: widget.onRemove,
        ),
        PartialSection(
          partialRows: partialRows,
          windowNos: windowNos,
          onRemove: widget.onRemove,
        ),
      ],
    );
  }
}

/// Roster-visible duplicate-face flags (local-session path): one neutral
/// card per group — "Duplicate face detected between [A] and [B]" (+N for
/// larger groups) — with a 1-tap professor override. Never an accusation
/// (twins/siblings are the known false-positive class and both faces are
/// in the room); never auto-absent (presence untouched — this only clears
/// the flag + exempts the pair for the session). Renders nothing when
/// there are no groups.
class DupFlagSection extends StatefulWidget {
  /// Symmetric email → peer emails, from [HostDriver.dupGroups].
  final Map<String, Set<String>> groups;

  /// Email → display name (falls back to the email).
  final Map<String, String> names;

  /// Called with ONE member email; the driver clears the whole group.
  final Future<void> Function(String email) onResolve;

  const DupFlagSection({
    super.key,
    required this.groups,
    required this.names,
    required this.onResolve,
  });

  @override
  State<DupFlagSection> createState() => _DupFlagSectionState();

  /// Distinct groups from the symmetric map (each pair stored twice).
  @visibleForTesting
  static List<List<String>> distinctGroups(Map<String, Set<String>> groups) {    final seen = <String>{};
    final out = <List<String>>[];
    final emails = groups.keys.toList()..sort();
    for (final e in emails) {
      final members = <String>{e, ...?groups[e]}.toList()..sort();
      if (members.length < 2) continue;
      final key = members.join('\x00');
      if (seen.add(key)) out.add(members);
    }
    return out;
  }
}

class _DupFlagSectionState extends State<DupFlagSection> {
  /// Group keys hidden after a successful tap (the parent driver may not
  /// rebuild immediately; the flag is already cleared driver-side).
  final Set<String> _dismissed = {};
  final Set<String> _resolving = {};

  static String _key(List<String> members) => members.join('\x00');

  @override
  void didUpdateWidget(covariant DupFlagSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groups != widget.groups) {
      final live = {
        for (final m in DupFlagSection.distinctGroups(widget.groups)) _key(m),
      };
      _dismissed.retainAll(live);
      _resolving.retainAll(live);
    }
  }

  Future<void> _resolve(List<String> members) async {
    final key = _key(members);
    if (!_resolving.add(key)) return;
    try {
      await widget.onResolve(members.first);
      if (mounted) setState(() => _dismissed.add(key));
    } catch (_) {
      // Leave the card visible: the flag was not cleared.
    } finally {
      if (mounted) setState(() => _resolving.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final found = [
      for (final m in DupFlagSection.distinctGroups(widget.groups))
        if (!_dismissed.contains(_key(m))) m,
    ];
    if (found.isEmpty) return const SizedBox.shrink();
    String label(String email) {
      final n = (widget.names[email] ?? '').trim();
      return n.isNotEmpty ? '$n ($email)' : email;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ProxSectionHeader(
          title: 'Needs review — duplicate face (${found.length})',
          padding: EdgeInsets.zero,
        ),
        for (final members in found)
          ProxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.face_retouching_off_outlined,
                      color: ProxStateColors.of(context, ProxState.waiting),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Duplicate face detected between '
                        '${members.map(label).join(', ')} — '
                        'both stay marked; this sometimes happens with '
                        'siblings. Tap below if these are different people.',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ProxSecondaryButton(
                  icon: const Icon(Icons.check),
                  label: Text(_resolving.contains(_key(members))
                      ? 'Resolving…'
                      : 'Not a duplicate'),
                  expanded: true,
                  onPressed: _resolving.contains(_key(members))
                      ? null
                      : () => _resolve(members),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
