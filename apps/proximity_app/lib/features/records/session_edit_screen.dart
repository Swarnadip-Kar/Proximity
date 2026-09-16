// Fix a saved class record: the same manual-attendance UI as the live
// take-attendance screen (present list + direct entry), applied to history.
// Presence is PER WINDOW: each person expands to one checkbox per round, so
// correcting round 3 never touches rounds 1–2 (the old all-windows toggle
// collapsed multi-round variation to uniform on one save). Saved via upsert
// (same record id, startIso preserved). Web records builds never reach the
// editor — SessionDetailScreen covers viewing there; [readOnly] keeps the
// same guarantee if one is ever pushed on web.
//
// Two sub-tabs: Marks (per-round person rows + partial + absent quick
// lists + Save) and Add person (the ManualAddForm edit-* + queue behavior,
// ManualAddForm edit-* + queue behavior, unchanged). The sub-nav SWAPS
// content via an IndexedStack — each sub-tab shows ONLY its view, no shared
// scroll; inactive views stay mounted so their state survives switches.
// Draft-preservation contract (documented, no silent loss): typing in Add
// person then switching to Marks (or back) preserves the unsent form input
// (controllers stay mounted); Save lives on Marks only and persists the
// *marked* state — it does NOT consume a typed-but-unsent Add draft. The
// professor must tap `Add & mark present` on the Add tab first, then Save
// on Marks. Web readOnly hides the Add tab exactly as the inline form was
// hidden (parity: no toggles, adds, removes, or save).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../core/sync_hook.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/clock.dart';
import '../../widgets/log_drawer.dart';
import '../manual_attendance/manual_attendance.dart';
import '../../widgets/partial_list.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/web_banner.dart';

class SessionEditScreen extends ConsumerStatefulWidget {
  final ClassRecord record;
  /// All of the course's sessions (union source for the absent list).
  /// Empty when unknown — the partial list still works.
  final List<ClassRecord> courseSessions;
  /// Web records builds view only: no toggles, adds, removes, or save.
  final bool readOnly;
  const SessionEditScreen(
      {super.key,
      required this.record,
      this.courseSessions = const [],
      this.readOnly = false});

  /// Canonical in-tab route name:
  /// `prof/courses/<course>/sessions/<sessionId>/edit`.
  /// Documented equivalent (no `proxOnGenerateRoute` entry — the table only
  /// handles `prof/courses/<course>[/export]`; in-tab pushes resolve record
  /// objects directly, so this stays in-tab-only). Shares the
  /// `prof/courses/<course>` prefix so `popUntil` by course still works and
  /// NAV logs show a name (no duplicate unnamed push).
  static String routeName(String course, String sessionId) =>
      'prof/courses/$course/sessions/$sessionId/edit';

  @override
  ConsumerState<SessionEditScreen> createState() => _SessionEditScreenState();
}

class _SessionEditScreenState extends ConsumerState<SessionEditScreen> {
  late List<Map<String, bool>> _windows;
  late Map<String, String> _names;
  late Map<String, String> _rolls;

  /// Active sub-tab (0 Marks, 1 Add person). State-preserving by
  /// construction (IndexedStack keeps the inactive view mounted — the Add
  /// form draft survives switches). Forced to 0 under [readOnly] (the Add
  /// tab is hidden there, parity with the old inline form).
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _windows = [for (final w in widget.record.windows) Map.of(w)];
    _names = Map.of(widget.record.names);
    _rolls = Map.of(widget.record.rolls);
  }

  List<String> get _persons {
    final out = <String>{
      for (final w in _windows) ...w.keys,
      ..._names.keys,
    }.toList()
      ..sort();
    return out;
  }

  /// Present = in every window (intersection semantics, same as exports).
  bool _isPresent(String email) {
    if (_windows.isEmpty) return false;
    for (final w in _windows) {
      if (w[email] != true) return false;
    }
    return true;
  }

  int _presentCount(String email) {
    var n = 0;
    for (final w in _windows) {
      if (w[email] == true) n++;
    }
    return n;
  }

  void _toggleWindow(String email, int windowIdx, bool present) {
    setState(() {
      while (_windows.length <= windowIdx) {
        _windows.add(<String, bool>{});
      }
      _windows[windowIdx][email] = present;
    });
  }

  void _toggle(String email, bool present) {
    setState(() {
      if (_windows.isEmpty) _windows = [<String, bool>{}];
      for (var i = 0; i < _windows.length; i++) {
        _windows[i][email] = present;
      }
    });
  }

  void _remove(String email) {
    setState(() {
      for (final w in _windows) {
        w.remove(email);
      }
      _names.remove(email);
      _rolls.remove(email);
    });
  }

  /// Marks [email] present in every round (partial/absent quick action).
  void _markPresent(String email, {String? name, String? roll}) {
    setState(() {
      if ((name ?? '').isNotEmpty) _names[email] = name!;
      if ((roll ?? '').isNotEmpty) _rolls[email] = roll!;
      if (_windows.isEmpty) _windows = [<String, bool>{}];
      for (final w in _windows) {
        w[email] = true;
      }
    });
  }

  /// Current-state record snapshot for the partial computation below.
  ClassRecord get _draft => ClassRecord(
        id: widget.record.id,
        courseId: widget.record.courseId,
        classLabel: widget.record.classLabel,
        dateIso: widget.record.dateIso,
        timestampIso: widget.record.timestampIso,
        startIso: widget.record.startIso,
        windows: [for (final w in _windows) Map.of(w)],
        names: Map.of(_names),
        rolls: Map.of(_rolls),
      );

  /// Course-mates absent from this session: union over the course minus
  /// anyone present in any round here. A newcomer from a later class reads
  /// as absent in earlier ones (matching exports).
  List<RosterEntry> get _absent {
    if (widget.courseSessions.isEmpty) return const [];
    final here = <String>{};
    for (final w in _windows) {
      for (final e in w.entries) {
        if (e.value) here.add(e.key);
      }
    }
    return [
      for (final m in courseRoster(widget.courseSessions))
        if (!here.contains(m.email)) m
    ];
  }

  /// Shared manual-add submit (see ManualAddForm): the form guarantees an
  /// ID plus a resolved or typed name/email — or queues offline itself.
  Future<void> _add(
      {required String name,
      required String roll,
      required String email}) async {
    setState(() {
      _names[email] = name;
      if (roll.isNotEmpty) _rolls[email] = roll;
      if (_windows.isEmpty) _windows = [<String, bool>{}];
      for (final w in _windows) {
        w[email] = true;
      }
    });
  }

  Future<void> _save() async {
    // Edits stamp a fresh timestampIso (monotonic): the edited row must win
    // field conflicts on union merge instead of losing to its own older
    // cloud copy.
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final stampIso =
        nowIso.compareTo(widget.record.timestampIso) > 0 ? nowIso : widget.record.timestampIso;
    final record = ClassRecord(
      id: widget.record.id,
      courseId: widget.record.courseId,
      classLabel: widget.record.classLabel,
      dateIso: widget.record.dateIso,
      timestampIso: stampIso,
      startIso: widget.record.startIso,
      windows: _windows,
      names: _names,
      rolls: _rolls,
      org: widget.record.org,
    );
    // Durable local save + outbox enqueue with a best-effort flush
    // (SyncEngine owns the push; offline just queues).
    final prof = await readSyncProf(ref);
    if (!mounted) return;
    try {
      final store = ref.read(deviceStoreProvider);
      final cloud = ref.read(cloudSyncProvider);
      await syncEngine.noteLocalSave(
          store: store, cloud: cloud, prof: prof, record: record);
    } catch (_) {}
    BleLog.log('SYNC', 'edit: saved session ${record.dateIso}');
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _openLog() {
    BleLog.log('NAV', 'edit → system log');
    showLogDrawer(context);
  }

  void _selectTab(int i) {
    setState(() => _tab = i);
  }

  /// Marks sub-tab content: partial + absent quick lists, person rows,
  /// single-scroll layout — only the Add form moved out.
  Widget _marksTab(
      BuildContext context,
      List<String> persons,
      List<PartialEntry> partials,
      List<RosterEntry> absent) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (partials.isNotEmpty)
          ProxCard(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ProxSectionHeader(
                  title: 'Partial in this session (${partials.length})',
                  padding: const EdgeInsets.only(bottom: ProxSpacing.sm),
                ),
                for (final e in partials)
                  ProxListTile(
                    dense: true,
                    title: e.name,
                    subtitle:
                        '${e.sessions.first.$3} · ${rosterSubtitle(e.roll, e.email)}',
                    trailing: widget.readOnly
                        ? null
                        : TextButton(
                            child: const Text('Mark present'),
                            onPressed: () => _markPresent(e.email),
                          ),
                  ),
              ],
            ),
          ),
        if (absent.isNotEmpty)
          ProxCard(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ProxSectionHeader(
                  title: 'Absent (${absent.length})',
                  padding: const EdgeInsets.only(bottom: ProxSpacing.xs),
                ),
                Text(
                  'Attended another session of this course.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                for (final m in absent)
                  ProxListTile(
                    dense: true,
                    title: m.name,
                    subtitle: rosterSubtitle(m.roll, m.email),
                    trailing: widget.readOnly
                        ? null
                        : TextButton(
                            child: const Text('Mark present'),
                            onPressed: () => _markPresent(m.email,
                                name: m.name, roll: m.roll),
                          ),
                  ),
              ],
            ),
          ),
        // Restrained motion: person rows stagger on load only (capped),
        // keyed by email so ticking a checkbox never replays entrances.
        for (var pi = 0; pi < persons.length; pi++)
          ProxFadeSlideIn(
            key: ValueKey<String>('person-${persons[pi]}'),
            delay: Duration(
                milliseconds:
                    (pi * ProxDurations.staggerStep.inMilliseconds).clamp(
                        0, ProxDurations.staggerCap.inMilliseconds)),
            child: _personTile(persons[pi]),
          ),
        if (!widget.readOnly) ...[
          const SizedBox(height: 16),
          ProxPrimaryButton(
            icon: const Icon(Icons.save),
            label: const Text('Save changes'),
            onPressed: _save,
          ),
        ],
      ],
    );
  }

  /// Add-person sub-tab content: the ManualAddForm edit-* + queue behavior,
  /// unchanged (same fieldPrefix/course/sessionId/onAdd/isPresent). Kept
  /// mounted in the IndexedStack so unsent input survives tab switches.
  Widget _addTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: ManualAddForm(
        fieldPrefix: 'edit',
        course: widget.record.courseId.isNotEmpty
            ? widget.record.courseId
            : widget.record.classLabel,
        sessionId: widget.record.id,
        onAdd: _add,
        isPresent: _isPresent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final persons = _persons;
    final present = persons.where(_isPresent).length;
    // Live partial + absent lists off the current draft (they update as
    // the professor ticks boxes or marks people present).
    final partials = partialsOfCourse([_draft]);
    final absent = _absent;
    // Web readOnly parity: the Add tab is hidden exactly as the inline
    // form was (no second tab, Marks content only).
    final showTabs = !widget.readOnly;
    final tab = showTabs ? _tab : 0;
    return AdaptiveScaffold(
      title: 'Edit attendance',
      actions: [
        IconButton(
          icon: const Icon(Icons.terminal_outlined),
          tooltip: 'System log',
          onPressed: _openLog,
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  // Global date rule, display only: with-day DD-MM-YYYY.
                  '${widget.record.classLabel} · ${shortDayDateOf(widget.record.dateIso)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text('$present present · ${persons.length} listed'),
                if (widget.readOnly) ...[
                  const SizedBox(height: 8),
                  const WebRecordsBanner(),
                ],
              ],
            ),
          ),
          if (showTabs)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Marks')),
                  ButtonSegment(value: 1, label: Text('Add person')),
                ],
                selected: {tab},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  if (s.isEmpty) return;
                  _selectTab(s.first);
                },
              ),
            ),
          Expanded(
            child: showTabs
                // Real sub-tabs: the sub-nav SWAPS content via this
                // IndexedStack — each sub-tab shows ONLY its view, no
                // shared scroll, no intersection. Inactive views stay
                // mounted (state-preserving switch): Add-person input
                // survives tab switches; Save stays on Marks.
                ? IndexedStack(
                    index: tab,
                    children: [
                      _marksTab(context, persons, partials, absent),
                      _addTab(),
                    ],
                  )
                : _marksTab(context, persons, partials, absent),
          ),
        ],
      ),
    );
  }

  /// One person's per-window correction. Intentional exception to the
  /// hold-and-tap rule: this is per-round correction (Round 1 vs Round 2),
  /// not bulk selection — bulk delete lives in the course overview list.
  /// Styled to tokens (brand active, pill-tinted rows); logic unchanged
  /// (tri-state header + per-round fixes + remove).
  Widget _personTile(String email) {
    final c = ProximityColors.of(context);
    return ExpansionTile(
      dense: true,
      leading: Checkbox(
        value: _isPresent(email),
        tristate: true,
        activeColor: c.accentBrand,
        checkColor: Colors.white,
        side: BorderSide(color: c.divider),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
        visualDensity: VisualDensity.compact,
        // Tri-state: all rounds / some rounds / none — tapping
        // sets or clears every round at once; per-round fixes
        // use the switches inside. View-only on web.
        onChanged:
            widget.readOnly ? null : (v) => _toggle(email, v ?? false),
      ),
      title: Text(_names[email] ?? email),
      subtitle: Text(
          '${_presentCount(email)}/${_windows.length} rounds · ${rosterSubtitle(_rolls[email] ?? '', email)}'),
      trailing: widget.readOnly
          ? null
          : IconButton(
              icon: Icon(Icons.delete_outline, color: c.contentSecondary),
              tooltip: 'Remove',
              onPressed: () => _remove(email),
            ),
      children: [
        for (var i = 0; i < _windows.length; i++)
          CheckboxListTile(
            dense: true,
            activeColor: c.accentBrand,
            checkColor: Colors.white,
            side: BorderSide(color: c.divider),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ProxRadii.card),
            ),
            visualDensity: VisualDensity.compact,
            value: _windows[i][email] == true,
            onChanged: widget.readOnly
                ? null
                : (v) => _toggleWindow(email, i, v ?? false),
            title: Text('Round ${i + 1}'),
          ),
      ],
    );
  }
}
