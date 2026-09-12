// Date-visibility fixes (tester-verified, presentation only).
//
// 1. Student session tiles: the frozen `sessionDateTimeLine` date is its own
//    prominent wrapping line (never ellipsized); status badge +
//    rounds/label/org secondary below (ellipsis only there). Pinned at
//    360dp-narrow + 130% text scale with longest labels.
// 2. Live tab root: today's date header (frozen `fullDateOf(todayIso())`,
//    same as the take header) exactly once; per-course last-hosted is NOT
//    repeated here — it lives on the Courses picker subtitle. Take-screen
//    header itself untouched (pinned unchanged here).
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
import 'package:proximity_app/features/live/live_session.dart';
import 'package:proximity_app/features/records/course_attendance_detail_screen.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_app/widgets/clock.dart';
import 'package:proximity_app/widgets/course_attendance.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

const _email = 'student@example.com';

ClassRecord _longSession() => ClassRecord(
      id: 'long-1',
      courseId: 'CS201',
      classLabel:
          'CS201-Advanced-Quantum-Field-Theory-Laboratory-Section-A-Room-301',
      dateIso: '2026-09-06',
      timestampIso: '2026-09-06T14:30:00.000Z',
      startIso: '2026-09-06T14:30:00.000Z',
      windows: [
        {_email: true},
        {_email: false},
        {_email: true},
        {_email: false},
        {_email: true},
        {_email: false},
        {_email: true},
        {_email: false},
      ],
      names: const {_email: 'Student One'},
      rolls: const {_email: '10000001'},
      org:
          'a.very.long.institute.organization.name.that.keeps.going.example.edu',
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

Widget _profShell(InMemoryDeviceStore store) => ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
            email: 'prof@example.com',
            displayName: 'Prof',
            uid: 'prof-uid'))),
        cloudSyncProvider.overrideWithValue(FakeCloudSync()),
        deviceStoreProvider.overrideWithValue(store),
        faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
        deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
        hostDriverProvider.overrideWithValue(FakeHostDriver()),
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
    );

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  testWidgets(
      'tile: full date visible at 360dp + 130% with longest labels',
      (t) async {
    _narrow(t);
    final s = _longSession();
    final dateLine = sessionDateTimeLine(s);
    await t.pumpWidget(ProviderScope(
      child: _scaled(
        StudentSessionTile(session: s, email: _email, course: 'CS201'),
      ),
    ));
    await t.pumpAndSettle();
    // Full frozen date string renders exactly once, fully.
    expect(find.text(dateLine), findsOneWidget);
    // Date line never ellipsizes (§10.1); secondary does.
    final dateText = t.widget<Text>(find.text(dateLine));
    expect(dateText.overflow, isNot(TextOverflow.ellipsis));
    expect(dateText.softWrap, isTrue);
    // Same data, better hierarchy: status badge + rounds/label/org present.
    expect(find.textContaining('Partial 4/8'), findsOneWidget);
    expect(find.textContaining('8 rounds'), findsOneWidget);
    expect(find.textContaining('example.edu'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('detail: full date visible at 360dp + 130% with trail',
      (t) async {
    _narrow(t);
    final s = _longSession();
    final dateLine = sessionDateTimeLine(s);
    await t.pumpWidget(ProviderScope(
      child: _scaled(
        CourseAttendanceDetailScreen(
            course: 'CS201', sessions: [s], email: _email),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text(dateLine), findsOneWidget);
    final dateText = t.widget<Text>(find.text(dateLine));
    expect(dateText.overflow, isNot(TextOverflow.ellipsis));
    expect(find.textContaining('Partial 4/8'), findsOneWidget);
    // Round-trail chips still render (same data).
    expect(find.textContaining('R1'), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('Live rows show today once, no per-course date repeat',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await store.addCourse('CS202');
    await store.upsertHistory(ClassRecord(
      id: 'h1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-04',
      timestampIso: '2026-09-04T10:00:00.000Z',
      w1: const {'a@x.in': true},
      names: const {'a@x.in': 'A'},
      rolls: const {'a@x.in': '1'},
    ));
    await t.pumpWidget(_profShell(store));
    await _settle(t);
    // Today's header, frozen take-header format — exactly once.
    expect(find.text(fullDateOf(todayIso())), findsOneWidget);
    // Per-course last-hosted lives on the Courses picker subtitle, not
    // here: no repeated date lines, no stale empty states.
    expect(find.textContaining('Last hosted'), findsNothing);
    expect(find.text('Not hosted yet'), findsNothing);
    // Host-only preserved: verbatim host line stays, no session counts.
    expect(find.text('Tap to host live session'), findsNWidgets(2));
    expect(find.textContaining('sessions ·'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('take header date unchanged (consistency, no duplication)',
      (t) async {
    await t.pumpWidget(MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(
        body: LiveSessionHeader(
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
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text(fullDateOf(todayIso())), findsOneWidget);
    expect(find.byIcon(Icons.calendar_today_outlined), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
