// One saved session, read-only: present/partial counts plus the per-student
// round ticks. Tapped from the course overview; native professors branch to
// the editor (fix marks) or the export center (CSV) from here. Records-only:
// viewing past marks here; the room-capture entry lives on another tab.
//
// Data logic preserved per the Phase-1 exemption (intersection present,
// partials, ticks, reload): restyle only.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

import '../../core/device_store.dart';
import '../../design/app_theme.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/clock.dart';
import '../../widgets/log_drawer.dart';
import '../../widgets/partial_list.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/student_card.dart';
import '../../widgets/verdict_badge.dart';
import '../../widgets/web_banner.dart';
import 'export_center_screen.dart';
import 'session_edit_screen.dart';
import 'session_row_card.dart';

class SessionDetailScreen extends ConsumerStatefulWidget {
  final ClassRecord record;
  /// All of the course's sessions (union source for absent/partial context).
  final List<ClassRecord> courseSessions;
  const SessionDetailScreen(
      {super.key, required this.record, this.courseSessions = const []});

  /// Canonical in-tab route name:
  /// `prof/courses/<course>/sessions/<sessionId>`.
  /// Documented equivalent (no `proxOnGenerateRoute` entry — the table only
  /// handles `prof/courses/<course>[/export]`; in-tab pushes resolve record
  /// objects directly, so this stays in-tab-only). Shares the
  /// `prof/courses/<course>` prefix so `popUntil` by course still works and
  /// NAV logs show a name (no duplicate unnamed push).
  static String routeName(String course, String sessionId) =>
      'prof/courses/$course/sessions/$sessionId';

  @override
  ConsumerState<SessionDetailScreen> createState() =>
      _SessionDetailScreenState();
}

class _SessionDetailScreenState extends ConsumerState<SessionDetailScreen> {
  late ClassRecord _record;

  /// Active Present/Partial/Absent filter tab. `all` is the legacy full
  /// list; tapping a badge narrows to that verdict, tapping it again
  /// returns to `all`.
  _SessionFilter _filter = _SessionFilter.all;

  @override
  void initState() {
    super.initState();
    _record = widget.record;
  }

  List<String> get _persons {
    final out = <String>{
      for (final w in _record.windows) ...w.keys,
      ..._record.names.keys,
    }.toList()
      ..sort();
    return out;
  }

  /// Present = in every window (intersection semantics, same as exports).
  bool _isPresent(String email) {
    if (_record.windows.isEmpty) return false;
    for (final w in _record.windows) {
      if (w[email] != true) return false;
    }
    return true;
  }

  /// Marked in at least one round (present or partial).
  bool _markedAnywhere(String email) {
    for (final w in _record.windows) {
      if (w[email] == true) return true;
    }
    return false;
  }

  /// Partial = marked in some but not all rounds.
  bool _isPartial(String email) =>
      _markedAnywhere(email) && !_isPresent(email);

  /// Course-mates absent from this session: union over the course (plus
  /// this record, so newcomers here are covered) minus anyone marked in
  /// any round here. A newcomer from a later class reads as absent in
  /// earlier ones (matching exports + the editor). Falls back to the
  /// session-local missing list when the course union is unknown.
  List<RosterEntry> _absentEntries() {
    final sessions = widget.courseSessions;
    if (sessions.isEmpty) {
      final names = _record.names;
      final rolls = _record.rolls;
      final out = [
        for (final email in _persons)
          if (!_markedAnywhere(email))
            RosterEntry(
                email: email,
                name: names[email] ?? email,
                roll: rolls[email] ?? ''),
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return out;
    }
    final here = <String>{
      for (final w in _record.windows)
        for (final e in w.entries)
          if (e.value) e.key,
    };
    final union = courseRoster([...sessions, _record]);
    return [for (final m in union) if (!here.contains(m.email)) m];
  }

  /// Per-round ticks for one student: 'R1 ✓ · R2 ✗'.
  String _ticksFor(String email) =>
      ticksForWindows(_record.windows, email);

  /// Re-reads this session after the editor saves (upsert keeps the id).
  Future<void> _reload() async {
    try {
      final history = await ref.read(deviceStoreProvider).readHistory();
      for (final r in history) {
        if (r.id == _record.id && mounted) {
          setState(() => _record = r);
          return;
        }
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _openEdit() async {
    BleLog.log('NAV', 'session ${_record.dateIso} → edit');
    final course = _record.courseId.isNotEmpty
        ? _record.courseId
        : _record.classLabel;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          settings: RouteSettings(
              name: SessionEditScreen.routeName(course, _record.id)),
          builder: (_) => SessionEditScreen(
              record: _record, courseSessions: widget.courseSessions)),
    );
    if (saved == true) await _reload();
    if (mounted) setState(() {});
  }

  void _openExport() {
    final course = _record.courseId.isNotEmpty
        ? _record.courseId
        : _record.classLabel;
    BleLog.log('NAV', 'session ${_record.dateIso} → export');
    Navigator.of(context).push(MaterialPageRoute(
        settings:
            RouteSettings(name: ExportCenterScreen.routeName(course)),
        builder: (_) => ExportCenterScreen(courseName: course)));
  }

  void _openLog() {
    BleLog.log('NAV', 'session → system log');
    showLogDrawer(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final persons = _persons;
    final presentEmails = persons.where(_isPresent).toList();
    final partialEmails = persons.where(_isPartial).toList();
    final absentEntries = _absentEntries();
    final present = presentEmails.length;
    final partials = partialEmails.length;
    final absent = absentEntries.length;
    final windows = _record.windows.length;
    final visiblePersons = switch (_filter) {
      _SessionFilter.all => persons,
      _SessionFilter.present => presentEmails,
      _SessionFilter.partial => partialEmails,
      // Absent renders from [absentEntries] below, not [persons].
      _SessionFilter.absent => const <String>[],
    };
    return AdaptiveScaffold(
      title: 'Session',
      actions: [
        IconButton(
          icon: const Icon(Icons.terminal_outlined),
          tooltip: 'System log',
          onPressed: _openLog,
        ),
      ],
      body: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: ProxSpacing.maxContentWidth),
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: ProxSpacing.screenMargin,
              vertical: ProxSpacing.lg,
            ),
            children: [
              Text(
                _record.classLabel,
                textAlign: TextAlign.center,
                style: ProxType.title(color: c.contentPrimary),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
              const SizedBox(height: ProxSpacing.xs),
              Text(
                sessionRoomyLine(_record.dateIso, _record.timestampIso),
                textAlign: TextAlign.center,
                style: ProxType.body(color: c.contentSecondary),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
              const SizedBox(height: ProxSpacing.md),
              // Same green/yellow/red share bar as the session rows.
              SessionShareBar(
                present: present,
                partial: partials,
                absent: absent,
              ),
              const SizedBox(height: ProxSpacing.sm),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: ProxSpacing.sm,
                runSpacing: ProxSpacing.xs,
                children: [
                  SelectableVerdictBadge(
                    status: ProxStatus.marked,
                    label: 'Present $present',
                    selected: _filter == _SessionFilter.present,
                    semanticLabel: 'Show present list',
                    onTap: () => setState(() => _filter =
                        _filter == _SessionFilter.present
                            ? _SessionFilter.all
                            : _SessionFilter.present),
                  ),
                  SelectableVerdictBadge(
                    status: ProxStatus.late,
                    label: 'Partial $partials',
                    selected: _filter == _SessionFilter.partial,
                    semanticLabel: 'Show partial list',
                    onTap: () => setState(() => _filter =
                        _filter == _SessionFilter.partial
                            ? _SessionFilter.all
                            : _SessionFilter.partial),
                  ),
                  SelectableVerdictBadge(
                    status: ProxStatus.absent,
                    label: 'Absent $absent',
                    selected: _filter == _SessionFilter.absent,
                    semanticLabel: 'Show absent list',
                    onTap: () => setState(() => _filter =
                        _filter == _SessionFilter.absent
                            ? _SessionFilter.all
                            : _SessionFilter.absent),
                  ),
                ],
              ),
              const SizedBox(height: ProxSpacing.xs),
              Text(
                '$windows round${windows == 1 ? '' : 's'}',
                textAlign: TextAlign.center,
                style: proxTabular(
                    context, ProxType.caption(color: c.contentSecondary)),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              if (kIsWeb) ...[
                const SizedBox(height: ProxSpacing.sm),
                const WebRecordsBanner(),
              ],
              const SizedBox(height: ProxSpacing.sm),
              if (!kIsWeb)
                ProxPrimaryButton(
                  icon: const Icon(Icons.edit),
                  label: const Text('Fix marks'),
                  onPressed: _openEdit,
                ),
              if (!kIsWeb) const SizedBox(height: ProxSpacing.sm),
              ProxSecondaryButton(
                icon: const Icon(Icons.ios_share),
                label: const Text('Export CSV'),
                onPressed: _openExport,
                expanded: true,
              ),
              const SizedBox(height: ProxSpacing.md),
              ProxSectionHeader(
                title: 'Attendance',
                padding: EdgeInsets.zero,
                // Filtered-list label: names the visible list beside the
                // title (same words as the live roster's list header).
                trailing: switch (_filter) {
                  _SessionFilter.present => Text(
                      'Present list',
                      style: ProxType.caption(
                          color: c.contentSecondary),
                    ),
                  _SessionFilter.partial => Text(
                      'Partial list',
                      style: ProxType.caption(
                          color: c.contentSecondary),
                    ),
                  _SessionFilter.absent => Text(
                      'Absent list',
                      style: ProxType.caption(
                          color: c.contentSecondary),
                    ),
                  _SessionFilter.all => null,
                },
              ),
              const SizedBox(height: ProxSpacing.md),
              if (persons.isEmpty)
                const ProxEmptyState(message: 'Nobody listed in this session.')
              else if (_filter == _SessionFilter.absent)
                if (absentEntries.isEmpty)
                  const ProxEmptyState(
                      message: 'Nobody absent — everyone on the roster '
                          'is marked in this session.')
                else
                  for (final m in absentEntries)
                    Padding(
                      key: ValueKey<String>('absent-${m.email}'),
                      padding:
                          const EdgeInsets.only(bottom: ProxSpacing.sm),
                      child: StudentCard(
                        name: m.name.isNotEmpty ? m.name : m.email,
                        subtitle:
                            '${ticksForWindows(_record.windows, m.email)} · ${rosterSubtitle(m.roll, m.email)}',
                      ),
                    )
              else if (visiblePersons.isEmpty)
                ProxEmptyState(
                    message: _filter == _SessionFilter.partial
                        ? 'No partials in this session.'
                        : 'Nobody present in every round yet.')
              else
                for (final email in visiblePersons)
                  Padding(
                    key: ValueKey<String>('person-$email'),
                    padding:
                        const EdgeInsets.only(bottom: ProxSpacing.sm),
                    child: StudentCard(
                      name: _record.names[email] ?? email,
                      subtitle:
                          '${_ticksFor(email)} · ${rosterSubtitle(_record.rolls[email] ?? '', email)}',
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Attendance filter behind the tappable Present/Partial/Absent badges.
/// `all` is the legacy full list; tapping a badge narrows to that
/// verdict, tapping it again returns to `all`. Badges render via the
/// shared [SelectableVerdictBadge] (visible selected ring).
enum _SessionFilter { all, present, partial, absent }
