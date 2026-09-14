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

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:archive/archive.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/auth.dart';
import '../../core/device_store.dart';
import '../../core/file_saver.dart';
import '../../core/sync_hook.dart';
import '../../design/tokens.dart';
import '../account/account_common.dart';
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
import 'export_center_screen.dart' show exportHeader;

/// Per-course entry name inside the export-all zip: same convention as
/// the per-course exports (`attendance_<course>_all.csv`).
String exportAllEntryName(String course) => 'attendance_${course}_all.csv';

/// Fleet zip name: `<profEmail>_Attendance_record_<yyyymmddTHHMMSSZ>`.
/// Pure (timestamp injected) so tests pin it without clocks.
String exportAllZipName(String profEmail, DateTime nowUtc) {
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${nowUtc.year}${two(nowUtc.month)}${two(nowUtc.day)}T${two(nowUtc.hour)}${two(nowUtc.minute)}${two(nowUtc.second)}Z';
  return '${profEmail}_Attendance_record_$stamp.zip';
}

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
  bool _syncing = false;
  Future<void> _syncFromCloud() async {
    if (_syncing) return;
    if (mounted) setState(() => _syncing = true);
    try {
      final res = await flushNow(ref);
      if (!mounted) return;
      if (!res.online) {
        setState(() => _syncMsg = 'Offline — this device only.');
        return;
      }
      setState(() {
        _syncMsg = res.remaining > 0
            ? 'Synced with cloud (${res.remaining} still pending).'
            : 'Synced with cloud.';
        // History may have converged (adoptions, pulls, tombstones) — the
        // inline futures below re-read on setState, even while offstage.
      });
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
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
      if (!mounted) return;
      await ref.read(deviceStoreProvider).addCourse(picked);
      BleLog.log('NAV', 'courses: registered $picked');
      if (mounted) setState(() {});
    }
  }

  /// Exports every course with sessions: one matrix CSV per course
  /// (same [buildDateRangeMatrix] + [exportHeader] bytes as the
  /// per-course flows), zipped into a single archive — one file per
  /// course, properly named like the per-course exports. A Close/Save/
  /// Share dialog (same contract as the single-course preview) confirms
  /// before anything leaves the device. Courses without sessions are
  /// skipped.
  Future<void> _exportAll(
      List<_CourseRow> rows, List<ClassRecord> history) async {
    final acct = ref.read(accountProvider).valueOrNull;
    final profName = (acct?.displayName ?? '').trim();
    final profEmail = (acct?.email ?? '').trim();
    final archive = Archive();
    var count = 0;
    for (final row in rows) {
      final sessions = history
          .where((r) =>
              r.courseId == row.name ||
              (r.courseId.isEmpty && r.classLabel == row.name))
          .toList()
        ..sort((a, b) => b.timestampIso.compareTo(a.timestampIso));
      if (sessions.isEmpty) continue;
      final csv = exportHeader(
        buildDateRangeMatrix(sessions),
        profName: profName,
        className: row.name,
        profEmail: profEmail,
      );
      final entryName = exportAllEntryName(row.name);
      archive.addFile(ArchiveFile(
          entryName, utf8.encode(csv).length, utf8.encode(csv)));
      count++;
    }
    if (count == 0 || !mounted) return;
    final zipName = exportAllZipName(profEmail, DateTime.now().toUtc());
    final zipBytes = ZipEncoder().encode(archive);
    // Captured pre-dialog: async Save/SnackBar must not reach across
    // gaps via State.context.
    final messenger = ScaffoldMessenger.of(context);
    BleLog.log('NAV', 'courses → export all ($count courses → $zipName)');
    if (!mounted) return;
    final lines = <String>[
      for (final f in archive.files) '• ${f.name}',
    ];
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Export All Data'),
        content: SingleChildScrollView(
          child: SelectableText(
              '$count course${count == 1 ? '' : 's'} · one file each:\n${lines.join('\n')}'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
          SizedBox(
            width: double.infinity,
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Save'),
                    onPressed: () async {
                      Navigator.of(dialogContext).pop();
                      try {
                        final path =
                            await saveBytesFile(zipName, zipBytes);
                        messenger.showSnackBar(SnackBar(
                            content: Text('Saved to device: $path')));
                      } catch (e) {
                        messenger.showSnackBar(
                            SnackBar(content: Text('Save failed: $e')));
                      }
                    },
                  ),
                ),
                const SizedBox(width: ProxSpacing.sm),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share'),
                    onPressed: () async {
                      Navigator.of(dialogContext).pop();
                      await SharePlus.instance.share(
                        ShareParams(
                          files: [
                            XFile.fromData(
                              Uint8List.fromList(zipBytes),
                              name: zipName,
                              mimeType: 'application/zip',
                            ),
                          ],
                          subject: 'Attendance — all courses',
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
          onPressed: () {
            // Stale-stack reset first (same as the student Mark tab):
            // dismiss the root setup-flow + pop the tab to root before
            // the switch so the previous identity's screens never survive
            // underneath.
            prepareAccountTransition(context);
            if (!mounted) return;
            unawaited(setMode(ref, AppMode.unset));
          },
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
              final courses = data.isNotEmpty && data[0] is List<Course>
                  ? data[0] as List<Course>
                  : const <Course>[];
              final history = data.length >= 2 && data[1] is List<ClassRecord>
                  ? data[1] as List<ClassRecord>
                  : const <ClassRecord>[];
              final rows = _rows(courses, history);
              // Floating Export docked above the shell nav bar (same
              // chrome + placement as Review & export on the course
              // page). List bottom padding keeps the last card clear.
              return Stack(
                children: [
                  ListView(
                    padding: const EdgeInsets.fromLTRB(
                      ProxSpacing.screenMargin,
                      ProxSpacing.lg,
                      ProxSpacing.screenMargin,
                      104,
                    ),
                    children: [
                      const ClockHeader(),
                      const WebRecordsBanner(),
                      if (_syncing)
                        const ProxLoadingRow(label: 'Syncing with cloud…')
                      else if (_syncMsg != null)
                        ProxSyncNote(_syncMsg!),
                      Row(
                        children: [
                          const Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: UnsyncedBadge(),
                            ),
                          ),
                          ProxSecondaryButton(
                            icon: const Icon(Icons.sync, size: 18),
                            label: const Text('Sync now'),
                            onPressed:
                                _syncing ? null : () => _syncFromCloud(),
                          ),
                        ],
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
                                  .clamp(0,
                                      ProxDurations.staggerCap.inMilliseconds),
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
                                  BleLog.log('NAV',
                                      'courses → overview ${rows[i].name}');
                                  Navigator.of(context)
                                      .push(MaterialPageRoute(
                                          settings: RouteSettings(
                                              name: CourseOverviewScreen
                                                  .routeName(rows[i].name)),
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
                  ),
                  if (rows.isNotEmpty)
                    Positioned(
                      left: ProxSpacing.lg,
                      right: ProxSpacing.lg,
                      bottom: ProxSpacing.sm,
                      child: SafeArea(
                        top: false,
                        child: ProxFloatingAction(
                          child: ProxPrimaryButton(
                            icon: const Icon(Icons.ios_share),
                            label: const Text('Export All Data'),
                            onPressed: rows.any((r) => r.sessions > 0)
                                ? () => _exportAll(rows, history)
                                : null,
                            expanded: true,
                            compact: true,
                          ),
                        ),
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
