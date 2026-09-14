import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/records/course_attendance_detail_screen.dart';
import 'package:proximity_app/widgets/course_attendance.dart';
import 'package:proximity_app/widgets/partial_list.dart';
import 'package:proximity_storage/storage.dart';

const _email = 'student@example.com';

ClassRecord rec(String id, String date, Map<String, bool> w1,
        [Map<String, bool>? w2]) =>
    ClassRecord(
      id: id,
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: date,
      timestampIso: '${date}T10:00:00.000Z',
      windows: [w1, if (w2 != null) w2],
      names: const {_email: 'Student One'},
      rolls: const {_email: '10000001'},
    );

void main() {
  test('summarizeCourse counts present/partial/absent days', () {
    final sessions = [
      rec('s1', '2026-09-04', {_email: true}),
      rec('s2', '2026-09-05', {_email: true}, {_email: false}),
      rec('s3', '2026-09-06', {_email: false}),
    ];
    final s = summarizeCourse('CS201', sessions, _email);
    expect(s.sessions, 3);
    expect(s.present, 1);
    expect(s.partial, 1);
    expect(s.absent, 1);
    expect(s.line, '1/3 days attended · 1 partial');
    expect(sessionStatusOf(sessions[1], _email), 'Partial 1/2');
  });

  test('partialsOfCourse lists multi-round partials only', () {
    final sessions = [
      rec('s1', '2026-09-04', {_email: true}),
      rec('s2', '2026-09-05', {_email: true}, {_email: false}),
    ];
    final partials = partialsOfCourse(sessions);
    expect(partials, hasLength(1));
    expect(partials.first.email, _email);
    expect(partials.first.sessions.first.$3, 'R1 ✓ · R2 ✗');
    expect(partialsOfCourse([sessions.first]), isEmpty);
  });

  testWidgets('StudentCourseScreen shows totals + sessions', (t) async {    final sessions = [
      rec('s1', '2026-09-04', {_email: true}),
      rec('s2', '2026-09-05', {_email: true}, {_email: false}),
    ];
    await t.pumpWidget(ProviderScope(child: MaterialApp(
        // App theme: rebuilt screens read the ProximityColors extension.
        theme: proxLightTheme(),
        home: CourseAttendanceDetailScreen(
            course: 'CS201', sessions: sessions, email: _email))));
    await t.pumpAndSettle();
    expect(find.text('1/2 days attended'), findsOneWidget);
    expect(find.text('Attendance percentage : 50%'), findsOneWidget);
    expect(find.textContaining('04-09-2026'), findsOneWidget);
    expect(find.textContaining('Partial 1/2'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('course detail header falls back to letters without a photo',
      (t) async {
    final sessions = [
      rec('s1', '2026-09-04', {_email: true}),
    ];
    await t.pumpWidget(ProviderScope(child: MaterialApp(
        theme: proxLightTheme(),
        home: CourseAttendanceDetailScreen(
            course: 'CS201', sessions: sessions, email: _email))));
    await t.pumpAndSettle();
    // No cached photo seen → course-letter disc in the ring center, no
    // network image attempted.
    expect(find.text('CS'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(t.takeException(), isNull);
  });

  test('courseRoster unions attendees, newest name wins', () {
    final old = rec('s1', '2026-09-04', {_email: true});
    final withNew = ClassRecord(
      id: 's2',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-05',
      timestampIso: '2026-09-05T10:00:00.000Z',
      windows: [
        {'new@example.com': true}
      ],
      names: const {_email: 'Student One', 'new@example.com': 'Newcomer'},
      rolls: const {_email: '10000001', 'new@example.com': '10000002'},
    );
    final roster = courseRoster([withNew, old]);
    expect(roster.map((e) => e.email),
        containsAll([_email, 'new@example.com']));
    // A newcomer in a new class reads as absent in earlier sessions:
    // they are in the union but in no window of s1.
    expect(old.windows.first.containsKey('new@example.com'), isFalse);
  });
}
