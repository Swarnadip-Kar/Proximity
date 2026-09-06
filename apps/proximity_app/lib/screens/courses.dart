// Professor main page: enlisted courses (subjects), most recent first.
// Tap a course for its sessions; register new courses by name.
// Back goes to the mode hub (never exits from here).
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_storage/storage.dart';

import '../core/auth.dart';
import '../core/cloud_sync.dart';
import '../core/device_store.dart';
import '../main.dart';
import '../mode.dart';
import '../widgets/clock.dart';
import '../widgets/web_banner.dart';
import 'course_detail.dart';

class ProfCoursesScreen extends ConsumerStatefulWidget {
  const ProfCoursesScreen({super.key});

  @override
  ConsumerState<ProfCoursesScreen> createState() => _ProfCoursesScreenState();
}

class _CourseRow {
  final String name;
  final int sessions;
  final String lastDate;
  const _CourseRow(
      {required this.name, required this.sessions, required this.lastDate});
}

class _ProfCoursesScreenState extends ConsumerState<ProfCoursesScreen> {
  final _nameCtrl = TextEditingController();
  String? _syncMsg;

  @override
  void initState() {
    super.initState();
    Future.microtask(_syncFromCloud);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  /// Pull-merge on open (first sign-in brings other devices' sessions here;
  /// later opens converge). Offline keeps local data quietly.
  Future<void> _syncFromCloud() async {
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
      final id = profPushIdentity(
          authEmail: acct?.email,
          authUid: acct?.uid,
          authName: acct?.displayName,
          role: role,
          hostNameFallback: hostName);
      if (id == null) return;
      final cloud = ref.read(cloudSyncProvider);
      if (!cloud.available) return;
      var online = false;
      try {
        online = await cloud.isOnline().timeout(const Duration(seconds: 8));
      } catch (_) {}
      if (!online) {
        if (mounted) setState(() => _syncMsg = 'Offline — this device only.');
        return;
      }
      final store = ref.read(deviceStoreProvider);
      final local = await store.readHistory();
      final remote = await cloud.pullProfSessions(id.uid);
      final merged = mergeHistories(local, remote);
      await store.writeHistory(merged);
      for (final r in merged) {
        final course = r.courseId.isNotEmpty ? r.courseId : r.classLabel;
        if (course.isNotEmpty) {
          try {
            await store.addCourse(course);
          } catch (_) {}
        }
      }
      if (mounted) setState(() => _syncMsg = 'Synced with cloud.');
    } catch (_) {}
  }

  Future<void> _register() async {
    if (!mounted) return;
    _nameCtrl.clear();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Register course'),
        content: TextField(
          controller: _nameCtrl,
          decoration: const InputDecoration(
            labelText: 'Course name',
            hintText: 'CS201',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_nameCtrl.text.trim()),
            child: const Text('Register'),
          ),
        ],
      ),
    );
    if (picked != null && picked.isNotEmpty) {
      await ref.read(deviceStoreProvider).addCourse(picked);
      if (mounted) setState(() {});
    }
  }

  Future<void> _deleteCourse(
      BuildContext context, String name, List<ClassRecord> history) async {
    final sessions = history
        .where((r) =>
            r.courseId == name || (r.courseId.isEmpty && r.classLabel == name))
        .toList();
    final stats = deletionStats(sessions);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete course $name?'),
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
    await ref.read(deviceStoreProvider).deleteCourse(name);
    // Deleting a course deletes its cloud sessions too (same professor).
    unawaited(_deleteCourseCloud(sessions.map((s) => s.id).toList()));
    if (mounted) setState(() {});
  }

  Future<void> _deleteCourseCloud(List<String> ids) async {
    if (ids.isEmpty) return;
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
      final id = profPushIdentity(
          authEmail: acct?.email,
          authUid: acct?.uid,
          authName: acct?.displayName,
          role: role,
          hostNameFallback: hostName);
      if (id == null) return;
      final cloud = ref.read(cloudSyncProvider);
      if (!cloud.available || !(await cloud.isOnline())) return;
      await cloud.deleteSessionsCloud(profUid: id.uid, ids: ids);
    } catch (_) {}
  }

  /// Tight-row label: short weekday + day/month ('Fri, 4 Sep').
  String _lastDateLabel(String lastDate) => lastDate.startsWith('no')
      ? lastDate
      : shortDayDateOf(lastDate);

  List<_CourseRow> _rows(List<Course> courses, List<ClassRecord> history) {
    final out = <_CourseRow>[];
    for (final c in courses) {
      final sessions = history
          .where((r) =>
              r.courseId == c.name ||
              (r.courseId.isEmpty && r.classLabel == c.name))
          .toList()
        ..sort((a, b) => b.dateIso.compareTo(a.dateIso));
      out.add(_CourseRow(
        name: c.name,
        sessions: sessions.length,
        lastDate: sessions.isEmpty ? 'no sessions yet' : sessions.first.dateIso,
      ));
    }
    // Most recent first; never-taken courses sink to the bottom.
    out.sort((a, b) {
      if (a.lastDate.startsWith('no') && b.lastDate.startsWith('no')) {
        return a.name.compareTo(b.name);
      }
      if (a.lastDate.startsWith('no')) return 1;
      if (b.lastDate.startsWith('no')) return -1;
      return b.lastDate.compareTo(a.lastDate);
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(deviceStoreProvider);
    final linked = ref.watch(linkedIdentityProvider);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setMode(ref, AppMode.unset);
      },
      child: AdaptiveScaffold(
        title: 'My courses',
        actions: [
          IconButton(
            icon: const Icon(Icons.switch_account),
            tooltip: 'Switch mode',
            onPressed: () => setMode(ref, AppMode.unset),
          ),
        ],
        body: FutureBuilder<List<dynamic>>(
          future:
              Future.wait([store.readCourses(), store.readHistory()]),
          builder: (context, snap) {
            final data = snap.data ?? const [];
            final courses =
                data.isEmpty ? const <Course>[] : data[0] as List<Course>;
            final history = data.length < 2
                ? const <ClassRecord>[]
                : data[1] as List<ClassRecord>;
            final rows = _rows(courses, history);
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const ClockHeader(),
                const WebRecordsBanner(),
                if (_syncMsg != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_syncMsg!,
                        style: const TextStyle(color: Colors.grey)),
                  ),
                if (linked != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        'Host: ${linked.name}${linked.roll.isNotEmpty ? ' · ${linked.roll}' : ''}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                const SizedBox(height: 8),
                // Course catalog edits are native-only (records view on web).
                if (!kIsWeb)
                  FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Register new course'),
                    onPressed: _register,
                  ),
                if (!kIsWeb) const SizedBox(height: 8),
                if (snap.connectionState == ConnectionState.waiting)
                  const Center(child: CircularProgressIndicator())
                else if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      kIsWeb
                          ? 'No synced courses yet. Courses appear here once cloud sync brings them.'
                          : 'No courses yet. Register your first course above.',
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  for (var i = 0; i < rows.length; i++)
                    AnimatedContainer(
                      duration: Duration(milliseconds: 200 + i * 40),
                      curve: Curves.easeOut,
                      child: Card(
                        child: ListTile(
                          title: Text(rows[i].name),
                          subtitle: Text(
                              '${rows[i].sessions} sessions · ${_lastDateLabel(rows[i].lastDate)}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!kIsWeb)
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: 'Delete course',
                                    onPressed: () => _deleteCourse(
                                        context, rows[i].name, history),
                                  ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(
                                  builder: (_) => CourseDetailScreen(
                                      courseName: rows[i].name)))
                              .then((_) {
                            if (mounted) setState(() {});
                          }),
                        ),
                      ),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}
