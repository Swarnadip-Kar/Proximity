// One student's course: that course's sessions plus the totals header
// (days taken vs attended). Opened by tapping a course card on
// MyAttendanceScreen. Hiding a session removes it from THIS device only
// (professor/cloud data untouched).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

import '../../core/device_store.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/course_attendance.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/web_banner.dart';
import '../debug/debug_log_screen.dart';

class CourseAttendanceDetailScreen extends ConsumerStatefulWidget {
  final String course;
  final List<ClassRecord> sessions;
  final String email;
  const CourseAttendanceDetailScreen(
      {super.key,
      required this.course,
      required this.sessions,
      required this.email});

  @override
  ConsumerState<CourseAttendanceDetailScreen> createState() =>
      _CourseAttendanceDetailScreenState();
}

class _CourseAttendanceDetailScreenState
    extends ConsumerState<CourseAttendanceDetailScreen> {
  late List<ClassRecord> _sessions;
  var _changed = false;

  @override
  void initState() {
    super.initState();
    _sessions = List.of(widget.sessions);
  }

  /// Device-only hide: the professor's record and the cloud copy stay
  /// untouched; only this device stops showing the session.
  Future<void> _hide(ClassRecord r) async {
    try {
      await ref.read(deviceStoreProvider).hideSession(r.id);
    } catch (_) {}
    BleLog.log('NAV', 'course ${widget.course}: hid ${r.dateIso} (device only)');
    if (mounted) {
      setState(() {
        _sessions = _sessions.where((s) => s.id != r.id).toList();
        _changed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Removed from this device only — class data unchanged.')));
    }
  }

  void _openLog() {
    BleLog.log('NAV', 'course ${widget.course} → system log');
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DebugLogScreen()));
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
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal_outlined),
            tooltip: 'System log',
            onPressed: _openLog,
          ),
        ],
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const WebRecordsBanner(),
            CourseSummaryHeader(summary: summary),
            const SizedBox(height: 8),
            if (_sessions.isEmpty)
              const ProxEmptyState(
                message: 'No sessions in this course.',
              )
            else
              // Restrained motion: stagger on load only, keyed by session
              // so hiding one never replays the rest.
              for (var i = 0; i < _sessions.length; i++)
                ProxFadeSlideIn(
                  key: ValueKey<String>('session-${_sessions[i].id}'),
                  delay: Duration(
                      milliseconds: (i *
                              ProxDurations.staggerStep.inMilliseconds)
                          .clamp(0,
                              ProxDurations.staggerCap.inMilliseconds)),
                  child: StudentSessionTile(
                    session: _sessions[i],
                    email: widget.email,
                    course: widget.course,
                    onHide: () => _hide(_sessions[i]),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
