// Student attendance records: classes synced online by professors,
// cached on this device. Read-only view of cloud sessions containing
// this Gmail; "delete" hides the entry on THIS device only
// (professor/cloud data untouched).
//
// Course-wise in both places: the cloud docs carry courseId/courseName
// (professor renames bump timestampIso so merges adopt them), the device
// cache is the last pull verbatim, and this screen groups by course with
// the class start time on every row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_storage/storage.dart';

import '../main.dart';
import '../core/auth.dart';
import '../core/cloud_sync.dart';
import '../core/device_store.dart';
import '../widgets/clock.dart';
import '../widgets/course_attendance.dart';
import '../widgets/web_banner.dart';
import 'student_course.dart';

class MyAttendanceScreen extends ConsumerStatefulWidget {
  const MyAttendanceScreen({super.key});

  @override
  ConsumerState<MyAttendanceScreen> createState() => _MyAttendanceScreenState();
}

class _MyAttendanceScreenState extends ConsumerState<MyAttendanceScreen> {
  bool _loading = true;
  bool _online = false;
  String _error = '';
  String _offlineNote = '';
  List<ClassRecord> _sessions = [];
  Set<String> _hidden = {};

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
      _offlineNote = '';
    });
    try {
      final acct = ref.read(authServiceProvider).current ??
          await ref.read(accountProvider.future);
      if (acct == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'Sign in to view your synced attendance.';
          });
        }
        return;
      }
      final cloud = ref.read(cloudSyncProvider);
      final store = ref.read(deviceStoreProvider);
      _hidden = await store.readHiddenSessions();
      final email = acct.email.toLowerCase();
      var online = false;
      try {
        online = await cloud.isOnline().timeout(const Duration(seconds: 8));
      } catch (_) {
        online = false;
      }
      if (!online) {
        // Offline: the last synced device copy, not a dead end. Renames
        // and fresh pushes converge here on the next online pull.
        List<ClassRecord> cached = const [];
        try {
          cached = await store.readStudentSessions();
        } catch (_) {}
        final visible =
            cached.where((s) => !_hidden.contains(s.id)).toList();
        if (mounted) {
          setState(() {
            _loading = false;
            _online = false;
            _sessions = visible;
            _error = visible.isEmpty
                ? 'You appear offline — connect to load synced records.'
                : '';
            _offlineNote = visible.isEmpty
                ? ''
                : 'Offline — showing last synced records.';
          });
        }
        return;
      }
      final sessions = await cloud.pullStudentSessions(email);
      // Device copy: same docs, same order (newest first). Professor
      // attendance pushes and course renames land here on every pull.
      try {
        await store.writeStudentSessions(sessions);
      } catch (_) {}
      final visible =
          sessions.where((s) => !_hidden.contains(s.id)).toList();
      if (mounted) {
        setState(() {
          _loading = false;
          _online = true;
          _sessions = visible;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e'.replaceFirst('StateError: ', '');
        });
      }
    }
  }

  Future<void> _openCourse(String course, List<ClassRecord> sessions,
      String email) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => StudentCourseScreen(
              course: course, sessions: sessions, email: email)),
    );
    // A hide inside the detail reloads this list on return.
    if (changed == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final acct = ref.watch(accountProvider).valueOrNull;
    final email = acct?.email.toLowerCase() ?? '';
    // Course-wise: buckets A–Z, sessions newest-first inside each (the
    // pull/cache order is newest-first; grouping is stable).
    final groups = <String, List<ClassRecord>>{};
    for (final s in _sessions) {
      groups.putIfAbsent(courseOfRecord(s), () => []).add(s);
    }
    final courses = groups.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final summaries = {
      for (final c in courses) c: summarizeCourse(c, groups[c]!, email)
    };
    final totalTaken = _sessions.length;
    final totalAttended =
        summaries.values.fold(0, (n, s) => n + s.present);
    return AdaptiveScaffold(
      title: 'My attendance',
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const ClockHeader(),
            const WebRecordsBanner(),
            if (acct != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(acct.email,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            const SizedBox(height: 8),
            if (_offlineNote.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(_offlineNote,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey)),
              ),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_error.isNotEmpty)
              Text(_error,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))
            else if (_sessions.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Text(
                  'No synced classes yet. Professors sync after marking — pull down to refresh when online.',
                  textAlign: TextAlign.center,
                ),
              )
            else ...[
              Text('$totalAttended present · $totalTaken synced sessions',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              // First page is courses: tap one for its sessions + totals.
              for (final c in courses)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(c),
                    subtitle:
                        Text(summaries[c]!.line),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                            '${summaries[c]!.present}/${summaries[c]!.sessions}',
                            style: Theme.of(context).textTheme.titleSmall),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    onTap: acct == null
                        ? null
                        : () => _openCourse(c, groups[c]!, email),
                  ),
                ),
            ],
            if (_online)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Synced from your professors. Removing hides it here only.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
