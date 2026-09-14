// One student's course: that course's sessions plus the totals header
// (days taken vs attended, progress ring). Opened by tapping a course card
// on MyAttendanceScreen. Hiding a session removes it from THIS device only
// (professor/cloud data untouched). Records-only: no marking entry here.
//
// Data logic preserved per the Phase-1 exemption (summary, hide): restyle
// only. No PopScope in this tab (navigation-shell rebuild): plain back
// returns null and the parent always refreshes on return.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

import '../../core/device_store.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/course_attendance.dart';
import '../../widgets/log_drawer.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/student_card.dart';
import '../../widgets/verdict_badge.dart';
import '../../widgets/web_banner.dart';
import 'session_row_card.dart';

class CourseAttendanceDetailScreen extends ConsumerStatefulWidget {
  final String course;
  final List<ClassRecord> sessions;
  final String email;

  /// Cached professor Gmail photo for this course (seen live on this
  /// device, '' = never seen). Photo first, course-letter disc fallback —
  /// the same avatar contract as the course cards.
  final String profPhotoUrl;
  const CourseAttendanceDetailScreen(
      {super.key,
      required this.course,
      required this.sessions,
      required this.email,
      this.profPhotoUrl = ''});

  /// Canonical in-tab route name: `records/mine/<course>`.
  /// Documented equivalent (deep-link table only has the `records/mine`
  /// root; in-tab pushes resolve record objects directly, so this stays
  /// in-tab-only). ONE identity for NAV logs and `popUntil` by name/prefix
  /// (no duplicate unnamed push).
  static String routeName(String course) => 'records/mine/$course';

  @override
  ConsumerState<CourseAttendanceDetailScreen> createState() =>
      _CourseAttendanceDetailScreenState();
}

class _CourseAttendanceDetailScreenState
    extends ConsumerState<CourseAttendanceDetailScreen> {
  late List<ClassRecord> _sessions;

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
    BleLog.log(
        'NAV', 'course ${widget.course}: hid ${r.dateIso} (device only)');
    if (mounted) {
      setState(() {
        _sessions = _sessions.where((s) => s.id != r.id).toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Removed from this device only — class data unchanged.')));
    }
  }

  void _openLog() {
    BleLog.log('NAV', 'course ${widget.course} → system log');
    showLogDrawer(context);
  }

  List<RoundTick> _trailFor(ClassRecord session) => [
        for (var i = 0; i < session.windows.length; i++)
          RoundTick('R${i + 1}',
              present: session.windows[i][widget.email] == true),
      ];

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final summary = summarizeCourse(widget.course, _sessions, widget.email);
    final value = summary.sessions == 0
        ? 0.0
        : (summary.present / summary.sessions).clamp(0.0, 1.0);
    return AdaptiveScaffold(
      title: widget.course,
      actions: [
        IconButton(
          icon: const Icon(Icons.terminal_outlined),
          tooltip: 'System log',
          onPressed: _openLog,
        ),
      ],
      body: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: ProxSpacing.maxContentWidth),
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: ProxSpacing.screenMargin,
              vertical: ProxSpacing.lg,
            ),
            children: [
              const WebRecordsBanner(),
              Container(
                padding:
                    const EdgeInsets.all(ProxSpacing.cardPadding),
                decoration: BoxDecoration(
                  color: c.surfaceRaised,
                  borderRadius: ProxRadii.cardSpecRadius,
                  border: Border.all(color: c.divider),
                  boxShadow: [c.elevationRaised],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Semantics(
                          label: summary.line,
                          // Same widget as the course-list cards (copy-paste
                          // parity by construction — one assembly, never drift).
                          child: AttendanceRingAvatar(
                            photoUrl: widget.profPhotoUrl,
                            course: widget.course,
                            value: value,
                          ),
                        ),
                        const SizedBox(width: ProxSpacing.lg),
                        Expanded(
                          child: Text(
                            summary.line,
                            style: ProxType.title(color: c.contentPrimary),
                            softWrap: true,
                            overflow: TextOverflow.visible,
                            maxLines: 2,
                          ),
                        ),
                      ],
                    ),
                    // Same Present/Partial/Absent badges + tri-color share
                    // bar as the prof live header (exact same widgets —
                    // VerdictBadge trio + SessionShareBar, day counts).
                    const SizedBox(height: ProxSpacing.sm),
                    Row(
                      children: [
                        _StudentSummaryCell(VerdictBadge(
                          status: ProxStatus.marked,
                          label: 'Present ${summary.present}',
                        )),
                        const SizedBox(width: ProxSpacing.xs),
                        _StudentSummaryCell(VerdictBadge(
                          status: ProxStatus.late,
                          label: 'Partial ${summary.partial}',
                        )),
                        const SizedBox(width: ProxSpacing.xs),
                        _StudentSummaryCell(VerdictBadge(
                          status: ProxStatus.absent,
                          label: 'Absent ${summary.absent}',
                        )),
                      ],
                    ),
                    const SizedBox(height: ProxSpacing.sm),
                    SessionShareBar(
                      present: summary.present,
                      partial: summary.partial,
                      absent: summary.absent,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: ProxSpacing.sm),
              if (_sessions.isEmpty)
                const ProxEmptyState(
                  message: 'No sessions in this course.',
                )
              else
                for (final session in _sessions)
                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: ProxSpacing.sm),
                    // Date-visibility layout lives in the shared
                    // `StudentSessionTile`: frozen `sessionDateTimeLine`
                    // date on its own wrapping line (never ellipsized),
                    // status badge + rounds/label/org secondary below.
                    // Same fields as before, better hierarchy.
                    child: StudentSessionTile(
                      key: ValueKey<String>('session-${session.id}'),
                      session: session,
                      email: widget.email,
                      course: widget.course,
                      roundTrail: _trailFor(session),
                      onHide: () => _hide(session),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One badge cell: equal third of the row, scales down instead of
/// wrapping — the trio always fits one line (same contract as the prof
/// live `_AttendanceSummary` cell + the session-card counts row).
class _StudentSummaryCell extends StatelessWidget {
  final VerdictBadge badge;
  const _StudentSummaryCell(this.badge);

  @override
  Widget build(BuildContext context) => Expanded(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          child: badge,
        ),
      );
}

/// Data limit (same as the cards): past-course records carry no photo, so
/// a course never joined live on this device always renders the letter
/// disc; the photo converges via the live gated /window unicast cached
/// per course. The header renders [AttendanceRingAvatar] — the same
/// assembly as the course-list cards.

