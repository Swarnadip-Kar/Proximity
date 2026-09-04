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

  testWidgets('course detail: sessions + export + retake', (t) async {    await t.pumpWidget(
        wrap(await seeded(), const CourseDetailScreen(courseName: 'CS201')));
    await t.pumpAndSettle();
    expect(find.text('Take attendance'), findsOneWidget);
    expect(find.textContaining('2026-09-03'), findsOneWidget);
    // export dialog shows signed-session CSV
    await t.tap(find.byTooltip('Export CSV'));
    await t.pumpAndSettle();
    expect(find.textContaining('A,1,a@x.in,1,0,Partial'), findsOneWidget);
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    // retake pushes the live screen and auto-starts window #1
    await t.tap(find.byTooltip('Retake attendance'));
    await t.pumpAndSettle();
    expect(find.textContaining('demo · Code KQ7'), findsOneWidget);
    // let the auto-started window close so no timers leak
    await t.pump(const Duration(seconds: 31));
    await t.pumpAndSettle();
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
