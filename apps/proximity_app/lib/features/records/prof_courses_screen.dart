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
import '../../main.dart';
import '../../mode.dart';
import '../../widgets/clock.dart';
import '../../widgets/details_expander.dart';
import '../../widgets/log_drawer.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/sync_badge.dart';
import '../../widgets/web_banner.dart';
import 'course_overview_screen.dart';

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
  String? _syncMsg;

  @override
  void initState() {
    super.initState();
    Future.microtask(_syncFromCloud);
  }

  @override
  void dispose() {
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
                    const Center(child: CircularProgressIndicator())
                  else if (rows.isEmpty)
                    ProxEmptyState(
                      message: kIsWeb
                          ? 'No synced courses yet. Courses appear here once cloud sync brings them.'
                          : 'No courses yet. Register your first course above.',
                    )
                  else
                    for (final row in rows)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: ProxSpacing.sm),
                        child: _PickerCard(
                          title: row.name,
                          subtitle:
                              '${row.sessions} sessions · ${_lastDateLabel(row.lastDate)}',
                          onTap: () {
                            BleLog.log(
                                'NAV', 'courses → overview ${row.name}');
                            Navigator.of(context)
                                .push(MaterialPageRoute(
                                    builder: (_) => CourseOverviewScreen(
                                        courseName: row.name)))
                                .then((_) {
                              if (mounted) setState(() {});
                            });
                          },
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
  final VoidCallback onTap;
  const _PickerCard(
      {required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
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
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.accentBrand.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(ProxRadii.md),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.folder_outlined, color: c.accentBrand),
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
                      subtitle,
                      style: ProxType.caption(color: c.contentSecondary),
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
