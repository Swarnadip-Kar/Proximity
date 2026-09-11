import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/records/course_attendance_detail_screen.dart';
import 'package:proximity_app/features/records/course_overview_screen.dart';
import 'package:proximity_app/features/records/export_center_screen.dart';
import 'package:proximity_app/features/records/my_attendance_screen.dart';
import 'package:proximity_app/features/records/prof_courses_screen.dart';
import 'package:proximity_app/features/records/session_detail_screen.dart';
import 'package:proximity_app/features/records/session_edit_screen.dart';
import 'package:proximity_app/screens/take_attendance.dart';
import 'package:proximity_app/widgets/clock.dart';
import 'package:proximity_storage/storage.dart';

import 'widget_test.dart' as helpers;

Future<InMemoryDeviceStore> seeded() async {
  final s = InMemoryDeviceStore();
  await s.addCourse('CS201');
  await s.addCourse('CS202');
  await s.appendHistory(ClassRecord(
    courseId: 'CS201',
    classLabel: 'CS201',
    dateIso: '2026-09-03',
    w1: const {'a@x.in': true},
    w2: const {'a@x.in': false},
    names: const {'a@x.in': 'A'},
    rolls: const {'a@x.in': '1'},
  ));
  return s;
}

/// Records ProviderScope shim removed (A4): pumps below use the canonical
/// widget_test.testScope (store + explicit MaterialApp home).

void main() {
  testWidgets('courses list recent-first with session counts', (t) async {
    await t.pumpWidget(helpers.testScope(
        store: await seeded(),
        home: MaterialApp(
            theme: proxLightTheme(), home: const ProfCoursesScreen())));
    await t.pumpAndSettle();
    expect(find.text('CS201'), findsOneWidget);
    expect(find.text('CS202'), findsOneWidget);
    expect(find.textContaining('1 sessions'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('courses empty state + register', (t) async {
    await t.pumpWidget(helpers.testScope(
        store: InMemoryDeviceStore(),
        home: MaterialApp(
            theme: proxLightTheme(), home: const ProfCoursesScreen())));
    await t.pumpAndSettle();
    expect(find.textContaining('No courses yet'), findsOneWidget);
    await t.tap(find.text('Register new course'));
    await t.pumpAndSettle();
    await t.enterText(
        find.widgetWithText(TextField, 'Course name'), 'CS301');
    await t.tap(find.text('Register'));
    await t.pumpAndSettle();
    expect(find.text('CS301'), findsOneWidget);
  });

  test('records route identities match the IA (one name per screen)', () {
    // Navigation identity (records packet): every in-tab push carries one
    // of these names — named logs, popUntil by name/prefix, deep-link parity.
    expect(ProfCoursesScreen.routeName, 'prof/courses');
    expect(CourseOverviewScreen.routeName('CS201'), 'prof/courses/CS201');
    expect(
        ExportCenterScreen.routeName('CS201'), 'prof/courses/CS201/export');
    expect(SessionDetailScreen.routeName('CS201', 'sess-1'),
        'prof/courses/CS201/sessions/sess-1');
    expect(SessionEditScreen.routeName('CS201', 'sess-1'),
        'prof/courses/CS201/sessions/sess-1/edit');
    expect(MyAttendanceScreen.routeName, 'records/mine');
    expect(CourseAttendanceDetailScreen.routeName('CS201'),
        'records/mine/CS201');
  });

  test('date labels: short day/month + full weekday/date/year', () {
    expect(shortDayDateOf('2026-09-03'), 'Thu, 03-09-2026');
    expect(shortDateOf('2026-09-03'), '03-09-2026');
    expect(fullDateOf('2026-09-03'), 'Thursday, 03-09-2026');
    expect(shortTimeOf('2026-09-03T12:34:56.000Z'), isNotEmpty);
    expect(shortTimeOf('2026-09-03T00:00:00.000'), isEmpty);
    expect(shortDayDateOf('garbage'), 'garbage');
  });

  testWidgets('course overview: sessions + export center (records-only)',
      (t) async {
    await t.pumpWidget(helpers.testScope(
        store: await seeded(),
        home: MaterialApp(
            theme: proxLightTheme(),
            home: const CourseOverviewScreen(courseName: 'CS201'))));
    await t.pumpAndSettle();
    // Records-only (§3.1a): no hosting entry lives in this tab.
    expect(find.text('Take attendance'), findsNothing);
    expect(find.byTooltip('Retake attendance'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('Review & export'), findsOneWidget);
    // Tight title: short weekday + DD-MM-YYYY; roomy subtitle: full date.
    expect(find.textContaining('Thu, 03-09-2026'), findsOneWidget);
    expect(
        find.textContaining('Thursday, 03-09-2026'), findsOneWidget);
    expect(find.textContaining('2026-09-03'), findsNothing);
    // Review & export opens the export center (per-session CSV + matrix).
    await t.tap(find.text('Review & export'));
    await t.pumpAndSettle();
    // Navigation identity (records packet): one named route per screen.
    expect(
        ModalRoute.of(t.element(find.byType(ExportCenterScreen)))
            ?.settings
            .name,
        'prof/courses/CS201/export');
    expect(find.text('Export date range'), findsOneWidget);
    await t.tap(find.byTooltip('Export CSV'));
    await t.pumpAndSettle();
    // export dialog shows simple session CSV (no W1/W2)
    expect(find.textContaining('A,1,a@x.in,Absent'), findsOneWidget);
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('export center: date-range matrix reachable', (t) async {
    await t.pumpWidget(helpers.testScope(
        store: await seeded(),
        home: MaterialApp(
            theme: proxLightTheme(),
            home: const ExportCenterScreen(courseName: 'CS201'))));
    await t.pumpAndSettle();
    expect(find.text('Export date range'), findsOneWidget);
    expect(find.textContaining('Thu, 03-09-2026'), findsOneWidget);
    await t.tap(find.text('Export date range'));
    await t.pumpAndSettle();
    // Date-range picker opens as a dialog; dismiss back to the center.
    expect(find.byType(Dialog), findsWidgets);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('Export date range'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('course overview: hold-and-tap select + delete with X/Y warning',
      (t) async {
    await t.pumpWidget(helpers.testScope(
        store: await seeded(),
        home: MaterialApp(
            theme: proxLightTheme(),
            home: const CourseOverviewScreen(courseName: 'CS201'))));
    await t.pumpAndSettle();
    // Hold-and-tap enters selection mode (no checkboxes in this tab).
    await t.longPress(find.textContaining('Thu, 03-09-2026'));
    await t.pumpAndSettle();
    expect(find.text('Delete 1'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);
    expect(find.byTooltip('Cancel'), findsOneWidget);
    await t.tap(find.text('Delete 1'));
    await t.pumpAndSettle();
    expect(
        find.textContaining(
            'delete attendance data of 1 students for 1 sessions'),
        findsOneWidget);
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(find.textContaining('No sessions yet'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('prof overview: delete course with X/Y warning', (t) async {
    await t.pumpWidget(helpers.testScope(
        store: await seeded(),
        home: MaterialApp(
            theme: proxLightTheme(),
            home: const CourseOverviewScreen(courseName: 'CS201'))));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Delete course'), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Delete course'));
    await t.pumpAndSettle();
    expect(
        find.textContaining(
            'delete attendance data of 1 students for 1 sessions'),
        findsOneWidget);
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    // Popped back after deleting the whole course.
    expect(find.text('Delete course'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('course rename from detail returns to updated list', (t) async {
    await t.pumpWidget(helpers.testScope(
        store: await seeded(),
        home: MaterialApp(
            theme: proxLightTheme(), home: const ProfCoursesScreen())));
    await t.pumpAndSettle();
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    // Navigation identity (records packet): one named route per screen.
    expect(
        ModalRoute.of(t.element(find.byType(CourseOverviewScreen)))
            ?.settings
            .name,
        'prof/courses/CS201');
    await t.tap(find.byTooltip('Edit course'));
    await t.pumpAndSettle();
    await t.enterText(
        find.widgetWithText(TextField, 'Course name'), 'CS201-A');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    // popped back; list shows the renamed course
    expect(find.text('CS201-A'), findsOneWidget);
    expect(find.text('CS201'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('take screen shows optional professor name field', (t) async {
    await t.pumpWidget(helpers.testScope(
        store: await seeded(),
        home: MaterialApp(
            theme: proxLightTheme(),
            home: const TakeAttendanceScreen(courseName: 'CS201'))));
    await t.pumpAndSettle();
    // The name field lives on the Setup sub-tab (real sub-tabs: tap swaps).
    await t.tap(find.text('Setup'));
    await t.pumpAndSettle();
    expect(
        find.widgetWithText(
            TextField, 'Your name (optional, shown to students)'),
        findsOneWidget);
    await t.enterText(
        find.widgetWithText(
            TextField, 'Your name (optional, shown to students)'),
        'Prof K');
    await t.pump();
    expect(t.takeException(), isNull);
  });
}
