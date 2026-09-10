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
import '../../design/app_theme.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/course_attendance.dart';
import '../../widgets/log_drawer.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/student_card.dart';
import '../../widgets/verdict_badge.dart';
import '../../widgets/web_banner.dart';

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

  ProxStatus _statusFor(String status) {
    if (status == 'Present') return ProxStatus.marked;
    if (status.startsWith('Partial')) return ProxStatus.review;
    return ProxStatus.waiting;
  }

  List<RoundTick> _trailFor(ClassRecord session) => [
        for (var i = 0; i < session.windows.length; i++)
          RoundTick('R${i + 1}',
              present: session.windows[i][widget.email] == true),
      ];

  /// Tile subtitle, same fields as the shared session tile minus the status
  /// (the `VerdictBadge` already carries the exact `sessionStatusOf` word —
  /// repeating it here rendered `Partial p/t` twice per tile).
  /// Rounds · label · org.
  String _tileSubtitle(ClassRecord session) {
    final org = session.org.isNotEmpty ? ' · ${session.org}' : '';
    final label =
        session.classLabel.isNotEmpty && session.classLabel != widget.course
            ? ' · ${session.classLabel}'
            : '';
    return '${session.windowCount} round${session.windowCount == 1 ? '' : 's'}$label$org';
  }

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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Semantics(
                      label: summary.line,
                      child: SizedBox(
                        width: 64,
                        height: 64,
                        child: CircularProgressIndicator(
                          value: value,
                          strokeWidth: 6,
                          strokeCap: StrokeCap.round,
                          backgroundColor: c.divider,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              c.accentBrand),
                        ),
                      ),
                    ),
                    const SizedBox(width: ProxSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            summary.line,
                            style: ProxType.title(color: c.contentPrimary),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${summary.present} present · ${summary.partial} partial · ${summary.absent} absent · ${summary.sessions} days taken',
                            style: proxTabular(context,
                                ProxType.caption(color: c.contentSecondary)),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                          ),
                        ],
                      ),
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
                    child: Row(
                      key: ValueKey<String>('session-${session.id}'),
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: StudentCard(
                            name: sessionDateTimeLine(session),
                            subtitle: _tileSubtitle(session),
                            status: VerdictBadge(
                              status: _statusFor(sessionStatusOf(
                                  session, widget.email)),
                              label: sessionStatusOf(
                                  session, widget.email),
                            ),
                            roundTrail: _trailFor(session),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Remove from this device',
                          onPressed: () => _hide(session),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
