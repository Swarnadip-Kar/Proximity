// Student records landing: synced courses as progress-ring cards, tap one
// for its sessions. Read-only: hiding removes the entry on THIS device only
// (professor/cloud data untouched). Records-only: no marking entry here.
//
// Data logic preserved per the Phase-1 exemption (load, cache, grouping,
// totals): restyle only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../design/app_theme.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/clock.dart';
import '../../widgets/course_attendance.dart';
import '../../widgets/details_expander.dart';
import '../../widgets/log_drawer.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/web_banner.dart';
import 'course_attendance_detail_screen.dart';

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
        BleLog.log('SYNC',
            'my-attendance: offline, ${visible.length} cached sessions');
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
      // Identity org wins, else the Gmail domain ([orgOf]).
      final myOrg = acct.org.isNotEmpty ? acct.org : orgOf(email);
      final sessions = await cloud.pullStudentSessions(email, org: myOrg);
      // Device copy: same docs, same order (newest first). Professor
      // attendance pushes and course renames land here on every pull.
      try {
        await store.writeStudentSessions(sessions);
      } catch (_) {}
      final visible =
          sessions.where((s) => !_hidden.contains(s.id)).toList();
      BleLog.log(
          'SYNC', 'my-attendance: pulled ${sessions.length} sessions');
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
    BleLog.log('NAV', 'my-attendance → $course');
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => CourseAttendanceDetailScreen(
              course: course, sessions: sessions, email: email)),
    );
    // Back yields no value (no PopScope anywhere in this tab): always
    // refresh so a hide inside the detail is reflected here on return.
    // Mechanical orchestration note for the final summary: previously
    // reloaded only when the detail returned true.
    if (mounted) _load();
  }

  void _openLog() {
    BleLog.log('NAV', 'my-attendance → system log');
    showLogDrawer(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
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
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(
                horizontal: ProxSpacing.screenMargin,
                vertical: ProxSpacing.lg,
              ),
              children: [
                const ClockHeader(),
                const WebRecordsBanner(),
                if (acct != null)
                  Padding(
                    padding: const EdgeInsets.only(top: ProxSpacing.xs),
                    child: Text(
                      acct.email,
                      style: ProxType.caption(color: c.contentSecondary),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                const SizedBox(height: ProxSpacing.sm),
                if (_offlineNote.isNotEmpty) ProxSyncNote(_offlineNote),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_error.isNotEmpty)
                  ProxErrorNote(_error)
                else if (_sessions.isEmpty)
                  const ProxEmptyState(
                    message:
                        'No synced classes yet. Professors sync after marking — pull down to refresh when online.',
                  )
                else ...[
                  Text('$totalAttended present · $totalTaken synced sessions',
                      style: proxTabular(
                          context, ProxType.label(color: c.contentPrimary))),
                  const SizedBox(height: ProxSpacing.sm),
                  // One card per course: progress ring as the primary
                  // visual, the x/y fraction line as the caption beneath.
                  for (final course in courses)
                    Padding(
                      padding:
                          const EdgeInsets.only(bottom: ProxSpacing.sm),
                      child: _CourseCard(
                        title: course,
                        summary: summaries[course]!,
                        onTap: acct == null
                            ? null
                            : () => _openCourse(
                                course, groups[course]!, email),
                      ),
                    ),
                ],
                if (_online)
                  const ProxSyncNote(
                    'Synced from your professors. Removing hides it here only.',
                  ),
                DetailsExpander(
                  title: 'Details',
                  child: Text(
                    'Synced sessions stay cached on this device. Counts converge on the next pull. Removing hides entries here only.',
                    style: ProxType.caption(color: c.contentSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Course card: progress ring (primary) + fraction line caption.
class _CourseCard extends StatelessWidget {
  final String title;
  final CourseAttendanceSummary summary;
  final VoidCallback? onTap;
  const _CourseCard(
      {required this.title, required this.summary, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final value = summary.sessions == 0
        ? 0.0
        : (summary.present / summary.sessions).clamp(0.0, 1.0);
    return Container(
      constraints: const BoxConstraints(minHeight: ProxSpacing.minTap),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: ProxRadii.cardSpecRadius,
        border: Border.all(color: c.divider),
        boxShadow: [c.elevationRaised],
      ),
      child: InkWell(
        borderRadius: ProxRadii.cardSpecRadius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(ProxSpacing.cardPadding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Semantics(
                label: summary.line,
                child: SizedBox(
                  width: ProxSpacing.minTap,
                  height: ProxSpacing.minTap,
                  child: CircularProgressIndicator(
                    value: value,
                    strokeWidth: 5,
                    strokeCap: StrokeCap.round,
                    backgroundColor: c.divider,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(c.accentBrand),
                  ),
                ),
              ),
              const SizedBox(width: ProxSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: ProxType.body(color: c.contentPrimary),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      summary.line,
                      style:
                          ProxType.caption(color: c.contentSecondary),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: ProxSpacing.sm),
              Icon(Icons.chevron_right, color: c.contentTertiary),
            ],
          ),
        ),
      ),
    );
  }
}
