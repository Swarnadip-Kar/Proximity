// Professor course picker: the "manage courses" half of the old course page.
//
// Lists registered courses (most recent first) with session counts, registers
// new ones, and pull-merges cloud sessions on open so other devices' visits
// converge here. Per-course work (sessions, rename/delete, export) lives in
// CourseOverviewScreen — this screen only picks or creates. Records-only:
// registration stays here because the Live tab root is register-free by
// design (it only opens existing courses); this tab never routes into room
// capture and shows no status chip for it.
//
// Data logic preserved per the Phase-1 exemption (rows, sort, register,
// sync): restyle only. No PopScope in this tab (navigation-shell rebuild):
// the shell owns back; the explicit Switch-mode button below is untouched.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

import '../../core/device_store.dart';
import '../../core/sync_hook.dart';
import '../../design/tokens.dart';
import '../live/live_refresh.dart';
import '../../main.dart';
import '../../mode.dart';
import '../../widgets/clock.dart';
import '../../widgets/details_expander.dart';
import '../../widgets/log_drawer.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_shimmer.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/student_card.dart' show CourseLogo;
import '../../widgets/sync_badge.dart';
import '../../widgets/web_banner.dart';
import 'course_overview_screen.dart';

class ProfCoursesScreen extends ConsumerStatefulWidget {
  const ProfCoursesScreen({super.key});

  /// Canonical tab-root route name: `prof/courses`.
  /// Matches the IA node (`ProxRoutes.profCourses` in `routes.dart`; the
  /// value is duplicated here as a literal — importing the table would
  /// cycle back into this screen). This root itself is built by the shell
  /// tab navigator at `/`; the name documents the ONE IA identity so NAV
  /// logs, `popUntil` by name/prefix, and deep-links agree with the
  /// in-tab pushes below (no duplicate unnamed push).
  static const String routeName = 'prof/courses';

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

  /// History-refresh trigger (post-End freshness, presentation/navigation
  /// only). Root cause: this state lives inside the shell IndexedStack +
  /// per-tab Navigator, which caches its route — tab switches never
  /// rebuild it, so the `FutureBuilder` futures below never re-read and
  /// the Courses tab serves its pre-End snapshot (new session missing
  /// without an app restart). The take host bumps [liveHistoryTick] when
  /// its visit writes history or exits (End/stop/decisions/adds/leave);
  /// this listener `setState`s, which re-creates the inline futures so the
  /// next read is fresh — even while offstage, so the data is current
  /// before the tab is shown. Data/filter/sort logic untouched.
  VoidCallback? _historyTickListener;

  @override
  void initState() {
    super.initState();
    Future.microtask(_syncFromCloud);
    _historyTickListener = () {
      if (mounted) setState(() {});
    };
    liveHistoryTick.addListener(_historyTickListener!);
  }

  @override
  void dispose() {
    if (_historyTickListener != null) {
      liveHistoryTick.removeListener(_historyTickListener!);
    }
    _nameCtrl.dispose();
    super.dispose();
  }

  /// Pull-merge on open through the SyncEngine (single-flight flush:
  /// outbox pushes + pull-union converge). Offline keeps local data
  /// quietly; the unsynced badge shows what is still queued.
  Future<void> _syncFromCloud() async {
    final res = await flushNow(ref);
    if (!mounted) return;
    if (!res.online) {
      setState(() => _syncMsg = 'Offline — this device only.');
      return;
    }
    setState(() => _syncMsg = res.remaining > 0
        ? 'Synced with cloud (${res.remaining} still pending).'
        : 'Synced with cloud.');
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
      BleLog.log('NAV', 'courses: registered $picked');
      if (mounted) setState(() {});
    }
  }

  void _openLog() {
    BleLog.log('NAV', 'courses → system log');
    showLogDrawer(context);
  }

  /// Tight-row label: short weekday + day/month ('Fri, 4 Sep').
  String _lastDateLabel(String lastDate) => lastDateLabel(lastDate);

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
    final c = ProximityColors.of(context);
    final store = ref.watch(deviceStoreProvider);
    final linked = ref.watch(linkedIdentityProvider);
    return AdaptiveScaffold(
      title: 'My courses',
      actions: [
        IconButton(
          icon: const Icon(Icons.terminal_outlined),
          tooltip: 'System log',
          onPressed: _openLog,
        ),
        IconButton(
          icon: const Icon(Icons.switch_account),
          tooltip: 'Switch mode',
          onPressed: () => setMode(ref, AppMode.unset),
        ),
      ],
      body: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: ProxSpacing.maxContentWidth),
          child: FutureBuilder<List<dynamic>>(
            future: Future.wait([store.readCourses(), store.readHistory()]),
            builder: (context, snap) {
              final data = snap.data ?? const [];
              final courses =
                  data.isEmpty ? const <Course>[] : data[0] as List<Course>;
              final history = data.length < 2
                  ? const <ClassRecord>[]
                  : data[1] as List<ClassRecord>;
              final rows = _rows(courses, history);
              return ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: ProxSpacing.screenMargin,
                  vertical: ProxSpacing.lg,
                ),
                children: [
                  const ClockHeader(),
                  const WebRecordsBanner(),
                  if (_syncMsg != null) ProxSyncNote(_syncMsg!),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: UnsyncedBadge(),
                  ),
                  if (linked != null)
                    Padding(
                      padding: const EdgeInsets.only(top: ProxSpacing.xs),
                      child: Text(
                        'Host: ${linked.name}${linked.roll.isNotEmpty ? ' · ${linked.roll}' : ''}',
                        style: ProxType.caption(color: c.contentSecondary),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  const SizedBox(height: ProxSpacing.sm),
                  // Course catalog edits are native-only (records view on web).
                  if (!kIsWeb)
                    ProxPrimaryButton(
                      icon: const Icon(Icons.add),
                      label: const Text('Register new course'),
                      onPressed: _register,
                    ),
                  if (!kIsWeb) const SizedBox(height: ProxSpacing.sm),
                  if (snap.connectionState == ConnectionState.waiting)
                    const ProxShimmerHost(
                      child: Column(
                        children: [
                          ProxShimmerCard(lines: 2),
                          SizedBox(height: ProxSpacing.sm),
                          ProxShimmerCard(lines: 2),
                          SizedBox(height: ProxSpacing.sm),
                          ProxShimmerCard(lines: 2),
                        ],
                      ),
                    )
                  else if (rows.isEmpty)
                    ProxEmptyState(
                      message: kIsWeb
                          ? 'No synced courses yet. Courses appear here once cloud sync brings them.'
                          : 'No courses yet. Register your first course to start taking attendance.',
                      // Sub-action CTA: same sheet as the button above.
                      actionLabel: kIsWeb ? null : 'Register course',
                      onAction: kIsWeb ? null : _register,
                    )
                  else
                    // Staggered entrance: each card fades/slides in 40ms
                    // apart (capped), giving the catalog a settled landing.
                    for (var i = 0; i < rows.length; i++)
                      ProxFadeSlideIn(
                        delay: Duration(
                          milliseconds: (i *
                                  ProxDurations.staggerStep.inMilliseconds)
                              .clamp(
                                  0,
                                  ProxDurations
                                      .staggerCap.inMilliseconds),
                        ),
                        child: Padding(
                          padding:
                              const EdgeInsets.only(bottom: ProxSpacing.sm),
                          child: _PickerCard(
                            title: rows[i].name,
                            subtitle:
                                '${rows[i].sessions} sessions · ${_lastDateLabel(rows[i].lastDate)}',
                            sessionCount: rows[i].sessions,
                            onTap: () {
                              BleLog.log(
                                  'NAV', 'courses → overview ${rows[i].name}');
                              Navigator.of(context)
                                  .push(MaterialPageRoute(
                                      settings: RouteSettings(
                                          name: CourseOverviewScreen.routeName(
                                              rows[i].name)),
                                      builder: (_) => CourseOverviewScreen(
                                          courseName: rows[i].name)))
                                  .then((_) {
                                if (mounted) setState(() {});
                              });
                            },
                          ),
                        ),
                      ),
                  DetailsExpander(
                    title: 'Details',
                    child: Text(
                      'Pull-merge converges other devices on open. Newest writes win per session.',
                      style: ProxType.caption(color: c.contentSecondary),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PickerCard extends StatelessWidget {
  final String title;
  final String subtitle;

  /// Session count rendered as a trailing donut badge.
  final int sessionCount;
  final VoidCallback onTap;
  const _PickerCard(
      {required this.title,
      required this.subtitle,
      this.sessionCount = 0,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    // Shared card shell (hover lift, gradient fill) + course logo disc —
    // the same disc language as student avatars, replacing the one-off
    // folder icon.
    return ProxCard(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CourseLogo(course: title),
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
                  subtitle,
                  style: ProxType.caption(color: c.contentSecondary),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: ProxSpacing.sm),
          // Session-count donut: ring + count, brand-tinted.
          _SessionDonut(count: sessionCount),
          const SizedBox(width: ProxSpacing.xs),
          Icon(Icons.chevron_right, color: c.contentTertiary),
        ],
      ),
    );
  }
}

/// Trailing session-count donut: 40dp ring in brand tint with the count
/// centered. Pure count display (no fraction implied).
class _SessionDonut extends StatelessWidget {
  final int count;
  const _SessionDonut({required this.count});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              value: 1.0,
              strokeWidth: 3,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation<Color>(
                c.accentBrand.withValues(alpha: 0.22),
              ),
            ),
          ),
          Text(
            '$count',
            style: ProxType.label(color: c.accentBrand).copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
