// Student records landing: synced courses as progress-ring cards, tap one
// for its sessions. Read-only: hiding removes the entry on THIS device only
// (professor/cloud data untouched). Records-only: no marking entry here.
//
// Data logic preserved per the Phase-1 exemption (load, cache, grouping,
// totals): restyle only.
library;

import 'dart:async';

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
import '../../widgets/prox_shimmer.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/student_card.dart' show AttendanceRingAvatar;
import '../../widgets/web_banner.dart';
import 'course_attendance_detail_screen.dart';

class MyAttendanceScreen extends ConsumerStatefulWidget {
  const MyAttendanceScreen({super.key});

  /// Canonical tab-root route name: `records/mine`.
  /// Matches the IA node (`ProxRoutes.myAttendance` in `routes.dart`; the
  /// value is duplicated here as a literal — importing the table would
  /// cycle back into this screen). This root itself is built by the shell
  /// tab navigator at `/`; the name documents the ONE IA identity so NAV
  /// logs, `popUntil` by name/prefix, and deep-links agree with the
  /// in-tab push below (no duplicate unnamed push).
  static const String routeName = 'records/mine';

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

  /// Cached professor Gmail photos per course (student-side device cache,
  /// saved on gated /window convergence). ''/absent = no photo seen yet
  /// → no badge. The waiting room always prefers the live poll value.
  Map<String, String> _profPhotos = {};

  /// Loads cached prof photos for the visible courses (best-effort, after
  /// the list is already up — never blocks the refresh itself).
  Future<void> _loadProfPhotos() async {
    final courses = {
      for (final s in _sessions) courseOfRecord(s),
    }.toList();
    if (courses.isEmpty) return;
    late final DeviceStore store;
    try {
      store = ref.read(deviceStoreProvider);
    } catch (_) {
      return;
    }
    final map = Map<String, String>.from(_profPhotos);
    var changed = false;
    for (final c in courses) {
      try {
        final url = (await store.readCourseProfPhoto(c)).trim();
        if (url.isNotEmpty && map[c] != url) {
          map[c] = url;
          changed = true;
        }
      } catch (_) {}
    }
    if (changed && mounted) setState(() => _profPhotos = map);
  }

  /// Last-started load wins: a stale init finishing AFTER a deliberate
  /// refresh (e.g. its 8s probe timing out late) must not clobber the
  /// fresher UI — completion paths check their generation and drop.
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _error = '';
      _offlineNote = '';
    });
    try {
      final acct = ref.read(authServiceProvider).current ??
          await ref.read(accountProvider.future);
      if (!mounted || gen != _gen) return;
      if (acct == null) {
        if (mounted && gen == _gen) {
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
      if (!mounted || gen != _gen) return;
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
        await _showCachedOffline(store, 'offline', gen);
        return;
      }
      // Identity org wins, else the Gmail domain ([orgOf]).
      final myOrg = acct.org.isNotEmpty ? acct.org : orgOf(email);
      List<ClassRecord> sessions;
      try {
        // Bounded like the Firestore query itself (10s): an unbounded pull
        // held the refresh spinner indefinitely on a dropped radio.
        sessions = await cloud
            .pullStudentSessions(email, org: myOrg)
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        // Probe passed but the pull itself failed (radio dropped between
        // the two): the same honest cached copy as the offline branch,
        // never raw transport text.
        await _showCachedOffline(store, 'pull failed', gen);
        return;
      }
      _applyPulled(sessions, gen);
      await _writeCache(store, sessions);
    } catch (e) {
      if (mounted && gen == _gen) {
        setState(() {
          _loading = false;
          _error = '$e'.replaceFirst('StateError: ', '');
        });
      }
    }
  }

  /// Deliberate pull-to-refresh (RefreshIndicator): re-reads cloud promptly
  /// without gating on the 8s online probe first — the probe is what stalled
  /// the drag (up to 8s of spinner before the pull even started, then an
  /// unbounded pull, then a cache write before the visible update). Same
  /// pull/filter/order/cache/honesty-copy as [_load]: no new polling, no
  /// engine call (student mode pulls directly; the engine flush is the
  /// professor push path and was verified uninvolved here — this screen
  /// never references it). The stale list stays visible under the indicator
  /// (no `_loading` swap); the UI reflects the re-read on completion.
  Future<void> _refresh() async {
    final gen = ++_gen;
    try {
      final acct = ref.read(authServiceProvider).current ??
          await ref.read(accountProvider.future);
      if (!mounted || gen != _gen) return;
      if (acct == null) {
        if (mounted && gen == _gen) {
          setState(() {
            _loading = false;
            _error = 'Sign in to view your synced attendance.';
          });
        }
        return;
      }
      final cloud = ref.read(cloudSyncProvider);
      final store = ref.read(deviceStoreProvider);
      try {
        _hidden = await store.readHiddenSessions();
      } catch (_) {}
      final email = acct.email.toLowerCase();
      final myOrg = acct.org.isNotEmpty ? acct.org : orgOf(email);
      try {
        final sessions = await cloud
            .pullStudentSessions(email, org: myOrg)
            .timeout(const Duration(seconds: 10));
        _applyPulled(sessions, gen);
        // Cache trails the visible update (see [_applyPulled]).
        unawaited(_writeCache(store, sessions));
      } catch (_) {
        await _showCachedOffline(store, 'refresh offline', gen);
      }
    } catch (e) {
      if (mounted && gen == _gen) {
        setState(() {
          _loading = false;
          _error = '$e'.replaceFirst('StateError: ', '');
        });
      }
    }
  }

  /// Online pull applied to the VISIBLE list first: the refresh indicator
  /// and the list reflect the re-read on completion. Also clears stale
  /// offline state (the init path used to rely on its entry `_loading`
  /// reset; refresh keeps the list up so it must clear here). Same docs,
  /// same newest-first order, same hidden filter as before. Drops silently
  /// when a newer load started after ([_gen]).
  void _applyPulled(List<ClassRecord> sessions, int gen) {
    if (!mounted || gen != _gen) return;
    final visible =
        sessions.where((s) => !_hidden.contains(s.id)).toList();
    BleLog.log(
        'SYNC', 'my-attendance: pulled ${sessions.length} sessions');
    setState(() {
      _loading = false;
      _online = true;
      _error = '';
      _offlineNote = '';
      _sessions = visible;
    });
    unawaited(_loadProfPhotos());
  }

  /// Device-copy write, best-effort AFTER the visible update (it used to be
  /// awaited before `setState`, so a slow cache write held the refresh
  /// hostage). Professor pushes and renames still land in the device copy
  /// on every pull — ordering only, same content.
  Future<void> _writeCache(
      DeviceStore store, List<ClassRecord> sessions) async {
    try {
      await store.writeStudentSessions(sessions);
    } catch (_) {}
  }

  /// Last-synced device copy with the honest offline strings, shared by the
  /// Drops silently when a newer load started after ([_gen]).
  Future<void> _showCachedOffline(
      DeviceStore store, String why, int gen) async {
    if (gen != _gen) return;
    List<ClassRecord> cached = const [];
    try {
      cached = await store.readStudentSessions();
    } catch (_) {}
    if (!mounted || gen != _gen) return;
    final visible =
        cached.where((s) => !_hidden.contains(s.id)).toList();
    BleLog.log(
        'SYNC', 'my-attendance: $why, ${visible.length} cached sessions');
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
    unawaited(_loadProfPhotos());
  }

  Future<void> _openCourse(String course, List<ClassRecord> sessions,
      String email) async {
    BleLog.log('NAV', 'my-attendance → $course');
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          settings: RouteSettings(
              name: CourseAttendanceDetailScreen.routeName(course)),
          builder: (_) => CourseAttendanceDetailScreen(
              course: course,
              sessions: sessions,
              email: email,
              // Cached prof photo seen live ('' = never seen → the
              // letter-disc fallback inside the detail header).
              profPhotoUrl: _profPhotos[course] ?? '')),
    );
    // Back yields no value (no PopScope anywhere in this tab): always
    // refresh so a hide inside the detail is reflected here on return.
    // Mechanical orchestration note for the final summary: previously
    // reloaded only when the detail returned true.
    if (mounted) _load();
  }

  /// Device-only course removal: hides every session of [course] on THIS
  /// device (the same [hideSession] filter as the per-session hide in the
  /// detail screen). No history delete, no tombstone, no cloud push —
  /// professor/cloud data untouched; the next pull re-fetches but the
  /// hidden filter keeps the course hidden.
  Future<void> _deleteCourse(String course) async {
    final ids = _sessions
        .where((s) => courseOfRecord(s) == course)
        .map((s) => s.id)
        .toList();
    if (ids.isEmpty || !mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $course from this device?'),
        content: Text(
            'This removes ${ids.length} session${ids.length == 1 ? '' : 's'} from this list only. Class data stays unchanged.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      final store = ref.read(deviceStoreProvider);
      for (final id in ids) {
        try {
          await store.hideSession(id);
        } catch (_) {}
      }
    } catch (_) {}
    if (!mounted) return;
    _hidden.addAll(ids);
    if (!mounted) return;
    setState(() {
      _sessions = _sessions.where((s) => !ids.contains(s.id)).toList();
      _profPhotos = Map.of(_profPhotos)..remove(course);
    });
    BleLog.log('NAV', 'my-attendance: removed $course (device only)');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Removed $course from this device only — class data unchanged.')));
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
            onRefresh: _refresh,
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
                  const ProxShimmerHost(
                    child: Column(
                      children: [
                        ProxShimmerRow(),
                        SizedBox(height: ProxSpacing.sm),
                        ProxShimmerRow(),
                        SizedBox(height: ProxSpacing.sm),
                        ProxShimmerRow(),
                      ],
                    ),
                  )
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
                      // Stable per-course key: deleting a course must drop
                      // ITS element (in-flight photo load, progress state),
                      // never shift a neighbour's element up by position.
                      key: ValueKey('course-$course'),
                      padding:
                          const EdgeInsets.only(bottom: ProxSpacing.sm),
                      child: _CourseCard(
                        title: course,
                        summary: summaries[course]!,
                        // Cached prof photo ('' = never seen → no badge).
                        profPhotoUrl: _profPhotos[course] ?? '',
                        onTap: acct == null
                            ? null
                            : () => _openCourse(
                                course, groups[course]!, email),
                        onDelete: () => _deleteCourse(course),
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
/// [profPhotoUrl] fills the ring center with the professor's cached Gmail
/// photo ('' = never seen live on this device → the course-letter disc;
/// see [AttendanceRingAvatar] for the data limit).
/// [onDelete] removes the whole course on THIS device only (confirm +
/// device-only snackbar in the owner); null hides the affordance.
class _CourseCard extends StatelessWidget {
  final String title;
  final CourseAttendanceSummary summary;
  final String profPhotoUrl;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  const _CourseCard(
      {required this.title,
      required this.summary,
      this.profPhotoUrl = '',
      this.onTap,
      this.onDelete});

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
                // Shared ring + face assembly (see AttendanceRingAvatar):
                // the detail header renders this same widget.
                child: AttendanceRingAvatar(
                  photoUrl: profPhotoUrl,
                  course: title,
                  value: value,
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
              if (onDelete != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove course from this device',
                  onPressed: onDelete,
                ),
              Icon(Icons.chevron_right, color: c.contentTertiary),
            ],
          ),
        ),
      ),
    );
  }
}
