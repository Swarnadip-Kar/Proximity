// One course's management page: Take a new visit on top, previous sessions
// below (most recent first), rename/delete the course, multi-select session
// deletion with X/Y warnings. Review/export of the past lives in
// ExportCenterScreen; one tapping a session opens SessionDetailScreen.
//
// Sync law (preserved): professors signed in pull-merge on open and after a
// take returns (newer timestampIso wins per id); offline-queued manual adds
// resolve now (single-flight, live drafts excluded — the visit is still
// open); local-only sessions push up; renames/deletes propagate to the cloud.
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
import '../../screens/take_attendance.dart';
import '../../widgets/clock.dart';
import '../../widgets/partial_list.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/sync_badge.dart';
import '../../widgets/web_banner.dart';
import '../debug/debug_log_screen.dart';
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
  final Set<String> _selected = {};
  String? _syncMsg;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_syncFromCloud);
  }

  @override
  void dispose() {
    _renameCtrl.dispose();
    super.dispose();
  }

  /// Pull-merge on open through the SyncEngine (single-flight flush:
  /// tombstones -> outbox FIFO with union-merge-before-push -> manual
  /// queue -> pull-union converge). Runs on page open and after
  /// take-attendance returns. Offline/failures keep local data quietly.
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

  Future<void> _takeAttendance({bool autoStart = false}) async {
    BleLog.log('NAV', 'overview ${widget.courseName} → take');
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TakeAttendanceScreen(
            courseName: widget.courseName, autoStart: autoStart)));
    if (mounted) setState(() {});
    // Returning from a live session: pull cloud merges (other devices may
    // have marked meanwhile) without blocking the list.
    unawaited(_syncFromCloud());
  }

  Future<void> _openExport() async {
    BleLog.log('NAV', 'overview ${widget.courseName} → export');
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ExportCenterScreen(courseName: widget.courseName)));
    if (mounted) setState(() {});
  }

  void _openLog() {
    BleLog.log('NAV', 'overview → system log');
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DebugLogScreen()));
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

  Future<void> _deleteSelected(List<ClassRecord> sessions) async {
    final sel = sessions.where((s) => _selected.contains(s.id)).toList();
    if (sel.isEmpty) return;
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
    if (confirm != true || !mounted) return;
    final ids = sel.map((s) => s.id).toList();
    await syncEngine.deleteSessionsLocal(ref.read(deviceStoreProvider), ids,
        courseOf: (_) => widget.courseName);
    BleLog.log('SYNC',
        'overview: deleted ${ids.length} sessions (${stats.students} students)');
    // Tombstones propagate on flush (other devices drop them on next sync).
    unawaited(flushNow(ref));
    if (mounted) {
      setState(() {
        _selected.clear();
        _notice = null;
      });
    }
  }

  /// Tight title: short weekday + day/month, time when known
  /// ('CS201 · Thu, 3 Sep · 10:00').
  String _sessionLabel(ClassRecord r) => sessionTightLabel(
      r.classLabel, r.dateIso, r.timestampIso);

  /// Roomy subtitle line: full weekday, date and year.
  String _sessionDateLine(ClassRecord r) =>
      sessionRoomyLine(r.dateIso, r.timestampIso);

  /// One-line partial marker on the session card (multi-round sessions
  /// only): "Partial (2)". The full per-student list lives in the session
  /// detail, where the professor can mark them present.
  String _partialLine(ClassRecord r) {
    final n = partialCountOf(r.windows, r.allEmails);
    return n == 0 ? '' : '\nPartial ($n)';
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
          builder: (_) => SessionDetailScreen(
              record: target!, courseSessions: sessions)),
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
      body: FutureBuilder<List<ClassRecord>>(
        future: store.readHistory(),
        builder: (context, snap) {
          final sessions = _sessions(snap.data ?? const <ClassRecord>[]);
          // Roster union: everyone ever seen in any session of this course.
          // Newcomers from later classes read as absent in earlier ones,
          // matching the matrix exports.
          final rosterCount = courseRoster(sessions).length;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const ClockHeader(),
              const WebRecordsBanner(),
              if (_syncing)
                const ProxLoadingRow(label: 'Syncing with cloud…')
              else if (_syncMsg != null)
                ProxSyncNote(_syncMsg!),
              const Align(
                alignment: Alignment.centerLeft,
                child: UnsyncedBadge(),
              ),
              const SizedBox(height: 8),
              // No hosting on web records builds (no BLE/HTTPS there).
              if (!kIsWeb)
                ProxPrimaryButton(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Take attendance'),
                  onPressed: _takeAttendance,
                ),
              if (!kIsWeb) const SizedBox(height: 8),
              ProxSecondaryButton(
                icon: const Icon(Icons.ios_share),
                label: const Text('Review & export'),
                onPressed: sessions.isEmpty ? null : _openExport,
                expanded: true,
              ),
              const SizedBox(height: 8),
              Text(
                '$rosterCount people · ${sessions.length} sessions',
                style: proxTabular(
                    context, Theme.of(context).textTheme.titleSmall),
              ),
              if (_selected.isNotEmpty && !kIsWeb) ...[
                const SizedBox(height: 8),
                ProxPrimaryButton(
                  icon: const Icon(Icons.delete),
                  label: Text('Delete selected (${_selected.length})'),
                  onPressed: () => _deleteSelected(sessions),
                ),
              ],
              if (_notice != null) ...[
                const SizedBox(height: 8),
                ProxErrorNote(_notice!),
              ],
              const SizedBox(height: 8),
              if (snap.connectionState == ConnectionState.waiting)
                const Center(child: CircularProgressIndicator())
              else if (sessions.isEmpty)
                const ProxEmptyState(
                  message: 'No sessions yet for this course.',
                )
              else
                // Restrained motion: stagger on load only (ProxListTile).
                for (var i = 0; i < sessions.length; i++)
                  _session(context, sessions, sessions[i], i),
              if (!kIsWeb && snap.hasData) ...[
                const SizedBox(height: 8),
                ProxSecondaryButton(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete course'),
                  onPressed: sessions.isEmpty
                      ? null
                      : () => _deleteCourse(sessions),
                  expanded: true,
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _session(
      BuildContext context, List<ClassRecord> sessions, ClassRecord r, int i) {
    final checked = _selected.contains(r.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: ProxSpacing.sm),
      child: ProxListTile(
        title: _sessionLabel(r),
        subtitle:
            '${_sessionDateLine(r)}\n${r.presentCount} present · ${r.windowCount} window${r.windowCount == 1 ? '' : 's'}${_partialLine(r)}',
        staggerIndex: i,
        // No multi-delete selection on web records builds.
        leading: kIsWeb
            ? null
            : Checkbox(
                value: checked,
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _selected.add(r.id);
                  } else {
                    _selected.remove(r.id);
                  }
                }),
              ),
        onTap: () => _openSession(sessions, r.id),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Export CSV',
              onPressed: _openExport,
            ),
            // Retake needs hosting: native only.
            if (!kIsWeb)
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Retake attendance',
                onPressed: () => _takeAttendance(autoStart: true),
              ),
          ],
        ),
      ),
    );
  }
}
