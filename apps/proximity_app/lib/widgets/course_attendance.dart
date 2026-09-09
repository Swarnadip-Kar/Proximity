// Student course attendance (modular UI): the per-course summary model,
// header, and session tile shared by MyAttendanceScreen (course cards)
// and StudentCourseScreen (sessions + totals). Pure summary math lives
// here so unit tests cover it without widgets.
library;

import 'package:flutter/material.dart';
import 'package:proximity_storage/storage.dart';

import '../design/tokens.dart';
import 'prox_cards.dart';

/// Course bucket: the renamed courseId, else the legacy class label.
/// Matches the professor's rename migration on both sides.
String courseOfRecord(ClassRecord s) =>
    s.courseId.isNotEmpty ? s.courseId : s.classLabel;

/// "2026-09-06 · 14:30" from the class-start time (snapshot time for old
/// records that predate startIso), local wall-clock, date fallback.
String sessionDateTimeLine(ClassRecord s) {
  final raw = s.startIso.isNotEmpty ? s.startIso : s.timestampIso;
  try {
    final dt = DateTime.parse(raw).toLocal();
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${s.dateIso} · $hh:$mm';
  } catch (_) {
    return s.dateIso;
  }
}

/// One session's verdict for [email]: Present / Partial p/t / Absent.
String sessionStatusOf(ClassRecord r, String email) {
  final key = email.toLowerCase();
  var present = 0;
  final total = r.windows.length;
  for (final w in r.windows) {
    if (w[key] == true) present++;
  }
  if (total == 0) return 'Absent';
  if (present == total) return 'Present';
  if (present > 0) return 'Partial $present/$total';
  return 'Absent';
}

/// Totals for one course: days taken vs attended.
class CourseAttendanceSummary {
  final String course;
  final int sessions;
  final int present;
  final int partial;
  int get absent => sessions - present - partial;
  const CourseAttendanceSummary(
      {required this.course,
      required this.sessions,
      required this.present,
      required this.partial});

  /// "6/8 days attended" — sessions stand in for days (one class visit
  /// per record; same-day repeats count separately, matching exports).
  String get line =>
      '$present/$sessions days attended${partial > 0 ? ' · $partial partial' : ''}';
}

/// Pure summary over [sessions] for [email].
CourseAttendanceSummary summarizeCourse(
    String course, List<ClassRecord> sessions, String email) {
  var present = 0;
  var partial = 0;
  for (final s in sessions) {
    final st = sessionStatusOf(s, email);
    if (st == 'Present') {
      present++;
    } else if (st.startsWith('Partial')) {
      partial++;
    }
  }
  return CourseAttendanceSummary(
      course: course,
      sessions: sessions.length,
      present: present,
      partial: partial);
}

class CourseSummaryHeader extends StatelessWidget {
  final CourseAttendanceSummary summary;
  final bool compact;
  const CourseSummaryHeader(
      {super.key, required this.summary, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return ProxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
            Text(summary.course,
                style: compact
                    ? Theme.of(context).textTheme.titleSmall
                    : Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(summary.line,
                style: Theme.of(context).textTheme.bodyMedium),
            if (!compact) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: summary.sessions == 0
                    ? 0
                    : summary.present / summary.sessions,
              ),
              const SizedBox(height: 4),
              Text(
                  '${summary.present} present · ${summary.partial} partial · ${summary.absent} absent · ${summary.sessions} days taken',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
    );
  }
}

class StudentSessionTile extends StatelessWidget {
  final ClassRecord session;
  final String email;
  final String course;
  final VoidCallback? onHide;
  const StudentSessionTile(
      {super.key,
      required this.session,
      required this.email,
      required this.course,
      this.onHide});

  @override
  Widget build(BuildContext context) {
    final status = sessionStatusOf(session, email);
    final present = status == 'Present';
    return ProxListTile(
      leading: Icon(
        present ? Icons.check_circle : Icons.circle_outlined,
        color: present
            ? ProxStateColors.of(context, ProxState.marked)
            : null,
      ),
      title: sessionDateTimeLine(session),
      // Institute org rides in the synced record already (prof org at
      // push, '' = legacy) — surfaced so same-org scope reads on the tile.
      subtitle:
          '$status · ${session.windowCount} round${session.windowCount == 1 ? '' : 's'}${session.classLabel.isNotEmpty && session.classLabel != course ? ' · ${session.classLabel}' : ''}${session.org.isNotEmpty ? ' · ${session.org}' : ''}',
      trailing: onHide == null
          ? null
          : IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove from this device',
              onPressed: onHide,
            ),
    );
  }
}
