// Live courses bug regression: professor registers a course (Courses tab
// write path) but the LIVE tab shows no courses.
// Root-cause target: _LiveRoot in lib/screens/shells.dart caches
// `readCourses()` once in initState, so post-registration courses never
// appear (IndexedStack keeps the state alive; tab switches only rebuild,
// never re-read).
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
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_ble/ble.dart';

Widget _profShellApp(InMemoryDeviceStore store) {
  return ProviderScope(
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
      bleEngineProvider.overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
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
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _openTab(WidgetTester t, String label) async {
  // Tap the tab-bar label itself (not the bar center): center-tap only
  // ever hits the middle tab.
  final labelInBar = find.descendant(
    of: find.byType(BottomNavigationBar),
    matching: find.text(label),
  );
  expect(labelInBar, findsOneWidget, reason: 'tab $label exists in bar');
  await t.tap(labelInBar);
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  testWidgets('register course → Live tab lists it', (t) async {
    final store = InMemoryDeviceStore();
    await t.pumpWidget(_profShellApp(store));
    await _settle(t);

    // Starts empty: honest empty state only.
    expect(find.text('Go to Courses'), findsOneWidget);

    // Professor registers a course via the SAME write path the Courses tab
    // uses (store.addCourse).
    await store.addCourse('CS201');

    // Revisit the Live tab (Courses → Live) — the list must refresh.
    await _openTab(t, 'Courses');
    await _openTab(t, 'Live');

    expect(find.text('CS201'), findsOneWidget,
        reason:
            'Live tab must list the newly registered course after tab revisit');
    expect(find.text('Go to Courses'), findsNothing,
        reason: 'empty state must clear once a course exists');
  });

  testWidgets('empty state only when truly no courses', (t) async {
    final store = InMemoryDeviceStore();
    await t.pumpWidget(_profShellApp(store));
    await _settle(t);

    expect(find.text('Go to Courses'), findsOneWidget);
    expect(find.textContaining('No courses yet'), findsOneWidget);
  });
}
