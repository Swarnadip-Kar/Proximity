// Courses-tab crash regression (student shell + Courses content).
//
// Guards the reported real-device symptom: tapping the Courses tab in
// student mode shows a red error screen
// (`framework.dart: Failed assertion '_elements.contains(element)'`,
// i.e. a GlobalKey retake against a parentless/inactive bookkeeping
// entry — the tab Navigators/PageView/KeepAlives + course-card list
// churn around it).
//
// Device-pattern coverage in one enrolled shell: seeded synced sessions
// (multiple courses, present + absent), cached prof photo + account
// photo, Courses open, course drill-down + back, per-course delete with
// confirm, and Mark↔Courses swipes — with a per-pump exception check so
// even a transient red frame fails the test. Also pins Courses scroll
// preservation across tab switches (keep-alive intact).
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
import 'package:proximity_app/features/records/course_attendance_detail_screen.dart';
import 'package:proximity_app/features/records/my_attendance_screen.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_app/screens/student_home.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

const _linked = LinkedIdentity(
    name: 'Test User', gmail: 'student@example.com', roll: 'R1');

void _check(WidgetTester t, String where) {
  final e = t.takeException();
  expect(e, isNull, reason: 'exception during $where: $e');
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  _check(t, 'settle-pump');
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 500));
    _check(t, 'settle-step$i');
  }
}

Finder _coursesTab() => find.descendant(
      of: find.byKey(const ValueKey('shell-bar')),
      matching: find.text('Courses'),
    );

Future<void> _pumpEnrolledShell(
  WidgetTester t, {
  FakeCloudSync? cloud,
  DeviceStore? store,
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
            email: 'student@example.com',
            displayName: 'Test User',
            uid: 'test-uid',
            photoUrl: 'https://example.com/me.jpg'))),
        cloudSyncProvider.overrideWithValue(cloud ?? FakeCloudSync()),
        deviceStoreProvider.overrideWithValue(store ?? InMemoryDeviceStore()),
        faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
        deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
        hostDriverProvider.overrideWithValue(FakeHostDriver()),
        studentDriverProvider
            .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
        bleEngineProvider.overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        btPowerProvider.overrideWithValue(() async => BtState.on),
        linkedIdentityProvider.overrideWith((ref) => _linked),
        enrollmentControllerProvider.overrideWith(
          (ref) => EnrollmentController(
            auth: ref.watch(authServiceProvider),
            store: ref.watch(deviceStoreProvider),
            verifier: FakeFaceVerifier(),
            deviceKey: FakeDeviceKey(),
          ),
        ),
      ],
      child: MaterialApp(theme: proxLightTheme(), home: const StudentShell()),
    ),
  );
  await _settle(t);
  _check(t, 'mount');
}

void main() {
  group('courses crash regression (student shell)', () {
    testWidgets('Courses opens clean with synced data, no element errors',
        (t) async {
      final cloud = FakeCloudSync();
      for (var k = 0; k < 10; k++) {
        final course = 'CS${201 + (k % 4)}';
        await cloud.pushSession(
          profUid: 'p1',
          profEmail: 'prof@example.com',
          profName: 'Prof',
          record: ClassRecord(
            courseId: course,
            classLabel: course,
            dateIso: '2026-09-${(4 + k).toString().padLeft(2, '0')}',
            timestampIso:
                '2026-09-${(4 + k).toString().padLeft(2, '0')}T10:00:00.000Z',
            windows: [
              {'student@example.com': k.isEven}
            ],
            names: const {'student@example.com': 'Test User'},
            rolls: const {'student@example.com': 'R1'},
            // Fresh-cloud fixture: production saves always stamp org.
            org: 'example.com',
          ),
        );
      }
      final store = InMemoryDeviceStore();
      await store.writeCourseProfPhoto('CS201', 'https://example.com/p.jpg');
      await _pumpEnrolledShell(t, cloud: cloud, store: store);
      expect(find.byType(StudentHomeScreen), findsOneWidget);

      // Open Courses through the page animation, checking every frame.
      await t.tap(_coursesTab());
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 60));
        _check(t, 'courses-anim-$i');
      }
      await _settle(t);
      _check(t, 'after-courses');
      expect(find.byType(MyAttendanceScreen), findsOneWidget);
      expect(find.text('CS201'), findsWidgets);

      // Drill into a course and back (detail push/pop on the tab nav).
      await t.tap(find.text('CS201').first);
      await _settle(t);
      _check(t, 'after-drill');
      // Navigation identity (records packet): one named route per screen.
      expect(
          ModalRoute.of(t.element(find.byType(CourseAttendanceDetailScreen)))
              ?.settings
              .name,
          'records/mine/CS201');
      await t.pageBack();
      await _settle(t);
      _check(t, 'after-back');
      expect(find.byType(MyAttendanceScreen), findsOneWidget);

      // Per-course delete with confirm dialog + snackbar.
      await t.tap(find.byTooltip('Remove course from this device').first);
      await _settle(t);
      _check(t, 'after-delete-tap');
      await t.tap(find.text('Remove'));
      await _settle(t);
      _check(t, 'after-delete-confirm');

      // Swipe away and back; Courses keeps its scroll offset (keep-alive).
      final list = find.descendant(
        of: find.byType(MyAttendanceScreen),
        matching: find.byType(ListView),
      );
      double listOffset() => t
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)),
          )
          .position
          .pixels;
      final pages = find.byType(PageView);
      await t.fling(list, const Offset(0, -300), 800);
      await _settle(t);
      _check(t, 'after-fling');
      final scrolled = listOffset();
      await t.fling(pages, const Offset(400, 0), 800);
      await _settle(t);
      _check(t, 'after-swipe-mark');
      expect(find.byType(StudentHomeScreen), findsOneWidget);
      await t.fling(pages, const Offset(-400, 0), 800);
      await _settle(t);
      _check(t, 'after-swipe-courses');
      expect(find.byType(MyAttendanceScreen), findsOneWidget);
      expect(listOffset(), moreOrLessEquals(scrolled, epsilon: 1));
    });
  });
}
