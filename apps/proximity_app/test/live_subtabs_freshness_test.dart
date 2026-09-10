// Live subtabs + freshness (tester-verified Live-tab defects).
//
// 1. Real sub-tabs: the Live sub-nav (Roster/Inbox/Add/Setup,
//    product-owner order) SWAPS content via an IndexedStack — each sub-tab
//    shows ONLY its view, no shared scroll, no intersection; inactive views
//    stay mounted so state survives switches (incl. mid-approve inbox
//    selection — the reverted grouping probe broke exactly this by
//    unmounting).
// 2. Date visibility: the session date/day is a proper visible header
//    element (same frozen `fullDateOf(todayIso())` helper/format) in both
//    IDLE and LIVE states.
// 3. Post-End freshness: after End attendance, the Courses tab shows the
//    new session without an app restart (the `liveHistoryTick` reload
//    trigger re-reads the IndexedStack-kept records screens on re-show).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/ble_radio.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/live/live_refresh.dart';
import 'package:proximity_app/features/live/live_session.dart';
import 'package:proximity_app/features/records/course_overview_screen.dart';
import 'package:proximity_app/features/records/prof_courses_screen.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_app/screens/take_attendance.dart';
import 'package:proximity_app/widgets/clock.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

Widget _themed(Widget body) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: body),
    );

ProviderScope _scoped(Widget home,
        {InMemoryDeviceStore? store,
        FakeHostDriver? host,
        FakeCloudSync? cloud}) =>
    ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(store ?? InMemoryDeviceStore()),
        hostDriverProvider.overrideWithValue(host ?? FakeHostDriver()),
        cloudSyncProvider
            .overrideWithValue(cloud ?? FakeCloudSync(online: false)),
        studentDriverProvider.overrideWithValue(FakeStudentDriver()),
        bleEngineProvider
            .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        cameraPermissionProvider.overrideWithValue(() async => true),
        btPowerProvider.overrideWithValue(() async => BtState.on),
      ],
      child: MaterialApp(theme: proxLightTheme(), home: home),
    );

Future<FakeHostDriver> _seededDriver() async {
  final driver = FakeHostDriver();
  await driver.startHosting(classLabel: 'CS201');
  driver.tally.noteWindow(1);
  driver.tally.noteWindow(2);
  driver.tally.mark('a@univ.edu', 'A', 1, roll: '1');
  driver.tally.mark('a@univ.edu', 'A', 2, roll: '1');
  driver.tally.mark('b@univ.edu', 'B', 1, roll: '2');
  await driver.addManualEntry(email: 'w@univ.edu', name: 'W', roll: '3');
  driver.seedDupGroup('a@univ.edu', ['b@univ.edu']);
  driver.seedManual(const [
    ManualRow(email: 'm@univ.edu', name: 'M One', roll: '9'),
    ManualRow(email: 'n@univ.edu', name: 'N Two', roll: '10'),
  ]);
  return driver;
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _openTab(WidgetTester t, String label) async {
  final labelInBar = find.descendant(
    of: find.byType(BottomNavigationBar),
    matching: find.text(label),
  );
  expect(labelInBar, findsOneWidget, reason: 'tab $label exists in bar');
  await t.tap(labelInBar);
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

ClassRecord _record(String id, String dateIso) => ClassRecord(
      id: id,
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: dateIso,
      timestampIso: '${dateIso}T10:00:00.000Z',
      startIso: '${dateIso}T10:00:00.000Z',
      w1: const {'a@x.in': true},
      names: const {'a@x.in': 'A'},
      rolls: const {'a@x.in': '1'},
    );

void main() {
  testWidgets('sub-tabs swap: each shows ONLY its view, no shared content',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    final host = await _seededDriver();
    await t.pumpWidget(_scoped(const TakeAttendanceScreen(courseName: 'CS201'),
        store: store, host: host));
    await t.pumpAndSettle();

    // One state-preserving switch, one scroll per tab (no shared scroll):
    // all four tab scrolls stay mounted (4 with offstage included) while
    // only the active tab's scroll is visible (1 with the default
    // offstage-skipping finder). Which tab is visible is asserted per-tab
    // below.
    expect(find.byType(IndexedStack), findsOneWidget);
    expect(
      find.byType(SingleChildScrollView, skipOffstage: false),
      findsNWidgets(4),
    );
    expect(find.byType(SingleChildScrollView), findsOneWidget);

    // Default = Roster (product-owner order, index 0): roster-only.
    expect(find.textContaining('Waiting area (1)'), findsOneWidget);
    expect(find.byKey(const ValueKey('prof-search')), findsOneWidget);
    expect(find.textContaining('Manual requests'), findsNothing);
    expect(find.text('Direct manual entry'), findsNothing);
    expect(
        find.widgetWithText(
            TextField, 'Your name (optional, shown to students)'),
        findsNothing);

    // Inbox: requests only, no roster/add/setup.
    await t.tap(find.text('Inbox (2)'));
    await t.pumpAndSettle();
    expect(find.text('Manual requests (2)'), findsOneWidget);
    expect(find.text('M One'), findsOneWidget);
    expect(find.textContaining('Waiting area'), findsNothing);
    expect(find.textContaining('Present — all rounds'), findsNothing);
    expect(find.text('Direct manual entry'), findsNothing);
    expect(find.byKey(const ValueKey('prof-search')), findsNothing);
    expect(
        find.widgetWithText(
            TextField, 'Your name (optional, shown to students)'),
        findsNothing);

    // Add: entry only, no roster/inbox/setup.
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();
    expect(find.text('Direct manual entry'), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-roll')), findsOneWidget);
    expect(find.textContaining('Manual requests'), findsNothing);
    expect(find.textContaining('Waiting area'), findsNothing);
    expect(find.byKey(const ValueKey('prof-search')), findsNothing);

    // Setup: name field home, no roster/inbox/add.
    await t.tap(find.text('Setup'));
    await t.pumpAndSettle();
    expect(
        find.widgetWithText(
            TextField, 'Your name (optional, shown to students)'),
        findsOneWidget);
    expect(find.text('Direct manual entry'), findsNothing);
    expect(find.textContaining('Manual requests'), findsNothing);
    expect(find.textContaining('Waiting area'), findsNothing);

    // Back to Roster: full roster again (waiting + present + partial).
    await t.tap(find.text('Roster'));
    await t.pumpAndSettle();
    expect(find.textContaining('Waiting area (1)'), findsOneWidget);
    expect(find.textContaining('Present — all rounds (1)'), findsOneWidget);
    expect(find.textContaining('Partial — some rounds'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('state preserved across switches, incl. mid-approve inbox',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    final host = await _seededDriver();
    await t.pumpWidget(_scoped(const TakeAttendanceScreen(courseName: 'CS201'),
        store: store, host: host));
    await t.pumpAndSettle();

    // Roster search text survives a round-trip through another tab.
    expect(find.byKey(const ValueKey('prof-search')), findsOneWidget);
    await t.enterText(
        find.byKey(const ValueKey('prof-search')), 'a@univ.edu');
    await t.pumpAndSettle();

    // Mid-approve inbox: long-press enters hold-and-tap selection.
    await t.tap(find.text('Inbox (2)'));
    await t.pumpAndSettle();
    await t.longPress(find.text('M One'));
    await t.pumpAndSettle();
    expect(find.text('Approve 1'), findsOneWidget);

    // Switch away and back: the inbox stayed mounted, so the pending
    // selection (and the approve flow built on it) is intact.
    await t.tap(find.text('Roster'));
    await t.pumpAndSettle();
    expect(find.textContaining('Waiting area'), findsOneWidget);
    await t.tap(find.text('Inbox (2)'));
    await t.pumpAndSettle();
    expect(find.text('Approve 1'), findsOneWidget);
    expect(find.text('Manual requests (2)'), findsOneWidget);

    // Roster search survived the same round-trip (the field owns no
    // controller — read the live EditableText, not the widget param).
    await t.tap(find.text('Roster'));
    await t.pumpAndSettle();
    final editable = find.descendant(
      of: find.byKey(const ValueKey('prof-search')),
      matching: find.byType(EditableText),
    );
    expect(t.widget<EditableText>(editable).controller.text, 'a@univ.edu');
    expect(t.takeException(), isNull);
  });

  testWidgets('date header visible in IDLE and LIVE states', (t) async {
    Widget header(bool live) => LiveSessionHeader(
          live: live,
          elapsed: Duration.zero,
          present: 0,
          waiting: 0,
          windowsTaken: 0,
          windowNo: 0,
          hosting: true,
          hostLine: null,
          onStart: () {},
          onRetake: () {},
          onTakeAnother: () {},
          onStop: () {},
          onEnd: () {},
        );
    for (final live in [false, true]) {
      await t.pumpWidget(_themed(header(live)));
      await t.pumpAndSettle();
      // Same frozen helper + format, prominent header element (icon +
      // label-weight, not a caption) in both states.
      expect(find.text(fullDateOf(todayIso())), findsOneWidget);
      expect(find.byIcon(Icons.calendar_today_outlined), findsOneWidget);
      expect(live ? find.text('LIVE') : find.text('IDLE'), findsOneWidget);
      expect(t.takeException(), isNull);
    }
  });

  testWidgets('end attendance → Courses tab shows the new session',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    final host = FakeHostDriver();
    await t.pumpWidget(ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
            email: 'prof@example.com',
            displayName: 'Prof',
            uid: 'prof-uid'))),
        cloudSyncProvider.overrideWithValue(FakeCloudSync(online: false)),
        deviceStoreProvider.overrideWithValue(store),
        faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
        deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
        hostDriverProvider.overrideWithValue(host),
        studentDriverProvider
            .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
        bleEngineProvider
            .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        btPowerProvider.overrideWithValue(() async => BtState.on),
        enrollmentControllerProvider.overrideWith(
          (ref) => EnrollmentController(
            auth: ref.watch(authServiceProvider),
            store: ref.watch(deviceStoreProvider),
            verifier: FakeFaceVerifier(),
            deviceKey: FakeDeviceKey(),
          ),
        ),
      ],
      child: MaterialApp(theme: proxLightTheme(), home: const ProfShell()),
    ));
    await _settle(t);

    // Courses tab reads empty before the visit (stale-link baseline).
    await _openTab(t, 'Courses');
    expect(find.textContaining('0 sessions'), findsOneWidget);

    // Host from the Live tab and mark one student, then End attendance.
    await _openTab(t, 'Live');
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    expect(find.byType(TakeAttendanceScreen), findsOneWidget);
    await host.addManualEntry(email: 'a@x.in', name: 'A', roll: '1');
    await t.pump();
    await t.tap(find.text('End attendance'));
    await t.pumpAndSettle();
    // End pops back to the Live root (no restart, no relaunch).
    expect(find.byType(TakeAttendanceScreen), findsNothing);
    expect(find.text('CS201'), findsOneWidget);

    // Courses tab shows the new session — the End tick re-read the
    // IndexedStack-kept records state on re-show.
    await _openTab(t, 'Courses');
    expect(find.textContaining('1 sessions'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('courses picker re-reads on the history-refresh tick',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await t.pumpWidget(_scoped(const ProfCoursesScreen(), store: store));
    await t.pumpAndSettle();
    expect(find.textContaining('0 sessions'), findsOneWidget);

    // History written elsewhere (an End on the Live tab) + tick: the
    // picker re-reads without any restart or manual refresh.
    await store.upsertHistory(_record('sess-1', '2026-09-09'));
    bumpLiveHistoryTick();
    await t.pumpAndSettle();
    expect(find.textContaining('1 sessions'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('course overview re-reads on the history-refresh tick',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.upsertHistory(_record('sess-1', '2026-09-09'));
    await t.pumpWidget(
        _scoped(const CourseOverviewScreen(courseName: 'CS201'), store: store));
    await t.pumpAndSettle();
    expect(find.textContaining('1 sessions'), findsOneWidget);

    await store.upsertHistory(_record('sess-2', '2026-09-10'));
    bumpLiveHistoryTick();
    await t.pumpAndSettle();
    expect(find.textContaining('2 sessions'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
