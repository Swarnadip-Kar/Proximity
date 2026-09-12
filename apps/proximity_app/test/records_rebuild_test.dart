// Courses-tab rebuild proofs: hide-inside-detail reloads the parent,
// the date-range matrix bytes are unchanged, and the overview exposes no
// hosting entry (hold-and-tap deletes instead of checkboxes).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/records/course_attendance_detail_screen.dart';
import 'package:proximity_app/features/records/course_overview_screen.dart';
import 'package:proximity_app/features/records/session_detail_screen.dart';
import 'package:proximity_app/widgets/selection_toolbar.dart';
import 'package:proximity_app/features/records/my_attendance_screen.dart';
import 'package:proximity_storage/storage.dart';

const _email = 'student@example.com';

ClassRecord _studentRec(String id, String date, Map<String, bool> w1,
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
      // App theme: rebuilt screens read the ProximityColors extension.
      child: MaterialApp(theme: proxLightTheme(), home: home),
    );

void main() {
  testWidgets('hide inside detail reloads My Attendance on return',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.writeStudentSessions([
      _studentRec('s1', '2026-09-04', {_email: true}),
      _studentRec('s2', '2026-09-05', {_email: true}),
    ]);
    // Offline path reads the device cache (no network in this test).
    await t.pumpWidget(_wrap(
        store: store,
        cloud: FakeCloudSync(online: false),
        home: const MyAttendanceScreen()));
    await t.pumpAndSettle();
    expect(find.text('2/2 days attended'), findsOneWidget);
    // Drill into the course, hide one session on this device only.
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    // Navigation identity (records packet): one named route per screen.
    expect(
        ModalRoute.of(t.element(find.byType(CourseAttendanceDetailScreen)))
            ?.settings
            .name,
        'records/mine/CS201');
    await t.tap(find.byTooltip('Remove from this device').first);
    await t.pumpAndSettle();
    expect(
        find.text('Removed from this device only — class data unchanged.'),
        findsOneWidget);
    expect((await store.readHiddenSessions()).contains('s1'), isTrue);
    // Back returns null (no PopScope); the parent always refreshes.
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.text('1/1 days attended'), findsOneWidget);
    expect(find.text('2/2 days attended'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('session detail highlights the present total', (t) async {
    final record = ClassRecord(
      id: 'd1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-05',
      timestampIso: '2026-09-05T10:00:00.000Z',
      windows: [
        {'a@x.in': true, 'b@x.in': true, 'c@x.in': false},
      ],
      names: const {'a@x.in': 'A', 'b@x.in': 'B', 'c@x.in': 'C'},
      rolls: const {'a@x.in': '1', 'b@x.in': '2', 'c@x.in': '3'},
    );
    await t.pumpWidget(_wrap(
        store: InMemoryDeviceStore(),
        cloud: FakeCloudSync(),
        home: MaterialApp(
          theme: proxLightTheme(),
          home:
              SessionDetailScreen(record: record, courseSessions: [record]),
        )));
    await t.pumpAndSettle();
    // Centered verdict row: Present / Partial / Absent badges with real
    // counts, windows caption below.
    expect(find.text('Present 2'), findsOneWidget);
    expect(find.text('Partial 0'), findsOneWidget);
    expect(find.text('Absent 1'), findsOneWidget);
    expect(find.text('1 round'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  test('date-range matrix bytes are unchanged', () {
    final s1 = ClassRecord(
      id: 'm1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-04',
      timestampIso: '2026-09-04T10:00:00.000Z',
      windows: [
        {'a@x.in': true, 'b@x.in': true}
      ],
      names: const {'a@x.in': 'A', 'b@x.in': 'B'},
      rolls: const {'a@x.in': '1', 'b@x.in': '2'},
    );
    final s2 = ClassRecord(
      id: 'm2',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-05',
      timestampIso: '2026-09-05T10:00:00.000Z',
      windows: [
        {'a@x.in': true},
        {'a@x.in': false}
      ],
      names: const {'a@x.in': 'A'},
      rolls: const {'a@x.in': '1'},
    );
    // Unsorted input on purpose: the builder sorts columns by timestamp,
    // keys rows by email, and marks intersection-present P else A.
    expect(
      buildDateRangeMatrix([s2, s1]),
      'Name,ID Number,Email,2026-09-04,2026-09-05\n'
      'A,1,a@x.in,P,A\n'
      'B,2,b@x.in,P,A\n',
    );
  });

  testWidgets('overview is records-only with hold-and-tap delete', (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await store.appendHistory(ClassRecord(
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-03',
      w1: const {'a@x.in': true},
      w2: const {'a@x.in': false},
      names: const {'a@x.in': 'A'},
      rolls: const {'a@x.in': '1'},
    ));
    await t.pumpWidget(_wrap(
        store: store,
        cloud: FakeCloudSync(),
        home: const CourseOverviewScreen(courseName: 'CS201')));
    await t.pumpAndSettle();
    // Negative UI check: no hosting entry, no LIVE chip, no checkboxes.
    expect(find.text('Take attendance'), findsNothing);
    expect(find.byTooltip('Retake attendance'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.textContaining('LIVE'), findsNothing);
    expect(find.text('Review & export'), findsOneWidget);
    // Counts line: rounds + icon counts (✓ ✗) + `N partial` word.
    expect(find.textContaining('1 partial'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('Total students: 0'), findsOneWidget);
    // Tap still opens the session detail.
    await t.tap(find.textContaining('Thu, 03-09-26'));
    await t.pumpAndSettle();
    expect(find.text('Session'), findsOneWidget);
    // Navigation identity (records packet): the auto-id session shares the
    // `prof/courses/<course>` prefix, so popUntil by course still works.
    final detailName =
        ModalRoute.of(t.element(find.byType(SessionDetailScreen)))
            ?.settings
            .name;
    expect(detailName?.startsWith('prof/courses/CS201/sessions/'), isTrue);
    await t.pageBack();
    await t.pumpAndSettle();
    // Hold-and-tap selects; Cancel exits selection mode.
    await t.longPress(find.textContaining('Thu, 03-09-26'));
    await t.pumpAndSettle();
    expect(find.text('Delete 1'), findsOneWidget);
    await t.tap(find.byTooltip('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('Delete 1'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('overview hold-and-tap exports selected dates', (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    for (final day in ['2026-09-03', '2026-09-04']) {
      await store.appendHistory(ClassRecord(
        courseId: 'CS201',
        classLabel: 'CS201',
        dateIso: day,
        w1: const {'a@x.in': true},
        names: const {'a@x.in': 'A'},
        rolls: const {'a@x.in': '1'},
      ));
    }
    await t.pumpWidget(_wrap(
        store: store,
        cloud: FakeCloudSync(),
        home: const CourseOverviewScreen(courseName: 'CS201')));
    await t.pumpAndSettle();
    // Hold selects one date: same toolbar hosts Export + Delete.
    await t.longPress(find.textContaining('Thu, 03-09-26'));
    await t.pumpAndSettle();
    expect(find.text('Export 1'), findsOneWidget);
    expect(find.text('Delete 1'), findsOneWidget);
    // Export opens the shared preview (Close + Save + Share); Close
    // dismisses cleanly and selection stays armed. (The preview title
    // reuses the session label, so assert the dialog-only actions.
    // Toolbar actions scroll horizontally — bring Export into view.)
    await t.scrollUntilVisible(
      find.text('Export 1'),
      200,
      scrollable: find.descendant(
        of: find.byType(SelectionToolbar),
        matching: find.byType(Scrollable),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Export 1'));
    await t.pumpAndSettle();
    expect(find.text('Close'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    expect(find.text('Close'), findsNothing);
    expect(find.text('Delete 1'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('overview badges show per-session present totals', (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    // Single-window: confirmed == window, so 2 present, no partial.
    await store.appendHistory(ClassRecord(
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-03',
      w1: const {'a@x.in': true, 'b@x.in': true},
      names: const {'a@x.in': 'A', 'b@x.in': 'B'},
      rolls: const {'a@x.in': '1', 'b@x.in': '2'},
    ));
    await store.appendHistory(ClassRecord(
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-04',
      w1: const {'c@x.in': true},
      names: const {'c@x.in': 'C'},
      rolls: const {'c@x.in': '3'},
    ));
    await t.pumpWidget(_wrap(
        store: store,
        cloud: FakeCloudSync(),
        home: const CourseOverviewScreen(courseName: 'CS201')));
    await t.pumpAndSettle();
    // Attendance % per row (union roster {a,b,c} = 3: 2/3 and 1/3);
    // the share bars below carry the counts.
    expect(find.text('67%'), findsOneWidget);
    expect(find.text('33%'), findsOneWidget);
    // Union of confirmed-present across sessions: {a,b,c} = 3.
    expect(find.text('Total students: 3'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('overview Total Students unions repeat attendees, 0 when empty',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    // Overlap on b: sum would be 4, union is 3 (a,b,c).
    await store.appendHistory(ClassRecord(
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-03',
      w1: const {'a@x.in': true, 'b@x.in': true},
      names: const {'a@x.in': 'A', 'b@x.in': 'B'},
      rolls: const {'a@x.in': '1', 'b@x.in': '2'},
    ));
    await store.appendHistory(ClassRecord(
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-04',
      w1: const {'b@x.in': true, 'c@x.in': true},
      names: const {'b@x.in': 'B', 'c@x.in': 'C'},
      rolls: const {'b@x.in': '2', 'c@x.in': '3'},
    ));
    await t.pumpWidget(_wrap(
        store: store,
        cloud: FakeCloudSync(),
        home: const CourseOverviewScreen(courseName: 'CS201')));
    await t.pumpAndSettle();
    expect(find.text('Total students: 3'), findsOneWidget);
    expect(find.text('Total students: 4'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('overview Total Students is 0 when empty', (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await t.pumpWidget(_wrap(
        store: store,
        cloud: FakeCloudSync(),
        home: const CourseOverviewScreen(courseName: 'CS201')));
    await t.pumpAndSettle();
    expect(find.text('Total students: 0'), findsOneWidget);
    expect(find.text('No sessions yet for this course.'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
