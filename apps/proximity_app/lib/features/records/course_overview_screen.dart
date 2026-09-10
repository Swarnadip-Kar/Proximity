// One course's management page: previous sessions below (most recent
// first), rename/delete the course, multi-select session deletion with X/Y
// warnings. Review/export of the past lives in ExportCenterScreen; tapping
// a session opens SessionDetailScreen. Records-only: this tab never routes
// into room capture and shows no status chip for it.
//
// Sync law (preserved): professors signed in pull-merge on open and after an
// export returns (newer timestampIso wins per id); offline-queued manual adds
// resolve now (single-flight, live drafts excluded); local-only sessions
// push up; renames/deletes propagate to the cloud.
//
// Data logic preserved per the Phase-1 exemption (filter, sort, union,
// tombstones, rename-migrate, warnings): restyle only. Bulk selection uses
// hold-and-tap (one SelectionScope for this list + SelectionToolbar); the
// per-round correction boxes on the session edit page are the one exception
// and are untouched there.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../core/sync_hook.dart';
import '../../design/app_theme.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/clock.dart';
import '../../widgets/details_expander.dart';
import '../../widgets/log_drawer.dart';
import '../../widgets/partial_list.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/selection_controller.dart';
import '../../widgets/selection_toolbar.dart';
import '../../widgets/student_card.dart';
import '../../widgets/sync_badge.dart';
import '../../widgets/verdict_badge.dart';
import '../../widgets/web_banner.dart';
import '../live/live_refresh.dart';
import 'export_center_screen.dart';
import 'session_detail_screen.dart';

class CourseOverviewScreen extends ConsumerStatefulWidget {
  final String courseName;
  const CourseOverviewScreen({super.key, required this.courseName});

  @override
  ConsumerState<CourseOverviewScreen> createState() =>
      _CourseOverviewScreenState();
}

class _CourseOverviewScreenState extends ConsumerState<CourseOverviewScreen> {
  final _renameCtrl = TextEditingController();
  String? _notice;
  String? _syncMsg;
  bool _syncing = false;

  /// History-refresh trigger (post-End freshness, presentation/navigation
  /// only). Root cause: this state lives inside the shell IndexedStack +
  /// per-tab Navigator (pushed atop the Courses tab), which keeps it alive
  /// across Live-tab visits — the `FutureBuilder` future below never
  /// re-reads on its own, so an overview opened before End keeps serving
  /// its pre-End snapshot. The take host bumps [liveHistoryTick] when its
  /// visit writes history or exits; this listener `setState`s, which
  /// re-creates the inline future so the next read is fresh. Data/filter/
  /// sort/union/tombstone/rename logic untouched.
  VoidCallback? _historyTickListener;

  @override
  void initState() {
    super.initState();
    Future.microtask(_syncFromCloud);
    _historyTickListener = () {
      if (mounted) setState(() {});
    };
    liveHistoryTick.addListener(_historyTickListener!);
  }

  @override
  void dispose() {
    if (_historyTickListener != null) {
      liveHistoryTick.removeListener(_historyTickListener!);
    }
    _renameCtrl.dispose();
    super.dispose();
  }

  /// Pull-merge on open through the SyncEngine (single-flight flush:
  /// tombstones -> outbox FIFO with union-merge-before-push -> manual
  /// queue -> pull-union converge). Offline/failures keep local data quietly.
  Future<void> _syncFromCloud() async {
    if (mounted) setState(() => _syncing = true);
    final res = await flushNow(ref);
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _syncMsg = !res.online
          ? 'Offline — showing this device only.'
          : res.remaining > 0
              ? 'Synced with cloud (${res.remaining} still pending).'
              : 'Synced with cloud.';
    });
  }

  Future<void> _rename() async {
    _renameCtrl.text = widget.courseName;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit course'),
        content: TextField(
          controller: _renameCtrl,
          decoration: const InputDecoration(labelText: 'Course name'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_renameCtrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (picked == null || picked.isEmpty || picked == widget.courseName) {
      return;
    }
    final ok = await syncEngine.renameCourseLocal(
        ref.read(deviceStoreProvider), widget.courseName, picked);
    if (!mounted) return;
    if (ok) {
      // Renaming migrates local history AND re-queues every touched record:
      // the same doc ids push with the new courseId on flush (no separate
      // cloud rename batch — union merge converges other devices).
      BleLog.log('SYNC', 'overview: renamed ${widget.courseName} → $picked');
      unawaited(flushNow(ref));
      Navigator.of(context).pop(); // back to the refreshed course list
    } else {
      setState(() => _notice = 'Name unchanged — empty or already used.');
    }
  }

  List<ClassRecord> _sessions(List<ClassRecord> history) {
    final out = history
        .where((r) =>
            r.courseId == widget.courseName ||
            (r.courseId.isEmpty && r.classLabel == widget.courseName))
        .toList()
      ..sort((a, b) => b.timestampIso.compareTo(a.timestampIso));
    return out;
  }

  Future<void> _openExport() async {
    BleLog.log('NAV', 'overview ${widget.courseName} → export');
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ExportCenterScreen(courseName: widget.courseName)));
    if (mounted) setState(() {});
  }

  void _openLog() {
    BleLog.log('NAV', 'overview → system log');
    showLogDrawer(context);
  }

  /// Deletes the whole course (catalog entry + sessions + cloud copies)
  /// with the X/Y warning: X students, Y sessions. Native only.
  Future<void> _deleteCourse(List<ClassRecord> sessions) async {
    final stats = deletionStats(sessions);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete course ${widget.courseName}?'),
        content: Text(
            'This will delete attendance data of ${stats.students} students for ${stats.sessions} sessions. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final repo = ref.read(deviceStoreProvider);
    final courseIds = sessions.map((s) => s.id).toList();
    // Tombstone first (durable delete for the cloud), then the catalog
    // entry — the sessions are already gone by then.
    await syncEngine.deleteSessionsLocal(repo, courseIds,
        courseOf: (_) => widget.courseName);
    await repo.deleteCourse(widget.courseName);
    BleLog.log('SYNC',
        'overview: deleted course ${widget.courseName} (${stats.students}/${stats.sessions})');
    // Tombstones propagate on flush (other devices drop them on next sync).
    unawaited(flushNow(ref));
    if (mounted) Navigator.of(context).pop();
  }

  /// Deletes the hold-and-tap selected sessions with the X/Y warning.
  /// Returns true when sessions were deleted.
  Future<bool> _deleteSessions(
      List<ClassRecord> sessions, Set<String> ids) async {
    final sel = sessions.where((s) => ids.contains(s.id)).toList();
    if (sel.isEmpty) return false;
    final stats = deletionStats(sel);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete sessions?'),
        content: Text(
            'This will delete attendance data of ${stats.students} students for ${stats.sessions} sessions. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return false;
    final deleted = sel.map((s) => s.id).toList();
    await syncEngine.deleteSessionsLocal(ref.read(deviceStoreProvider), deleted,
        courseOf: (_) => widget.courseName);
    BleLog.log('SYNC',
        'overview: deleted ${deleted.length} sessions (${stats.students} students)');
    // Tombstones propagate on flush (other devices drop them on next sync).
    unawaited(flushNow(ref));
    if (mounted) {
      setState(() {
        _notice = null;
      });
    }
    return true;
  }

  /// Tight title: short weekday + day/month, time when known
  /// ('CS201 · Thu, 3 Sep · 10:00').
  String _sessionLabel(ClassRecord r) =>
      sessionTightLabel(r.classLabel, r.dateIso, r.timestampIso);

  /// Roomy subtitle line: full weekday, date and year.
  String _sessionDateLine(ClassRecord r) =>
      sessionRoomyLine(r.dateIso, r.timestampIso);

  /// Partial marker for the session row (multi-round sessions only):
  /// "Partial (2)". The full per-student list lives in the session
  /// detail, where the professor can mark them present.
  String _partialMarker(ClassRecord r) {
    final n = partialCountOf(r.windows, r.allEmails);
    return n == 0 ? '' : 'Partial ($n)';
  }

  /// Tap opens the read-only session detail (edit/export branch from there).
  Future<void> _openSession(List<ClassRecord> sessions, String id) async {
    ClassRecord? target;
    for (final r in sessions) {
      if (r.id == id) {
        target = r;
        break;
      }
    }
    if (target == null || !mounted) return;
    BleLog.log('NAV', 'overview → session ${target.dateIso}');
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) =>
              SessionDetailScreen(record: target!, courseSessions: sessions)),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(deviceStoreProvider);
    return AdaptiveScaffold(
      title: widget.courseName,
      actions: [
        IconButton(
          icon: const Icon(Icons.terminal_outlined),
          tooltip: 'System log',
          onPressed: _openLog,
        ),
        if (!kIsWeb)
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Edit course',
            onPressed: _rename,
          ),
      ],
      body: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: ProxSpacing.maxContentWidth),
          child: FutureBuilder<List<ClassRecord>>(
            future: store.readHistory(),
            builder: (context, snap) {
              final sessions = _sessions(snap.data ?? const <ClassRecord>[]);
              // Roster union: everyone ever seen in any session of this course.
              // Newcomers from later classes read as absent in earlier ones,
              // matching the matrix exports.
              final rosterCount = courseRoster(sessions).length;
              return SelectionScope(
                child: _OverviewBody(
                  sessions: sessions,
                  loading: snap.connectionState == ConnectionState.waiting,
                  hasData: snap.hasData,
                  rosterCount: rosterCount,
                  syncing: _syncing,
                  syncMsg: _syncMsg,
                  notice: _notice,
                  onOpenExport: _openExport,
                  onOpenSession: (id) => _openSession(sessions, id),
                  onDeleteSessions: (ids) => _deleteSessions(sessions, ids),
                  onDeleteCourse:
                      sessions.isEmpty ? null : () => _deleteCourse(sessions),
                  sessionLabel: _sessionLabel,
                  sessionDateLine: _sessionDateLine,
                  partialMarker: _partialMarker,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Overview content inside one [SelectionScope]: session rows use
/// hold-and-tap selection with a bottom toolbar
/// (Delete N · Select all · Cancel). No checkbox appears here; the
/// session-edit page keeps the per-round correction boxes. On desktop
/// only, a Select/Done toggle arms selection mode (same pattern as the
/// manual inbox) and right-click enters with that row — same controller,
/// same toolbar.
class _OverviewBody extends ConsumerStatefulWidget {
  final List<ClassRecord> sessions;
  final bool loading;
  final bool hasData;
  final int rosterCount;
  final bool syncing;
  final String? syncMsg;
  final String? notice;
  final VoidCallback onOpenExport;
  final ValueChanged<String> onOpenSession;
  final Future<bool> Function(Set<String>) onDeleteSessions;
  final VoidCallback? onDeleteCourse;
  final String Function(ClassRecord) sessionLabel;
  final String Function(ClassRecord) sessionDateLine;
  final String Function(ClassRecord) partialMarker;

  const _OverviewBody({
    required this.sessions,
    required this.loading,
    required this.hasData,
    required this.rosterCount,
    required this.syncing,
    required this.syncMsg,
    required this.notice,
    required this.onOpenExport,
    required this.onOpenSession,
    required this.onDeleteSessions,
    required this.onDeleteCourse,
    required this.sessionLabel,
    required this.sessionDateLine,
    required this.partialMarker,
  });

  @override
  ConsumerState<_OverviewBody> createState() => _OverviewBodyState();
}

class _OverviewBodyState extends ConsumerState<_OverviewBody> {
  /// Desktop Select-toggle arm (mirrors the manual inbox): widens
  /// selectionMode so plain left-clicks toggle while armed. Same
  /// controller, same toolbar — presentation state only, never set
  /// off-desktop (no toggle renders there).
  var _armed = false;

  void _disarm() {
    if (_armed && mounted) setState(() => _armed = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final controller = ref.watch(selectionControllerProvider);
    final selecting = controller.selecting && !kIsWeb;
    // Off-desktop the arm is never set, so this equals the old
    // `selecting` exactly (mobile/web paths byte-identical).
    final effective = selecting || (_armed && isDesktopSelection);
    final count = controller.count;
    // Local copies of the widget props (read-only aliases for the
    // rest of this build).
    final sessions = widget.sessions;
    final loading = widget.loading;
    final hasData = widget.hasData;
    final rosterCount = widget.rosterCount;
    final syncing = widget.syncing;
    final syncMsg = widget.syncMsg;
    final notice = widget.notice;
    final onOpenExport = widget.onOpenExport;
    final onOpenSession = widget.onOpenSession;
    final onDeleteSessions = widget.onDeleteSessions;
    final onDeleteCourse = widget.onDeleteCourse;
    final sessionLabel = widget.sessionLabel;
    final sessionDateLine = widget.sessionDateLine;
    final partialMarker = widget.partialMarker;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: ProxSpacing.screenMargin,
              vertical: ProxSpacing.lg,
            ),
            children: [
              const ClockHeader(),
              const WebRecordsBanner(),
              if (syncing)
                const ProxLoadingRow(label: 'Syncing with cloud…')
              else if (syncMsg != null)
                ProxSyncNote(syncMsg),
              const Align(
                alignment: Alignment.centerLeft,
                child: UnsyncedBadge(),
              ),
              const SizedBox(height: ProxSpacing.sm),
              ProxSecondaryButton(
                icon: const Icon(Icons.ios_share),
                label: const Text('Review & export'),
                onPressed: sessions.isEmpty ? null : onOpenExport,
                expanded: true,
              ),
              const SizedBox(height: ProxSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '$rosterCount people · ${sessions.length} sessions',
                      style: proxTabular(
                          context, ProxType.label(color: c.contentPrimary)),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  // Mouse-first entry (desktop only): arms selection mode
                  // so left-clicks toggle; Done disarms + clears. Renders
                  // nothing on touch devices.
                  SelectionModeToggle(
                    selecting: effective,
                    onSelect: () => setState(() => _armed = true),
                    onDone: () {
                      controller.clear();
                      _disarm();
                    },
                  ),
                ],
              ),
              DetailsExpander(
                title: 'Details',
                child: Text(
                  'The roster unions everyone seen in any session. Newcomers appear absent in earlier sessions, matching exports.',
                  style: ProxType.caption(color: c.contentSecondary),
                ),
              ),
              if (notice != null) ...[
                const SizedBox(height: ProxSpacing.sm),
                ProxErrorNote(notice),
              ],
              const SizedBox(height: ProxSpacing.sm),
              if (loading)
                const Center(child: CircularProgressIndicator())
              else if (sessions.isEmpty)
                const ProxEmptyState(
                  message: 'No sessions yet for this course.',
                )
              else ...[
                // One-time hold-to-select hint (§9): once per install,
                // hidden while selecting. Web builds have no multi-delete
                // selection, so the mark stays a native affordance.
                if (!kIsWeb)
                  SelectionCoachMark(
                    listType: SelectionCoachMarks.sessions,
                    selecting: effective,
                  ),
                for (final r in sessions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: ProxSpacing.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: StudentCard(
                            name: sessionLabel(r),
                            subtitle:
                                '${sessionDateLine(r)} · ${r.presentCount} present · ${r.windowCount} window${r.windowCount == 1 ? '' : 's'}',
                            status: partialMarker(r).isEmpty
                                ? null
                                : VerdictBadge(
                                    status: ProxStatus.review,
                                    label: partialMarker(r),
                                  ),
                            selectionMode: effective,
                            selected: controller.isSelected(r.id),
                            // No multi-delete selection on web records builds.
                            onSelectionChanged: kIsWeb
                                ? null
                                : (select) {
                                    if (select) {
                                      controller.select(r.id);
                                    } else {
                                      controller.deselect(r.id);
                                    }
                                  },
                            onTap: () => onOpenSession(r.id),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.ios_share),
                          tooltip: 'Export CSV',
                          onPressed: onOpenExport,
                        ),
                      ],
                    ),
                  ),
              ],
              if (!kIsWeb && hasData) ...[
                const SizedBox(height: ProxSpacing.sm),
                ProxSecondaryButton(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete course'),
                  onPressed: onDeleteCourse,
                  expanded: true,
                ),
              ],
            ],
          ),
        ),
        SelectionToolbar(
          visible: selecting,
          selectedCount: count,
          totalCount: sessions.length,
          actions: [
            SelectionToolbarAction(
              label: 'Delete $count',
              onPressed: count == 0
                  ? null
                  : () async {
                      final ids = controller.selectedIds;
                      final deleted = await onDeleteSessions(ids);
                      if (deleted) controller.clear();
                      // A delete that empties the list also drops the
                      // desktop arm.
                      if (_armed && !controller.selecting) _disarm();
                    },
            ),
          ],
          onSelectAll: () => controller.selectAll(sessions.map((s) => s.id)),
          // Toolbar Cancel exits selection mode entirely (clears the
          // desktop arm too); the toolbar contract itself is unchanged.
          onCancel: () {
            controller.clear();
            _disarm();
          },
        ),
      ],
    );
  }
}
