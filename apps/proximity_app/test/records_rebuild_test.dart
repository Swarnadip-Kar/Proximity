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
import 'package:proximity_app/features/records/course_overview_screen.dart';
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
    expect(find.textContaining('Partial (1)'), findsOneWidget);
    // Tap still opens the session detail.
    await t.tap(find.textContaining('Thu, 3 Sep'));
    await t.pumpAndSettle();
    expect(find.text('Session'), findsOneWidget);
    await t.pageBack();
    await t.pumpAndSettle();
    // Hold-and-tap selects; Cancel exits selection mode.
    await t.longPress(find.textContaining('Thu, 3 Sep'));
    await t.pumpAndSettle();
    expect(find.text('Delete 1'), findsOneWidget);
    await t.tap(find.byTooltip('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('Delete 1'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
