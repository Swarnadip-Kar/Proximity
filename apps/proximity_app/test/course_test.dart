import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/ble_radio.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/face_camera.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/screens/course_detail.dart';
import 'package:proximity_app/screens/courses.dart';
import 'package:proximity_app/screens/take_attendance.dart';
import 'package:proximity_app/widgets/clock.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

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

ProviderScope wrap(InMemoryDeviceStore s, Widget home) => ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(s),
        faceCameraProvider.overrideWithValue(FakeFaceCamera()),
        hostDriverProvider.overrideWithValue(FakeHostDriver()),
        studentDriverProvider.overrideWithValue(FakeStudentDriver()),
        bleEngineProvider
            .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        cameraPermissionProvider.overrideWithValue(() async => true),
        btPowerProvider.overrideWithValue(() async => BtState.on),
      ],
      child: MaterialApp(home: home),
    );

void main() {
  testWidgets('courses list recent-first with session counts', (t) async {
    await t.pumpWidget(wrap(await seeded(), const ProfCoursesScreen()));
    await t.pumpAndSettle();
    expect(find.text('CS201'), findsOneWidget);
    expect(find.text('CS202'), findsOneWidget);
    expect(find.textContaining('1 sessions'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('courses empty state + register', (t) async {
    await t.pumpWidget(wrap(InMemoryDeviceStore(), const ProfCoursesScreen()));
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

  test('date labels: short day/month + full weekday/date/year', () {
    expect(shortDayDateOf('2026-09-03'), 'Thu, 3 Sep');
    expect(shortDateOf('2026-09-03'), '3 Sep');
    expect(fullDateOf('2026-09-03'), 'Thursday, 3 September 2026');
    expect(shortTimeOf('2026-09-03T12:34:56.000Z'), isNotEmpty);
    expect(shortTimeOf('2026-09-03T00:00:00.000'), isEmpty);
    expect(shortDayDateOf('garbage'), 'garbage');
  });

  testWidgets('course detail: sessions + export + retake', (t) async {    await t.pumpWidget(
        wrap(await seeded(), const CourseDetailScreen(courseName: 'CS201')));
    await t.pumpAndSettle();
    expect(find.text('Take attendance'), findsOneWidget);
    expect(find.text('Export date range'), findsOneWidget);
    // Tight title: short weekday + day/month; roomy subtitle: full date.
    expect(find.textContaining('Thu, 3 Sep'), findsOneWidget);
    expect(
        find.textContaining('Thursday, 3 September 2026'), findsOneWidget);
    expect(find.textContaining('2026-09-03'), findsNothing);
    // export dialog shows simple session CSV (no W1/W2)
    await t.tap(find.byTooltip('Export CSV'));
    await t.pumpAndSettle();
    expect(find.textContaining('A,1,a@x.in,Absent'), findsOneWidget);
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    // retake pushes the live screen and auto-starts the single window
    await t.tap(find.byTooltip('Retake attendance'));
    await t.pumpAndSettle();
    expect(find.textContaining('demo · Code KQ7'), findsOneWidget);
    // stop early so no timers leak, then close
    await t.tap(find.text('Stop'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('course detail: select sessions + delete with X/Y warning',
      (t) async {
    await t.pumpWidget(
        wrap(await seeded(), const CourseDetailScreen(courseName: 'CS201')));
    await t.pumpAndSettle();
    await t.tap(find.byType(Checkbox).first);
    await t.pumpAndSettle();
    expect(find.textContaining('Delete selected (1)'), findsOneWidget);
    await t.tap(find.textContaining('Delete selected (1)'));
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

  testWidgets('prof courses: delete course with X/Y warning', (t) async {
    await t.pumpWidget(wrap(await seeded(), const ProfCoursesScreen()));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Delete course').first);
    await t.pumpAndSettle();
    expect(
        find.textContaining(
            'delete attendance data of 1 students for 1 sessions'),
        findsOneWidget);
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(find.text('CS201'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('course rename from detail returns to updated list', (t) async {
    await t.pumpWidget(
        wrap(await seeded(), const ProfCoursesScreen()));
    await t.pumpAndSettle();
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
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
    await t.pumpWidget(wrap(await seeded(),
        const TakeAttendanceScreen(courseName: 'CS201')));
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
