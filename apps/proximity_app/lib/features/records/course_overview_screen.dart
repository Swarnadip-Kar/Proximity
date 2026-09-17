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

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../core/sync_hook.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/clock.dart';
import '../../widgets/csv_preview.dart';
import '../../widgets/details_expander.dart';
import '../../widgets/fallback_button.dart' show showProxSheet;
import '../../widgets/log_drawer.dart';
import '../../widgets/partial_list.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_shimmer.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/selection_controller.dart';
import '../../widgets/selection_toolbar.dart';
import 'session_row_card.dart';
import '../../widgets/student_card.dart';
import '../../widgets/sync_badge.dart';
import '../../widgets/web_banner.dart';
import '../live/live_refresh.dart';
import 'export_center_screen.dart';
import 'session_detail_screen.dart';

class CourseOverviewScreen extends ConsumerStatefulWidget {
  final String courseName;
  const CourseOverviewScreen({super.key, required this.courseName});

  /// Canonical in-tab route name: `prof/courses/<course>`.
  /// Matches the IA node in `proxOnGenerateRoute` so NAV logs, `popUntil`
  /// by name/prefix, and deep-links share ONE identity with the named
  /// route (no duplicate unnamed push).
  static String routeName(String course) => 'prof/courses/$course';

  @override
  ConsumerState<CourseOverviewScreen> createState() =>
      _CourseOverviewScreenState();
}

class _CourseOverviewScreenState extends ConsumerState<CourseOverviewScreen> {
  final _renameCtrl = TextEditingController();
  String? _notice;
  String? _syncMsg;
  bool _syncing = false;

  /// Setup photo opt-in for this course (off by default): the header
  /// shows my Gmail photo when on, the course logo disc otherwise.
  /// Re-read on every refresh (init, history tick, return from export/
  /// session/live-setup) so a toggle flipped in the live setup tab
  /// reflects here without an app restart.
  bool _sharePhoto = false;

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
    Future.microtask(_reloadSharePhoto);
    _historyTickListener = () {
      // History tick also means the live setup may have flipped the
      // per-course photo opt-in — re-read it so the header stays true.
      _reloadSharePhoto();
      if (mounted) setState(() {});
    };
    liveHistoryTick.addListener(_historyTickListener!);
  }

  /// Re-reads the per-course photo opt-in (setup toggle) and repaints the
  /// header. Never throws; a stale `false` keeps the logo disc (safe).
  Future<void> _reloadSharePhoto() async {
    try {
      final share = await ref
          .read(deviceStoreProvider)
          .readShowProfPhoto(widget.courseName);
      if (mounted && share != _sharePhoto) {
        setState(() => _sharePhoto = share);
      } else if (mounted) {
        // Still rebuild once so a freshly-arrived account photoUrl pairs
        // with an already-true flag on first load.
        setState(() => _sharePhoto = share);
      }
    } catch (_) {}
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
    // Sheet chrome (not AlertDialog): scrim/elevation/radius tokens,
    // ProxPrimary Save + ProxSecondary Cancel. Behavior unchanged.
    final picked = await showProxSheet<String>(
      context: context,
      title: 'Edit course',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _renameCtrl,
            decoration: const InputDecoration(labelText: 'Course name'),
            autofocus: true,
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
          const SizedBox(height: ProxSpacing.lg),
          ProxPrimaryButton(
            label: const Text('Save'),
            onPressed: () => Navigator.of(ctx).pop(_renameCtrl.text.trim()),
          ),
          const SizedBox(height: ProxSpacing.sm),
          Center(
            child: ProxSecondaryButton(
              label: const Text('Cancel'),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ),
        ],
      ),
    );
    if (picked == null || picked.isEmpty || picked == widget.courseName) {
      return;
    }
    if (!mounted) return;
    final store = ref.read(deviceStoreProvider);
    final ok =
        await syncEngine.renameCourseLocal(store, widget.courseName, picked);
    if (!mounted) return;
    if (ok) {
      // Renaming migrates local history AND re-queues every touched record:
      // the same doc ids push with the new courseId on flush (no separate
      // cloud rename batch — union merge converges other devices).
      // Carry the per-course photo opt-in to the new name so the header
      // keeps showing the Gmail photo when it was on.
      try {
        final share = await store.readShowProfPhoto(widget.courseName);
        await store.writeShowProfPhoto(picked, share);
      } catch (_) {}
      if (!mounted) return;
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
        settings: RouteSettings(
            name: ExportCenterScreen.routeName(widget.courseName)),
        builder: (_) => ExportCenterScreen(courseName: widget.courseName)));
    if (!mounted) return;
    setState(() {});
    // The live setup toggle may have flipped while away — re-read it so
    // the Gmail-photo header is current on return.
    await _reloadSharePhoto();
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

  /// Exports the hold-and-tap selected sessions as one combined matrix
  /// (same builder as the date-range export) in the shared CSV preview
  /// dialog (Close + Save + Share). Selection stays armed afterwards so
  /// the professor can delete or re-export without re-holding.
  Future<void> _exportSessions(
      List<ClassRecord> sessions, Set<String> ids) async {
    final sel = sessions.where((s) => ids.contains(s.id)).toList()
      ..sort((a, b) => b.timestampIso.compareTo(a.timestampIso));
    if (sel.isEmpty || !mounted) return;
    final acct = ref.read(accountProvider).valueOrNull;
    final csv = exportHeader(
      buildDateRangeMatrix(sel),
      profName: (acct?.displayName ?? '').trim(),
      className: widget.courseName,
      profEmail: (acct?.email ?? '').trim(),
    );
    final label =
        sel.length == 1 ? _sessionLabel(sel.first) : '${sel.length} sessions';
    BleLog.log('NAV', 'overview ${widget.courseName} → export $label');
    await showCsvPreviewDialog(
      context,
      title: '${widget.courseName} · $label',
      csv: csv,
      onSave: () => saveCsvToDevice(
          context, csv, 'attendance_${widget.courseName}_selected.csv'),
      onShare: () =>
          shareCsvText(csv, 'Attendance ${widget.courseName} ($label)'),
    );
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
          settings: RouteSettings(
              name:
                  SessionDetailScreen.routeName(widget.courseName, target.id)),
          builder: (_) =>
              SessionDetailScreen(record: target!, courseSessions: sessions)),
    );
    if (!mounted) return;
    setState(() {});
    await _reloadSharePhoto();
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
              // Total Students: unique attendees present in ≥1 session.
              // Present = confirmed (intersection of all windows, trailing
              // empties trimmed — same as presentCount / export-matrix P);
              // unioned across sessions (union, not sum) so repeat
              // attendees count once. Empty course → 0, still rendered.
              final totalStudents = <String>{
                for (final s in sessions) ...s.confirmedEmails,
              }.length;
              return SelectionScope(
                child: _OverviewBody(
                  courseName: widget.courseName,
                  sharePhoto: _sharePhoto,
                  sessions: sessions,
                  loading: snap.connectionState == ConnectionState.waiting,
                  hasData: snap.hasData,
                  rosterCount: rosterCount,
                  totalStudents: totalStudents,
                  syncing: _syncing,
                  syncMsg: _syncMsg,
                  notice: _notice,
                  onOpenExport: _openExport,
                  onOpenSession: (id) => _openSession(sessions, id),
                  onDeleteSessions: (ids) => _deleteSessions(sessions, ids),
                  onExportSessions: (ids) => _exportSessions(sessions, ids),
                  onDeleteCourse:
                      sessions.isEmpty ? null : () => _deleteCourse(sessions),
                  sessionLabel: _sessionLabel,
                  onSyncNow: _syncing ? null : () => _syncFromCloud(),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Course identity header: the professor's Gmail photo when the setup
/// photo toggle is on for this course AND an account photo exists —
/// otherwise the course logo disc. Same disc/photo language as pickers,
/// roster avatars, and the student-view preview card.
class _CourseIdentityHeader extends StatelessWidget {
  final String courseName;
  final bool sharePhoto;
  final String photoUrl;

  const _CourseIdentityHeader({
    required this.courseName,
    required this.sharePhoto,
    required this.photoUrl,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    // One course-disc path: gated photo or CS-style initials via the
    // shared component (same disc as pickers + live list).
    final avatar = ProxAvatar.course(
      course: courseName,
      photoUrl: sharePhoto ? photoUrl : '',
      size: 32,
    );
    return Row(
      children: [
        avatar,
        const SizedBox(width: ProxSpacing.md),
        Expanded(
          child: Text(
            courseName,
            style: ProxType.title(color: c.contentPrimary),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ],
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
  final String courseName;
  final bool sharePhoto;
  final List<ClassRecord> sessions;
  final bool loading;
  final bool hasData;
  final int rosterCount;
  final int totalStudents;
  final bool syncing;
  final String? syncMsg;
  final String? notice;
  final VoidCallback onOpenExport;
  final ValueChanged<String> onOpenSession;
  final Future<bool> Function(Set<String>) onDeleteSessions;
  final Future<void> Function(Set<String>) onExportSessions;
  final VoidCallback? onDeleteCourse;
  final String Function(ClassRecord) sessionLabel;
  final VoidCallback? onSyncNow;

  const _OverviewBody({
    required this.courseName,
    required this.sharePhoto,
    required this.sessions,
    required this.loading,
    required this.hasData,
    required this.rosterCount,
    required this.totalStudents,
    required this.syncing,
    required this.syncMsg,
    required this.notice,
    required this.onOpenExport,
    required this.onOpenSession,
    required this.onDeleteSessions,
    required this.onExportSessions,
    required this.onDeleteCourse,
    required this.sessionLabel,
    this.onSyncNow,
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
    final effective = selecting || (_armed && isDesktopSelection);
    final count = controller.count;
    // Local copies of the widget props (read-only aliases for the
    // rest of this build).
    final sessions = widget.sessions;
    final loading = widget.loading;
    final hasData = widget.hasData;
    final rosterCount = widget.rosterCount;
    final totalStudents = widget.totalStudents;
    final syncing = widget.syncing;
    final syncMsg = widget.syncMsg;
    final notice = widget.notice;
    final onOpenExport = widget.onOpenExport;
    final onOpenSession = widget.onOpenSession;
    final onDeleteSessions = widget.onDeleteSessions;
    final onExportSessions = widget.onExportSessions;
    final onDeleteCourse = widget.onDeleteCourse;
    // Floating Review & export docked above the shell nav bar (same
    // pattern as the Live tab). Hidden while the selection toolbar owns
    // the bottom edge. List bottom padding keeps Delete course clear of
    // the dock.
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  ProxSpacing.screenMargin,
                  ProxSpacing.lg,
                  ProxSpacing.screenMargin,
                  104,
                ),
                children: [
                  const ClockHeader(),
                  const WebRecordsBanner(),
                  if (syncing)
                    const ProxLoadingRow(label: 'Syncing with cloud…')
                  else if (syncMsg != null)
                    ProxSyncNote(syncMsg),
                  Row(
                    children: [
                      const Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: UnsyncedBadge(),
                        ),
                      ),
                      ProxSecondaryButton(
                        icon: const Icon(Icons.sync, size: 18),
                        label: const Text('Sync now'),
                        onPressed: widget.onSyncNow,
                      ),
                    ],
                  ),
                  const SizedBox(height: ProxSpacing.sm),
                  // Course identity: my Gmail photo when the setup toggle is
                  // on for this course, else the course logo disc — same
                  // avatar language as pickers and roster cards.
                  _CourseIdentityHeader(
                    courseName: widget.courseName,
                    sharePhoto: widget.sharePhoto,
                    photoUrl:
                        ref.watch(accountProvider).valueOrNull?.photoUrl ?? '',
                  ),
                  const SizedBox(height: ProxSpacing.md),
                  // Review & export lives in the floating dock below now —
                  // sessions header follows the identity block directly.
                  Row(
                    children: [
                      Expanded(
                        child: ProxSectionHeader(
                          title: 'Total Classes: ${sessions.length}',
                          padding: EdgeInsets.zero,
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
                  const SizedBox(height: ProxSpacing.sm),
                  // Total line (no badge/highlight): the same gradient-bar
                  // section header as the roster Attendance header — unique
                  // attendees present in ≥1 session (union, not a sum).
                  // Renders even when empty (0) so the count stays honest.
                  // Details drops below it.
                  ProxSectionHeader(
                    title: 'Total students: $totalStudents',
                    padding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: ProxSpacing.xs),
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
                    const ProxShimmerHost(
                      child: Column(
                        children: [
                          ProxShimmerRow(),
                          SizedBox(height: ProxSpacing.sm),
                          ProxShimmerRow(),
                          SizedBox(height: ProxSpacing.sm),
                          ProxShimmerRow(),
                        ],
                      ),
                    )
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
                        // Shared row card (same module as the export
                        // center): date main line, % top-right, counts
                        // row, share bar. Segments: confirmed present
                        // (green), partial (yellow), truly absent (red) =
                        // roster union minus both (newcomers read absent
                        // in earlier sessions, matching exports).
                        child: Builder(
                          builder: (context) {
                            final partial =
                                partialCountOf(r.windows, r.allEmails);
                            final absent =
                                (rosterCount - r.presentCount - partial)
                                    .clamp(0, 1 << 30);
                            return SessionRowCard(
                              courseName: widget.courseName,
                              title: sessionShortLine(r),
                              windows: r.windowCount,
                              present: r.presentCount,
                              partial: partial,
                              absent: absent,
                              // No avatar disc here: it eats the width the
                              // day/time + counts need on narrow phones.
                              showAvatar: false,
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
                            );
                          },
                        ),
                      ),
                  ],
                  if (!kIsWeb && hasData) ...[
                    const SizedBox(height: ProxSpacing.sm),
                    // Terminal red, same idiom as End attendance.
                    SizedBox(
                      width: double.infinity,
                      child: ProxDangerButton(
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: const [
                            Icon(Icons.delete_outline, size: 18),
                            SizedBox(width: ProxSpacing.sm),
                            Text('Delete course'),
                          ],
                        ),
                        onPressed: onDeleteCourse,
                      ),
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
                // Same hold-and-tap selection as Delete: export the held
                // dates as one combined matrix (Close + Save + Share).
                // Selection stays armed for delete/re-export.
                SelectionToolbarAction(
                  label: 'Export $count',
                  onPressed: count == 0
                      ? null
                      : () async {
                          await onExportSessions(controller.selectedIds);
                        },
                ),
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
              onSelectAll: () =>
                  controller.selectAll(sessions.map((s) => s.id)),
              // Toolbar Cancel exits selection mode entirely (clears the
              // desktop arm too); the toolbar contract itself is unchanged.
              onCancel: () {
                controller.clear();
                _disarm();
              },
            ),
          ],
        ),
        if (!selecting)
          Positioned(
            left: ProxSpacing.lg,
            right: ProxSpacing.lg,
            bottom: ProxSpacing.sm,
            child: SafeArea(
              top: false,
              child: ProxFloatingAction(
                child: ProxPrimaryButton(
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Review & export'),
                  onPressed: sessions.isEmpty ? null : onOpenExport,
                  expanded: true,
                  compact: true,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
