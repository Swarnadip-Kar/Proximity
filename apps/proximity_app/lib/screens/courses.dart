// Professor main page: enlisted courses (subjects), most recent first.
// Tap a course for its sessions; register new courses by name.
// Back goes to the mode hub (never exits from here).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_storage/storage.dart';

import '../core/device_store.dart';
import '../main.dart';
import '../mode.dart';
import '../widgets/clock.dart';
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

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
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
                if (linked != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        'Host: ${linked.name}${linked.roll.isNotEmpty ? ' · ${linked.roll}' : ''}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Register new course'),
                  onPressed: _register,
                ),
                const SizedBox(height: 8),
                if (snap.connectionState == ConnectionState.waiting)
                  const Center(child: CircularProgressIndicator())
                else if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      'No courses yet. Register your first course above.',
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
                              '${rows[i].sessions} sessions · ${rows[i].lastDate}'),
                          trailing: const Icon(Icons.chevron_right),
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
