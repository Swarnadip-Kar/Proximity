// Records date + refresh fixes (tester-verified, presentation/read-path only).
//
// FIX 1 — day missing: cloud docs read via `docToRecord` default a missing
//   `dateIso` to `''`, in which case the FROZEN `sessionDateTimeLine` yields
//   `' · HH:MM'` (TIME with no DAY) or `''` (empty line). The helper is
//   untouched (pinned below); the composition `studentSessionDateLine`
//   restores the day from the same start/timestamp in the identical shape,
//   and the tile renders it as the prominent never-ellipsized first line.
// FIX 2 — late refresh: `MyAttendanceScreen._load` awaited the 8s online
//   probe BEFORE pulling, then pulled unbounded, then awaited the cache
//   write before `setState`. The deliberate-refresh path (`_refresh`, wired
//   to the RefreshIndicator) pulls bounded (10s, like the Firestore query)
//   with no probe gate and applies the UI before the cache write. Offline
//   honesty copy + last-sync semantics unchanged; no polling; engine
//   untouched (this screen never references it — pull is direct).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/records/course_attendance_detail_screen.dart';
import 'package:proximity_app/features/records/my_attendance_screen.dart';
import 'package:proximity_app/widgets/course_attendance.dart';
import 'package:proximity_storage/storage.dart';

const _email = 'student@example.com';

/// Fresh-cloud fixture: production saves always stamp org, so pushed
/// records carry it (no silent server/fake fallback stamps org-less rows).
ClassRecord _rec(String id, String course, String date, String stamp) =>
    ClassRecord(
      id: id,
      courseId: course,
      classLabel: course,
      dateIso: date,
      timestampIso: stamp,
      startIso: stamp,
      windows: [
        {_email: true}
      ],
      names: const {_email: 'Student One'},
      rolls: const {_email: '10000001'},
      org: 'example.com',
    );

/// Cloud-originated edge shape: `docToRecord` defaults a missing dateIso to
/// `''` while the timestamps survive (old/hand-written docs).
ClassRecord _datelessRec(String id, String stamp) => ClassRecord(
      id: id,
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '',
      timestampIso: stamp,
      startIso: stamp,
      windows: [
        {_email: true}
      ],
      names: const {_email: 'Student One'},
      rolls: const {_email: '10000001'},
    );

/// Probe that never answers: proves refresh never gates on it (any
/// probe-gated path hangs here forever; the fixed path completes).
class _HangingProbeCloud extends FakeCloudSync {
  @override
  Future<bool> isOnline() => Completer<bool>().future;
}

/// Production-faithful offline pull: the real query throws past the cache
/// (rules/transport), surfacing the honest cached copy — never an empty
/// "success".
class _OfflinePullCloud extends FakeCloudSync {
  _OfflinePullCloud() : super(online: false);
  @override
  Future<List<ClassRecord>> pullStudentSessions(String emailLower,
      {String org = ''}) async {
    throw StateError('You appear offline — connect to the internet.');
  }
}

ProviderScope _wrap(
        {required InMemoryDeviceStore store,
        required FakeCloudSync cloud,
        required Widget home}) =>
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
            email: _email, displayName: 'Student One', uid: 'u1'))),
        cloudSyncProvider.overrideWithValue(cloud),
        deviceStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(theme: proxLightTheme(), home: home),
    );

Widget _scaled(Widget body, {double scale = 1.3}) => MaterialApp(
      theme: proxLightTheme(),
      builder: (context, c) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
        ),
        child: c!,
      ),
      home: Scaffold(body: body),
    );

void _narrow(WidgetTester t) {
  t.view.physicalSize = const Size(360, 700);
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
}

/// Expected derived line, computed the same local-wall-clock way the
/// composition does (TZ-agnostic: never hard-codes the UTC calendar day).
/// Global rule: `[Day], DD-MM-YYYY · HH:MM`.
String _expectedDerived(String stamp) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final dt = DateTime.parse(stamp).toLocal();
  String p(int v, [int w = 2]) => '$v'.padLeft(w, '0');
  return '${days[dt.weekday - 1]}, ${p(dt.day)}-${p(dt.month)}-${p(dt.year, 4)} · ${p(dt.hour)}:${p(dt.minute)}';
}

void main() {
  // ---- FIX 1: frozen helper untouched, composition restores the day ----
  test('frozen sessionDateTimeLine still yields TIME-with-no-DAY for dateIso ""',
      () {
    final s = _datelessRec('edge-1', '2026-09-06T14:30:00.000Z');
    // Root-cause pin: the helper itself is NOT fixed (frozen) — it returns
    // the day-missing shape the testers reported.
    expect(sessionDateTimeLine(s).startsWith(' · '), isTrue);
  });

  test('studentSessionDateLine is verbatim when dateIso is present', () {
    final s = _rec('s1', 'CS201', '2026-09-06', '2026-09-06T14:30:00.000Z');
    expect(studentSessionDateLine(s), sessionDateTimeLine(s));
    // Day + time both present (global `[Day], DD-MM-YYYY` date; the clock
    // part is local wall-clock).
    expect(studentSessionDateLine(s).contains('06-09-2026'), isTrue);
    expect(studentSessionDateLine(s).contains(' · '), isTrue);
  });

  test('studentSessionDateLine restores day from startIso when dateIso ""',
      () {
    const stamp = '2026-09-06T14:30:00.000Z';
    final s = _datelessRec('edge-1', stamp);
    final line = studentSessionDateLine(s);
    expect(line, _expectedDerived(stamp));
    expect(line.startsWith(' · '), isFalse);
    expect(line.contains(' · '), isTrue);
  });

  test('studentSessionDateLine falls back to timestampIso when startIso ""',
      () {
    final s = ClassRecord(
      id: 'edge-2',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '',
      timestampIso: '2026-09-05T09:15:00.000Z',
      startIso: '',
      windows: [
        {_email: true}
      ],
    );
    // Constructor defaults startIso to timestampIso when empty.
    expect(studentSessionDateLine(s),
        _expectedDerived('2026-09-05T09:15:00.000Z'));
  });

  test('studentSessionDateLine never renders an empty prominent line', () {
    final s = ClassRecord(
      id: 'edge-3',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '',
      timestampIso: '',
      startIso: '',
      windows: [
        {_email: true}
      ],
    );
    // Nothing parses ('T00:00:00.000Z' defaults) → own label, never ''.
    expect(studentSessionDateLine(s), 'CS201');
    expect(studentSessionDateLine(s).isNotEmpty, isTrue);
  });

  testWidgets('tile: derived day prominent at 360dp + 130%, never ellipsis',
      (t) async {
    _narrow(t);
    const stamp = '2026-09-06T14:30:00.000Z';
    final s = _datelessRec('edge-1', stamp);
    final line = studentSessionDateLine(s);
    expect(line, _expectedDerived(stamp));
    await t.pumpWidget(ProviderScope(child: _scaled(
      StudentSessionTile(session: s, email: _email, course: 'CS201'),
    )));
    await t.pumpAndSettle();
    expect(find.text(line), findsOneWidget);
    final dateText = t.widget<Text>(find.text(line));
    expect(dateText.overflow, isNot(TextOverflow.ellipsis));
    expect(dateText.softWrap, isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('detail: dateless session still shows its day', (t) async {
    _narrow(t);
    const stamp = '2026-09-06T14:30:00.000Z';
    final s = _datelessRec('edge-1', stamp);
    await t.pumpWidget(ProviderScope(child: _scaled(
      CourseAttendanceDetailScreen(
          course: 'CS201', sessions: [s], email: _email),
    )));
    await t.pumpAndSettle();
    expect(find.text(_expectedDerived(stamp)), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  // ---- FIX 2: refresh re-reads cloud promptly ----
  testWidgets('refresh completes while the online probe hangs', (t) async {
    final store = InMemoryDeviceStore();
    final cloud = _HangingProbeCloud();
    await cloud.pushSession(
      profUid: 'p1',
      profEmail: 'prof@example.com',
      profName: 'Prof',
      record: _rec('s1', 'CS201', '2026-09-04', '2026-09-04T10:00:00.000Z'),
    );
    await t.pumpWidget(
        _wrap(store: store, cloud: cloud, home: const MyAttendanceScreen()));
    await t.pump();
    // Init load is probe-gated (still spinning) — the deliberate refresh is
    // not: it pulls straight through and the UI reflects it on completion.
    // `show()` needs pumped frames for its dismiss animation, so it must
    // not be awaited directly (deadlock); the settle below drives it.
    unawaited(t
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await t.pumpAndSettle();
    expect(find.text('CS201'), findsOneWidget);
    expect(find.text('1 present · 1 synced sessions'), findsOneWidget);
    // Device copy still converges after the visible update.
    await t.pump(const Duration(milliseconds: 100));
    expect(await store.readStudentSessions(), hasLength(1));
    // Let the init load's 8s probe timeout fire (consumes its timer for a
    // clean teardown): the stale init must NOT clobber the fresher UI.
    await t.pump(const Duration(seconds: 9));
    expect(find.text('CS201'), findsOneWidget);
    expect(find.text('1 present · 1 synced sessions'), findsOneWidget);
    expect(find.text('Offline — showing last synced records.'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('refresh picks up a newly synced course', (t) async {
    final store = InMemoryDeviceStore();
    final cloud = FakeCloudSync();
    await cloud.pushSession(
      profUid: 'p1',
      profEmail: 'prof@example.com',
      profName: 'Prof',
      record: _rec('s1', 'CS201', '2026-09-04', '2026-09-04T10:00:00.000Z'),
    );
    await t.pumpWidget(
        _wrap(store: store, cloud: cloud, home: const MyAttendanceScreen()));
    await t.pumpAndSettle();
    expect(find.text('CS201'), findsOneWidget);
    expect(find.text('CS202'), findsNothing);
    await cloud.pushSession(
      profUid: 'p1',
      profEmail: 'prof@example.com',
      profName: 'Prof',
      record: _rec('s2', 'CS202', '2026-09-05', '2026-09-05T10:00:00.000Z'),
    );
    unawaited(t
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await t.pumpAndSettle();
    expect(find.text('CS201'), findsOneWidget);
    expect(find.text('CS202'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('failed refresh keeps the honest offline copy', (t) async {
    final store = InMemoryDeviceStore();
    await store.writeStudentSessions([
      _rec('s1', 'CS201', '2026-09-04', '2026-09-04T10:00:00.000Z'),
    ]);
    await t.pumpWidget(_wrap(
        store: store,
        cloud: _OfflinePullCloud(),
        home: const MyAttendanceScreen()));
    await t.pumpAndSettle();
    // Init probe already shows the cached copy with the honesty note.
    expect(find.text('Offline — showing last synced records.'), findsOneWidget);
    expect(find.text('CS201'), findsOneWidget);
    // A deliberate refresh under the same outage preserves both.
    unawaited(t
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await t.pumpAndSettle();
    expect(find.text('Offline — showing last synced records.'), findsOneWidget);
    expect(find.text('CS201'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('failed refresh with empty cache keeps the connect copy',
      (t) async {
    final store = InMemoryDeviceStore();
    await t.pumpWidget(_wrap(
        store: store,
        cloud: _OfflinePullCloud(),
        home: const MyAttendanceScreen()));
    await t.pumpAndSettle();
    expect(find.text('You appear offline — connect to load synced records.'),
        findsOneWidget);
    unawaited(t
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await t.pumpAndSettle();
    expect(find.text('You appear offline — connect to load synced records.'),
        findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
