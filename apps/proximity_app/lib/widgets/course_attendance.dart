// Student course attendance (modular UI): the per-course summary model,
// header, and session tile shared by MyAttendanceScreen (course cards)
// and StudentCourseScreen (sessions + totals). Pure summary math lives
// here so unit tests cover it without widgets.
library;

import 'package:flutter/material.dart';
import 'package:proximity_storage/storage.dart';

import '../design/tokens.dart';
import 'student_card.dart';
import 'verdict_badge.dart';

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

/// First-line date for a student session tile: the frozen
/// [sessionDateTimeLine] string, with the DAY/date restored when the synced
/// record carries none.
///
/// `dateIso` to `''`, in which case the frozen helper yields `' · HH:MM'`
/// (TIME with no DAY) or `''` (empty line) — the reported day-missing shape.
/// This restores the day from the same start/timestamp the helper itself
/// uses for the time, in the identical `'yyyy-MM-dd · HH:MM'` shape; when
/// nothing parses, the session's own `classLabel` (then `id`, which the
/// constructor always generates) keeps the prominent line non-empty. No
/// invented copy — every fallback is a field already on the record.
String studentSessionDateLine(ClassRecord session) {
  if (session.dateIso.isNotEmpty) return sessionDateTimeLine(session);
  final raw =
      session.startIso.isNotEmpty ? session.startIso : session.timestampIso;
  try {
    final dt = DateTime.parse(raw).toLocal();
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d · $hh:$mm';
  } catch (_) {}
  if (session.classLabel.isNotEmpty) return session.classLabel;
  return session.id;
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

/// Secondary line for a student session tile: rounds · label · org.
///
/// Status rides the [VerdictBadge] (exact `sessionStatusOf` word), never
/// duplicated here — same split as the course-detail tile (FIX 2 dedupe).
/// Institute org rides in the synced record already (prof org at push,
/// '' = legacy) — surfaced so same-org scope reads on the tile.
String studentSessionSecondary(ClassRecord session, String course) {
  final label =
      session.classLabel.isNotEmpty && session.classLabel != course
          ? ' · ${session.classLabel}'
          : '';
  final org = session.org.isNotEmpty ? ' · ${session.org}' : '';
  return '${session.windowCount} round${session.windowCount == 1 ? '' : 's'}$label$org';
}

ProxStatus _statusKindFor(String status) {
  if (status == 'Present') return ProxStatus.marked;
  if (status.startsWith('Partial')) return ProxStatus.review;
  return ProxStatus.waiting;
}

class StudentSessionTile extends StatelessWidget {
  final ClassRecord session;
  final String email;
  final String course;
  final VoidCallback? onHide;

  /// Round-trail chips (detail screen passes its `_trailFor`; standalone
  /// uses stay empty). Same [RoundTick] shape as `StudentCard`.
  final List<RoundTick> roundTrail;
  const StudentSessionTile(
      {super.key,
      required this.session,
      required this.email,
      required this.course,
      this.onHide,
      this.roundTrail = const []});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final status = sessionStatusOf(session, email);
    final present = status == 'Present';
    // date (`studentSessionDateLine` — the frozen `sessionDateTimeLine`
    // string with the DAY restored when a synced record carries no dateIso,
    // so TIME-with-no-DAY never renders) is its own prominent first line and
    // NEVER ellipsizes — it wraps (softWrap + visible overflow, no fixed
    // height) so the full date stays readable at 360dp + 130% type.
    // §10.1: ellipsis lives only on the non-date secondary line below.
    return Container(
      constraints: const BoxConstraints(minHeight: ProxSpacing.minTap),
      padding: EdgeInsets.all(ProxLayout.cardPadding(context)),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: ProxRadii.cardSpecRadius,
        border: Border.all(color: c.divider),
        boxShadow: [c.elevationRaised],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            present ? Icons.check_circle : Icons.circle_outlined,
            color: present
                ? ProxStateColors.of(context, ProxState.marked)
                : c.contentTertiary,
          ),
          const SizedBox(width: ProxSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  studentSessionDateLine(session),
                  style: ProxType.body(color: c.contentPrimary),
                  softWrap: true,
                  maxLines: 3,
                  overflow: TextOverflow.visible,
                ),
                const SizedBox(height: ProxSpacing.xs),
                // Status badge on its own line (never shares a Row with
                // the secondary text): at 360dp + 130% type the badge's
                // intrinsic width plus a side-by-side text overflows the
                // column, while stacked both fit with room to spare.
                VerdictBadge(
                  status: _statusKindFor(status),
                  label: status,
                ),
                const SizedBox(height: ProxSpacing.xs),
                Text(
                  studentSessionSecondary(session, course),
                  style: ProxType.caption(color: c.contentSecondary),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
                if (roundTrail.isNotEmpty) ...[
                  const SizedBox(height: ProxSpacing.xs),
                  Wrap(
                    spacing: ProxSpacing.sm,
                    runSpacing: ProxSpacing.xs,
                    children: [
                      for (final tick in roundTrail)
                        _SessionRoundChip(tick: tick),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (onHide != null) ...[
            const SizedBox(width: ProxSpacing.sm),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove from this device',
              onPressed: onHide,
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionRoundChip extends StatelessWidget {
  final RoundTick tick;
  const _SessionRoundChip({required this.tick});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final color = tick.present ? c.statusMarked : c.contentSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ProxSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ProxRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        '${tick.label} ${tick.present ? '✓' : '✗'}',
        style: ProxType.caption(color: color),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
