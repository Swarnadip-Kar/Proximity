// One student's course: that course's sessions plus the totals header
// (days taken vs attended). Opened by tapping a course card on
// MyAttendanceScreen. Hiding a session removes it from THIS device only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_storage/storage.dart';

import '../main.dart';
import '../core/device_store.dart';
import '../widgets/course_attendance.dart';
import '../widgets/web_banner.dart';

class StudentCourseScreen extends ConsumerStatefulWidget {
  final String course;
  final List<ClassRecord> sessions;
  final String email;
  const StudentCourseScreen(
      {super.key,
      required this.course,
      required this.sessions,
      required this.email});

  @override
  ConsumerState<StudentCourseScreen> createState() =>
      _StudentCourseScreenState();
}

class _StudentCourseScreenState extends ConsumerState<StudentCourseScreen> {
  late List<ClassRecord> _sessions;
  var _changed = false;

  @override
  void initState() {
    super.initState();
    _sessions = List.of(widget.sessions);
  }

  Future<void> _hide(ClassRecord r) async {
    try {
      await ref.read(deviceStoreProvider).hideSession(r.id);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _sessions = _sessions.where((s) => s.id != r.id).toList();
        _changed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Removed from this device only — class data unchanged.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary =
        summarizeCourse(widget.course, _sessions, widget.email);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.of(context).pop(_changed);
      },
      child: AdaptiveScaffold(
        title: widget.course,
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const WebRecordsBanner(),
            CourseSummaryHeader(summary: summary),
            const SizedBox(height: 8),
            if (_sessions.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Text('No sessions in this course.',
                    textAlign: TextAlign.center),
              )
            else
              for (final s in _sessions)
                StudentSessionTile(
                  session: s,
                  email: widget.email,
                  course: widget.course,
                  onHide: () => _hide(s),
                ),
          ],
        ),
      ),
    );
  }
}
