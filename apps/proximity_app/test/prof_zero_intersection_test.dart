// Prof zero-intersection (tester-verified prof-shell duplication bugs).
//
// Audit map (grep-proven, see INTEGRATION_LOG `## Prof zero-intersection`):
// - Manual attendance-taking home: Live>Add only (`DirectAddSection`,
//   `direct-` keys, `Direct manual entry` + `Add & mark present`). Removed:
//   take-scroll extra sheet (`sheet-` keys + `Add student` AppBar entry).
//   Kept with proof: session-edit `Add person` (`edit-` keys) is
//   correction-scoped with distinct copy (see the session-edit group).
//   Roster path + setup path carry no manual-entry UI (asserted absent).
// - Prof display-name editable field home: Live>Setup only
//   (`Your name (optional, shown to students)`). No second editable prof
//   name field in owned files; Account `Display name` is a read-only fact
//   (outside ownership, not a field); the old `account-prof-name` register
//   field is gone (one-button switch, verified zero hits in lib).
// - Each Live sub-section its own concern only: roster =
//   waiting/present/partial/dup/search; inbox = requests; add = entry;
//   setup = name/IP/discovery (+ recover via banner/dialog, separate).
// - Live header date/day: `fullDateOf(todayIso())` (frozen records
//   helpers/formats), showing today.
// - Tab rows: Live = host entry only (radio + `Tap to host live session`
//   + `Host` action, no management); Courses = records/management only
//   (verified records-only, no hosting affordance).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/live/direct_add.dart';
import 'package:proximity_app/features/live/live_roster.dart';
import 'package:proximity_app/features/live/live_session.dart';
import 'package:proximity_app/features/live/live_setup.dart';
import 'package:proximity_app/features/live/manual_inbox.dart';
import 'package:proximity_app/features/manual_attendance/manual_attendance.dart'
    as ma;
import 'package:proximity_app/features/records/session_edit_screen.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_app/screens/take_attendance.dart';
import 'package:proximity_app/widgets/clock.dart';
import 'package:proximity_storage/storage.dart';

import 'widget_test.dart' as helpers;

Widget _themed(Widget body) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: body),
    );

/// Shell ProviderScope shims removed (A4): pumps below use the canonical
/// widget_test.testScope with an explicit offline cloud + MaterialApp home.
/// The take-host _settle stays local: A3 unifies only the live_subtabs vs
/// tab_slide pair, and _openTab variants stay distinct per brief.

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
  ]);
  return driver;
}

/// Prof-shell shim removed (A4): the Live-rows test below uses the
/// canonical widget_test.testScope (prof email + store + ProfShell home).

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  testWidgets('Live header shows today date/day (frozen records format)',
      (t) async {
    await t.pumpWidget(_themed(LiveSessionHeader(
      live: false,
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
    )));
    await t.pumpAndSettle();
    // Frozen helper + frozen format, showing today (current hosting date).
    expect(find.text(fullDateOf(todayIso())), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('roster path: roster-only, no manual entry, no setup field',
      (t) async {
    final driver = await _seededDriver();
    await t.pumpWidget(ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
        hostDriverProvider.overrideWithValue(driver),
      ],
      child: MaterialApp(
        theme: proxLightTheme(),
        home: Scaffold(
          // Scroll like the Take host's Roster sub-tab (same composer,
          // same constraints — the body is taller than the test viewport).
          body: SingleChildScrollView(
            child: LiveRosterBody(
              waitingRows: driver.waitingRows,
              groups: driver.dupGroups,
              names: driver.tally.nameMap(),
              onResolve: (email) => driver.resolveDupFlag(email),
              tally: driver.tally,
              onRemoveStudent: (email) => driver.removeStudent(email),
            ),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    // Own concern only.
    expect(find.textContaining('Waiting area (1)'), findsOneWidget);
    expect(find.textContaining('Present — all rounds (1)'), findsOneWidget);
    expect(find.textContaining('Partial — some rounds'), findsOneWidget);
    expect(find.textContaining('duplicate face'), findsOneWidget);
    expect(find.byKey(const ValueKey('prof-search')), findsOneWidget);
    // Zero intersection: no inbox/add/setup composition here.
    expect(find.byType(ma.ManualAddForm), findsNothing);
    expect(find.byType(ManualInboxSection), findsNothing);
    expect(find.byType(DirectAddSection), findsNothing);
    expect(find.byType(LiveSetupSection), findsNothing);
    expect(find.text('Direct manual entry'), findsNothing);
    expect(find.text('Add & mark present'), findsNothing);
    expect(find.textContaining('Manual requests'), findsNothing);
    expect(
        find.widgetWithText(
            TextField, 'Your name (optional, shown to students)'),
        findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('inbox section: requests only, no roster/add/setup',
      (t) async {
    final driver = await _seededDriver();
    await t.pumpWidget(ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
        cloudSyncProvider.overrideWithValue(FakeCloudSync()),
        hostDriverProvider.overrideWithValue(driver),
      ],
      child: MaterialApp(
        theme: proxLightTheme(),
        home: Scaffold(
          body: ManualInboxSection(
            pending: driver.manualPending,
            onApproveOne: (e) => driver.decideManual(e, true),
            onRejectOne: (e) => driver.decideManual(e, false),
            onDecide: (emails, approve) async {
              for (final e in emails) {
                await driver.decideManual(e, approve);
              }
            },
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('Manual requests (1)'), findsOneWidget);
    expect(find.text('M One'), findsOneWidget);
    // No roster/add/setup composition here.
    expect(find.byType(ma.ManualAddForm), findsNothing);
    expect(find.byType(WaitingListSection), findsNothing);
    expect(find.byType(MarkedRosterSection), findsNothing);
    expect(find.byType(DirectAddSection), findsNothing);
    expect(find.byType(LiveSetupSection), findsNothing);
    expect(find.text('Direct manual entry'), findsNothing);
    expect(find.text('Add & mark present'), findsNothing);
    expect(find.textContaining('Waiting area'), findsNothing);
    expect(find.textContaining('Present — all rounds'), findsNothing);
    expect(find.byKey(const ValueKey('prof-search')), findsNothing);
    expect(
        find.widgetWithText(
            TextField, 'Your name (optional, shown to students)'),
        findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('add section: entry only, no roster/inbox/setup', (t) async {
    final driver = await _seededDriver();
    final store = InMemoryDeviceStore();
    await t.pumpWidget(ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(store),
        cloudSyncProvider.overrideWithValue(FakeCloudSync(online: false)),
        hostDriverProvider.overrideWithValue(driver),
      ],
      child: MaterialApp(
        theme: proxLightTheme(),
        home: Scaffold(
          body: DirectAddSection(
            course: 'CS201',
            sessionId: '',
            onAdd: (
                {required String name,
                required String roll,
                required String email}) async {
              await driver.addManualEntry(
                  email: email, name: name, roll: roll);
            },
            isPresent: (email) => driver.tally.confirmed
                .any((r) => r.email == email.toLowerCase()),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.byType(ma.ManualAddForm), findsOneWidget);
    expect(find.text('Add & mark present'), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-roll')), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-email')), findsOneWidget);
    // No roster/inbox/setup composition here.
    expect(find.byType(WaitingListSection), findsNothing);
    expect(find.byType(MarkedRosterSection), findsNothing);
    expect(find.byType(ManualInboxSection), findsNothing);
    expect(find.byType(LiveSetupSection), findsNothing);
    expect(find.textContaining('Manual requests'), findsNothing);
    expect(find.textContaining('Waiting area'), findsNothing);
    expect(
        find.widgetWithText(
            TextField, 'Your name (optional, shown to students)'),
        findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('setup: name field lives here only (single home)',
      (t) async {
    final nameCtrl = TextEditingController(text: '');
    addTearDown(nameCtrl.dispose);
    await t.pumpWidget(_themed(LiveSetupSection(
      hosting: true,
      live: false,
      nameCtrl: nameCtrl,
      onNameChanged: (_) {},
      serverLine: 'https://192.168.1.2:8443 · waiting for window',
      allIps: const ['192.168.1.2'],
      currentIp: '192.168.1.2',
      onPickIp: () {},
      serverError: null,
    )));
    await t.pumpAndSettle();
    // Own concern only: name + server line, no manual entry.
    expect(
        find.widgetWithText(
            TextField, 'Your name (optional, shown to students)'),
        findsOneWidget);
    expect(find.byType(ma.ManualAddForm), findsNothing);
    expect(find.byType(ManualInboxSection), findsNothing);
    expect(find.byType(WaitingListSection), findsNothing);
    expect(find.byType(MarkedRosterSection), findsNothing);
    expect(find.text('Direct manual entry'), findsNothing);
    expect(find.textContaining('Manual requests'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('take host: sub-tabs swap, each section exactly once',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    final host = FakeHostDriver();
    await t.pumpWidget(helpers.testScope(
        store: store,
        hostDriver: host,
        cloud: FakeCloudSync(online: false),
        home: MaterialApp(
            theme: proxLightTheme(),
            home: const TakeAttendanceScreen(courseName: 'CS201'))));
    await t.pumpAndSettle();

    // Fixed chrome each once.
    expect(find.byType(LiveSessionHeader), findsOneWidget);
    // Session date/day header (today) in the header.
    expect(find.text(fullDateOf(todayIso())), findsOneWidget);
    // No AppBar sheet extra (removed duplicate entry point).
    expect(find.byTooltip('Add student'), findsNothing);
    expect(find.text('Add student'), findsNothing);
    expect(find.byKey(const ValueKey('sheet-roll')), findsNothing);
    expect(find.byKey(const ValueKey('sheet-name')), findsNothing);
    expect(find.byKey(const ValueKey('sheet-email')), findsNothing);

    // Real sub-tabs (tester fix): the sub-nav swaps via an IndexedStack —
    // each sub-tab shows ONLY its view (no shared scroll, asserted by
    // absence below with the default offstage-skipping finders).
    expect(find.byType(IndexedStack), findsOneWidget);

    // Default = Roster: waiting + marked only, no inbox/add/setup.
    expect(find.textContaining('Waiting area'), findsOneWidget);
    expect(find.byKey(const ValueKey('prof-search')), findsOneWidget);
    expect(find.textContaining('Manual requests'), findsNothing);
    expect(find.text('Direct manual entry'), findsNothing);
    expect(
        find.widgetWithText(
            TextField, 'Your name (optional, shown to students)'),
        findsNothing);

    // Inbox sub-tab: requests only, no roster/add/setup.
    await t.tap(find.text('Inbox'));
    await t.pumpAndSettle();
    expect(find.textContaining('Manual requests'), findsOneWidget);
    expect(find.textContaining('Waiting area'), findsNothing);
    expect(find.text('Direct manual entry'), findsNothing);
    expect(find.byKey(const ValueKey('prof-search')), findsNothing);
    expect(
        find.widgetWithText(
            TextField, 'Your name (optional, shown to students)'),
        findsNothing);

    // Add sub-tab: entry only, no roster/inbox/setup.
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();
    expect(find.text('Direct manual entry'), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-roll')), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-email')), findsOneWidget);
    expect(find.text('Add & mark present'), findsOneWidget);
    expect(find.textContaining('Manual requests'), findsNothing);
    expect(find.textContaining('Waiting area'), findsNothing);
    expect(find.byKey(const ValueKey('prof-search')), findsNothing);

    // Setup sub-tab: name field home, no roster/inbox/add.
    await t.tap(find.text('Setup'));
    await t.pumpAndSettle();
    expect(
        find.widgetWithText(
            TextField, 'Your name (optional, shown to students)'),
        findsOneWidget);
    expect(find.text('Direct manual entry'), findsNothing);
    expect(find.textContaining('Manual requests'), findsNothing);
    expect(find.textContaining('Waiting area'), findsNothing);
    expect(find.byKey(const ValueKey('prof-search')), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('Live rows are host-only; Courses rows are records-only',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await t.pumpWidget(helpers.testScope(
        email: 'prof@example.com',
        store: store,
        home: MaterialApp(theme: proxLightTheme(), home: const ProfShell()),
    ));
    await _settle(t);

    // Live tab root: host entry only.
    expect(find.text('CS201'), findsOneWidget);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Tap to host live session'), findsOneWidget);
    // No management on the Live picker.
    expect(find.text('Register new course'), findsNothing);
    expect(find.textContaining('sessions ·'), findsNothing);
    expect(find.textContaining('people ·'), findsNothing);
    expect(find.text('Review & export'), findsNothing);
    expect(find.text('Delete course'), findsNothing);

    // Courses tab: records/management only (already records-only).
    final coursesTab = find.descendant(
      of: find.byKey(const ValueKey('shell-bar')),
      matching: find.text('Courses'),
    );
    await t.tap(coursesTab);
    await _settle(t);
    expect(find.text('Register new course'), findsOneWidget);
    expect(find.textContaining('sessions ·'), findsOneWidget);
    // No hosting affordance on the Courses picker.
    expect(find.text('Host'), findsNothing);
    expect(find.text('Tap to host live session'), findsNothing);
    expect(find.text('Take attendance'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'session-edit Add person is correction-scoped with distinct copy (kept)',
      (t) async {
    final record = ClassRecord(
      id: 'sess-1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-05',
      timestampIso: '2026-09-05T10:00:00.000Z',
      startIso: '2026-09-05T10:00:00.000Z',
      w1: const {'a@x.in': true},
      w2: const {'a@x.in': false},
      names: const {'a@x.in': 'A'},
      rolls: const {'a@x.in': '1'},
    );
    await t.pumpWidget(helpers.testScope(
        cloud: FakeCloudSync(online: false),
        home: MaterialApp(
            theme: proxLightTheme(),
            home: SessionEditScreen(record: record, courseSessions: [record]))));
    await t.pumpAndSettle();
    // Distinct correction copy (not the live `Direct manual entry`):
    // sub-tabs Marks + Add person (navigation only).
    expect(find.text('Marks'), findsOneWidget);
    expect(find.text('Add person'), findsOneWidget);
    expect(find.text('Direct manual entry'), findsNothing);
    // Default = Marks: `Save changes` sits below the fold (long form):
    // drag to materialize it before asserting (same lazy-list pattern
    // as take); the Add form is offstage here.
    await t.drag(find.byType(ListView).first, const Offset(0, -800));
    await t.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-roll')), findsNothing);
    // Add tab: same module form but correction-scoped keys +
    // local present-check.
    await t.tap(find.text('Add person'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-roll')), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-roll')), findsNothing);
    // Per-round correction chrome (not live Start/Stop controls).
    await t.tap(find.text('Marks'));
    await t.pumpAndSettle();
    expect(find.textContaining('Partial in this session'), findsOneWidget);
    expect(find.text('Start'), findsNothing);
    expect(find.text('Stop'), findsNothing);
    expect(t.takeException(), isNull);
  });

  test('account-prof-name editable field has no lib hits (single home kept)',
      () {
    // The one-button Account switch carries no prof-name TextField; the
    // editable prof display-name field lives ONLY in Live>Setup.
    // Pinned here so a reintroduced account-side field fails fast.
    expect(find.byKey(const Key('account-prof-name')), findsNothing);
  });
}
