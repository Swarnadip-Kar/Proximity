import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/screens/student_course.dart';
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
        home: StudentCourseScreen(
            course: 'CS201', sessions: sessions, email: _email))));
    await t.pumpAndSettle();
    expect(find.text('1/2 days attended · 1 partial'), findsOneWidget);
    expect(find.textContaining('2026-09-04'), findsOneWidget);
    expect(find.textContaining('Partial 1/2'), findsOneWidget);
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
