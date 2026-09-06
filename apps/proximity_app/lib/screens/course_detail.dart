// One course: take attendance for a new instance on top, previous
// sessions below (most recent first), each exportable. Includes calendar
// date-range matrix export (email primary key, P/A per session) and
// multi-select session deletion with X/Y warning. Professors signed in
// sync with the cloud on open (first sign-in merges both ways; later opens
// pull); renames/deletes propagate to the cloud; CSVs share or save to
// the device.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_storage/storage.dart';
import 'package:share_plus/share_plus.dart';

import '../core/auth.dart';
import '../core/cloud_sync.dart';
import '../core/device_store.dart';
import '../core/file_saver.dart';
import '../design/tokens.dart';
import '../main.dart';
import '../widgets/clock.dart';
import '../widgets/manual_add.dart';
import '../widgets/prox_buttons.dart';
import '../widgets/prox_cards.dart';
import '../widgets/prox_states.dart';
import '../widgets/web_banner.dart';
import 'session_edit.dart';
import 'take_attendance.dart';

class CourseDetailScreen extends ConsumerStatefulWidget {
  final String courseName;
  const CourseDetailScreen({super.key, required this.courseName});

  @override
  ConsumerState<CourseDetailScreen> createState() => _CourseDetailScreenState();
}

class _CourseDetailScreenState extends ConsumerState<CourseDetailScreen> {
  final _renameCtrl = TextEditingController();
  String? _notice;
  final Set<String> _selected = {};
  String? _rangeError;
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

  /// Signed-in professor identity for cloud ops; null when offline-skipped
  /// or student (local-only — never touches the cloud).
  Future<({String uid, String email, String name})?> _profIdentity() async {
    try {
      final acct = ref.read(authServiceProvider).current;
      Map<String, String>? role;
      try {
        role = await ref.read(deviceStoreProvider).readRole();
      } catch (_) {}
      String hostName = '';
      try {
        hostName = await ref.read(deviceStoreProvider).readHostName();
      } catch (_) {}
      return profPushIdentity(
          authEmail: acct?.email,
          authUid: acct?.uid,
          authName: acct?.displayName,
          role: role,
          hostNameFallback: hostName);
    } catch (_) {
      return null;
    }
  }

  /// Pull professor sessions and merge into local history (newer timestamp
  /// wins per id). Runs on page open and after take-attendance returns.
  /// Offline/failures keep local data and report quietly.
  Future<void> _syncFromCloud() async {
    final id = await _profIdentity();
    if (id == null) return;
    final cloud = ref.read(cloudSyncProvider);
    if (!cloud.available) return;
    if (mounted) setState(() => _syncing = true);
    try {
      var online = false;
      try {
        online = await cloud.isOnline().timeout(const Duration(seconds: 8));
      } catch (_) {
        online = false;
      }
      if (!online) {
        if (mounted) {
          setState(() {
            _syncing = false;
            _syncMsg = 'Offline — showing this device only.';
          });
        }
        return;
      }
      final store = ref.read(deviceStoreProvider);
      final local = await store.readHistory();
      final remote = await cloud.pullProfSessions(id.uid);
      final merged = mergeHistories(local, remote);
      await store.writeHistory(merged);
      // Offline-queued manual adds resolve now (ID → directory → record).
      // Resolved records already exist in the cloud, so the id-diff push
      // below would skip them — push them explicitly.
      var queueNote = '';
      try {
        final q = await processPendingAdds(store: store, cloud: cloud);
        if (q.resolvedIds.isNotEmpty || q.remaining > 0) {
          final parts = <String>[];
          if (q.resolvedIds.isNotEmpty) {
            final n = q.resolvedIds.length;
            parts.add('Resolved $n queued manual add${n == 1 ? '' : 's'}');
            final fresh = await store.readHistory();
            for (final rid in q.resolvedIds) {
              for (final r in fresh) {
                if (r.id == rid) {
                  try {
                    await cloud.pushSession(
                        profUid: id.uid,
                        profEmail: id.email,
                        profName: id.name,
                        record: r);
                  } catch (_) {}
                }
              }
            }
          }
          if (q.remaining > 0) {
            parts.add(
                '${q.remaining} still queued (needs internet or a matching ID)');
          }
          queueNote = parts.join('. ');
        }
      } catch (_) {}
      // Push local-only sessions up so other devices see this visit.
      final remoteIds = {for (final r in remote) r.id};
      for (final r in local) {
        if (!remoteIds.contains(r.id)) {
          try {
            await cloud.pushSession(
                profUid: id.uid,
                profEmail: id.email,
                profName: id.name,
                record: r);
          } catch (_) {}
        }
      }
      if (mounted) {
        setState(() {
          _syncing = false;
          _syncMsg =
              'Synced with cloud.${queueNote.isEmpty ? '' : ' $queueNote'}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _syncing = false;
          _syncMsg = 'Sync failed — showing this device only.';
        });
      }
    }
  }

  /// Writes [csv] into the app documents directory (native) or downloads
  /// it (web records build) and reports the path.
  Future<void> _saveCsv(String csv, String filename) async {
    try {
      final path = await saveTextFile(filename, csv);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved to device: $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
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
    final ok = await ref
        .read(deviceStoreProvider)
        .renameCourse(widget.courseName, picked);
    if (!mounted) return;
    if (ok) {
      // Renaming migrates local history AND the cloud copies (same prof):
      // other devices pull the new name on next sync instead of keeping
      // two course spellings.
      unawaited(_renameCloud(widget.courseName, picked));
      Navigator.of(context).pop(); // back to the refreshed course list
    } else {
      setState(
          () => _notice = 'Name unchanged — empty or already used.');
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

  /// Best-effort cloud rename (professors, online). Local rename already
  /// succeeded; a cloud failure only delays other devices seeing the name.
  Future<void> _renameCloud(String oldName, String newName) async {
    try {
      final id = await _profIdentity();
      if (id == null) return;
      final cloud = ref.read(cloudSyncProvider);
      if (!cloud.available || !(await cloud.isOnline())) return;
      await cloud.renameCourseCloud(
          profUid: id.uid, oldName: oldName, newName: newName);
    } catch (_) {}
  }
  Future<void> _takeAttendance({bool autoStart = false}) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TakeAttendanceScreen(
            courseName: widget.courseName, autoStart: autoStart)));
    if (mounted) setState(() {});
    // Returning from a live session: pull cloud merges (other devices may
    // have marked meanwhile) without blocking the list.
    unawaited(_syncFromCloud());
  }

  /// Tight title: short weekday + day/month, time when known
  /// ('CS201 · Thu, 3 Sep · 10:00').
  String _sessionLabel(ClassRecord r) {
    final time = shortTimeOf(r.timestampIso);
    return '${r.classLabel} · ${shortDayDateOf(r.dateIso)}'
        '${time.isEmpty ? '' : ' · $time'}';
  }

  /// Roomy subtitle line: full weekday, date and year.
  String _sessionDateLine(ClassRecord r) {
    final time = shortTimeOf(r.timestampIso);
    return '${fullDateOf(r.dateIso)}${time.isEmpty ? '' : ' · $time'}';
  }

  Future<void> _exportRange(List<ClassRecord> sessions) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2),
      initialDateRange: DateTimeRange(
        start: now.subtract(const Duration(days: 30)),
        end: now,
      ),
    );
    if (picked == null || !mounted) return;
    String fmt(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final inRange =
        sessionsInRange(sessions, fmt(picked.start), fmt(picked.end));
    final rangeLabel =
        '${shortDayDateOf(fmt(picked.start))} … ${shortDayDateOf(fmt(picked.end))}';
    if (inRange.isEmpty) {
      setState(
          () => _rangeError = 'No classes took place in $rangeLabel.');
      return;
    }
    setState(() => _rangeError = null);
    final csv = buildDateRangeMatrix(inRange);
    if (!mounted) return;
    final fname =
        'attendance_${widget.courseName}_${fmt(picked.start)}_${fmt(picked.end)}.csv';
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${widget.courseName} · $rangeLabel'),
        content: SingleChildScrollView(child: SelectableText(csv)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.save_alt),
            label: const Text('Save to device'),
            onPressed: () => _saveCsv(csv, fname),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.ios_share),
            label: const Text('Share'),
            onPressed: () => SharePlus.instance.share(ShareParams(
              text: csv,
              subject:
                  'Attendance ${widget.courseName} ${fmt(picked.start)}-${fmt(picked.end)}',
            )),
          ),
        ],
      ),
    );
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
    await ref.read(deviceStoreProvider).deleteSessions(ids);
    // Deletes propagate to the cloud (other devices drop them on next sync).
    unawaited(_deleteCloud(ids));
    if (mounted) {
      setState(() {
        _selected.clear();
        _notice = null;
      });
    }
  }

  Future<void> _deleteCloud(List<String> ids) async {
    try {
      final id = await _profIdentity();
      if (id == null) return;
      final cloud = ref.read(cloudSyncProvider);
      if (!cloud.available || !(await cloud.isOnline())) return;
      await cloud.deleteSessionsCloud(profUid: id.uid, ids: ids);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(deviceStoreProvider);
    return AdaptiveScaffold(
      title: widget.courseName,
      actions: [
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
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const ClockHeader(),
              const WebRecordsBanner(),
              if (_syncing)
                const ProxLoadingRow(label: 'Syncing with cloud…')
              else if (_syncMsg != null)
                ProxSyncNote(_syncMsg!),
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
                icon: const Icon(Icons.calendar_month),
                label: const Text('Export date range'),
                onPressed: sessions.isEmpty
                    ? null
                    : () => _exportRange(sessions),
                expanded: true,
              ),
              if (_selected.isNotEmpty && !kIsWeb) ...[
                const SizedBox(height: 8),
                ProxPrimaryButton(
                  icon: const Icon(Icons.delete),
                  label: Text('Delete selected (${_selected.length})'),
                  onPressed: () => _deleteSelected(sessions),
                ),
              ],
              const SizedBox(height: 8),
              if (_rangeError != null) ...[
                const SizedBox(height: 8),
                ProxErrorNote(_rangeError!),
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
                for (var i = 0; i < sessions.length; i++)
                  _session(context, sessions, sessions[i], i),
            ],
          );
        },
      ),
    );
  }

    /// One-line partial marker on the session card (multi-round sessions
  /// only): "Partial (2)". The full per-student list lives on the edit
  /// page, where the professor can mark them present.
  String _partialLine(ClassRecord r) {
    if (r.windows.length <= 1) return '';
    var n = 0;
    for (final email in r.allEmails) {
      var some = false;
      var all = true;
      for (final w in r.windows) {
        if (w[email] == true) {
          some = true;
        } else {
          all = false;
        }
      }
      if (some && !all) n++;
    }
    return n == 0 ? '' : '\nPartial ($n)';
  }

  /// Opens a session in the editor: editable natively, read-only on the
  /// web records build.
  Future<void> _openSession(List<ClassRecord> sessions, String id) async {
    ClassRecord? target;
    for (final r in sessions) {
      if (r.id == id) {
        target = r;
        break;
      }
    }
    if (target == null || !mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => SessionEditScreen(
              record: target!, courseSessions: sessions, readOnly: kIsWeb)),
    );
    if (mounted) setState(() {});
  }

  Widget _session(
      BuildContext context, List<ClassRecord> sessions, ClassRecord r, int i) {
    final checked = _selected.contains(r.id);
    // Restrained motion for this data-dense view: stagger on load only.
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
        // Tap opens the record read-only on web, editable natively.
        // The full course list rides along for the absent computation.
        onTap: () => _openSession(sessions, r.id),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Export CSV',
              onPressed: () => showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text(_sessionLabel(r)),
                  content: SingleChildScrollView(
                    child: SelectableText(r.toCsv()),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Save'),
                      onPressed: () => _saveCsv(r.toCsv(),
                          'attendance_${r.classLabel}_${r.dateIso}_${r.id.substring(0, r.id.length.clamp(0, 8))}.csv'),
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.ios_share),
                      label: const Text('Share'),
                      onPressed: () => SharePlus.instance.share(ShareParams(
                        text: r.toCsv(),
                        subject:
                            'Attendance ${r.classLabel} ${r.dateIso}',
                      )),
                    ),
                  ],
                ),
              ),
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
