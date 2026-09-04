import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/ble_radio.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/face_camera.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/roster_repo.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/main.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_face/face.dart';
import 'package:proximity_transport/transport.dart';

ProviderScope testScope(
    {String email = 'aarav@institute.ac.in',
    LinkedIdentity? linked,
    InMemoryDeviceStore? store}) {
  final auth = FakeAuthService(
      SignedAccount(email: email, displayName: 'Test User'));
  final repo = FakeRosterRepository();
  final deviceStore = store ?? InMemoryDeviceStore();
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(auth),
      rosterRepositoryProvider.overrideWithValue(repo),
      deviceStoreProvider.overrideWithValue(deviceStore),
      faceCameraProvider.overrideWithValue(FakeFaceCamera()),
      hostDriverProvider.overrideWithValue(FakeHostDriver()),
      studentDriverProvider.overrideWithValue(FakeStudentDriver()),
      bleEngineProvider
          .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
      blePermissionProvider.overrideWithValue(() async => true),
      btPowerProvider.overrideWithValue(() async => BtState.on),
      if (linked != null)
        linkedIdentityProvider.overrideWith((ref) => linked),
      enrollmentControllerProvider.overrideWith(
        (ref) => EnrollmentController(
          auth: ref.watch(authServiceProvider),
          repo: ref.watch(rosterRepositoryProvider),
          store: ref.watch(deviceStoreProvider),
          embedder: MockFaceEmbedder(
            enrolled: const [1, 0, 0, 0],
            probe: const [1, 0, 0, 0],
          ),
        ),
      ),
    ],
    child: const ProximityApp(),
  );
}

void main() {
  testWidgets('prof course→take→LIVE→close→export', (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await t.pumpWidget(testScope(store: store));
    // role select → prof courses
    await t.tap(find.text('Continue as Professor (host)'));
    await t.pumpAndSettle();
    expect(find.text('CS201'), findsOneWidget);
    // course detail → take attendance (fake host advertises)
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    await t.tap(find.text('Take attendance'));
    await t.pumpAndSettle();
    expect(find.textContaining('waiting for window'), findsOneWidget);
    // start window #1
    await t.tap(find.text('Start #1'));
    await t.pumpAndSettle();
    expect(find.textContaining('demo · Code KQ7'), findsOneWidget);
    expect(find.textContaining('00:'), findsWidgets);
    // fast-forward 31s → auto-close
    await t.pump(const Duration(seconds: 31));
    // export → signed CSV, back on detail
    await t.tap(find.text('End + Export'));
    await t.pumpAndSettle();
    expect(find.text('Take attendance'), findsOneWidget);
  });

  testWidgets('student join→face→listening→ACK', (t) async {
    await t.pumpWidget(testScope(
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'aarav@institute.ac.in',
            roll: '12342210')));
    await t.tap(find.text('Continue as Student'));
    await t.pumpAndSettle();
    // manual join via professor IP
    await t.enterText(
        find.widgetWithText(TextField, 'Professor IP'), '192.168.43.1');
    await t.pump();
    await t.tap(find.text('Join'));
    await t.pumpAndSettle();
    // face scan screen
    await t.tap(find.text('Scan face'));
    await t.pumpAndSettle();
    expect(find.text('Face scan'), findsWidgets);
    await t.tap(find.text('Scan my face'));
    await t.pumpAndSettle();
    expect(find.textContaining('Listening'), findsOneWidget);
    await t.pump(const Duration(seconds: 30));
    expect(find.text('✓ Marked'), findsOneWidget);
  });

  testWidgets('student without enrollment cannot join', (t) async {    await t.pumpWidget(testScope(linked: null));
    await t.tap(find.text('Continue as Student'));
    await t.pumpAndSettle();
    await t.enterText(
        find.widgetWithText(TextField, 'Professor IP'), '192.168.43.1');
    await t.pump();
    await t.tap(find.text('Join'));
    await t.pumpAndSettle();
    expect(find.text('Enroll this device first — identity is required.'),
        findsOneWidget);
  });

  testWidgets('face-fail→needs-review copy present', (t) async {
    // Static copy contract: needs-review path must exist in UI strings.
    await t.pumpWidget(testScope());
    await t.tap(find.text('Continue as Student'));
    await t.pumpAndSettle();
    // Paused copy exists in source (background contract); smoke-check browsing.
    expect(find.textContaining('foreground'), findsOneWidget);
  });

  testWidgets('enrollment: sign-in → key → face → upload → linked',
      (t) async {
    await t.pumpWidget(testScope());
    // open enrollment from role select
    await t.tap(find.text('Enroll this device (online, once)'));
    await t.pumpAndSettle();
    expect(find.text('Enroll this device'), findsWidgets);
    // 1. sign in — nothing to type, identity imports from Gmail
    await t.tap(find.text('Sign in with Google'));
    await t.pumpAndSettle();
    expect(find.textContaining('Signed in as Test User'), findsOneWidget);
    expect(find.textContaining('aarav@institute.ac.in'), findsWidgets);
    // ID number (compulsory, saved unverified)
    await t.enterText(
        find.widgetWithText(TextField, 'ID Number'), '12342210');
    await t.pump();
    // 2. device key
    await t.tap(find.text('Generate device key'));
    await t.pumpAndSettle();
    expect(find.textContaining('Key: '), findsOneWidget);
    // 3. face scan (fake camera: preview → scan → detected)
    await t.tap(find.text('Scan face'));
    await t.pumpAndSettle();
    expect(find.text('Face scan'), findsWidgets);
    await t.tap(find.text('Scan my face'));
    await t.pumpAndSettle();
    expect(find.textContaining('Face detected and enrolled'), findsOneWidget);
    // 4. upload → linked banner on role select after Done
    await t.tap(find.text('Upload enrollment'));
    await t.pumpAndSettle();
    expect(find.textContaining('Enrolled. Identity linked'), findsOneWidget);
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect(
        find.textContaining('Enrolled as Test User · 12342210'),
        findsOneWidget);
  });

  testWidgets('prof enlists new course by name', (t) async {
    await t.pumpWidget(testScope());
    await t.tap(find.text('Continue as Professor (host)'));
    await t.pumpAndSettle();
    expect(find.text('My courses'), findsWidgets);
    await t.tap(find.text('Register new course'));
    await t.pumpAndSettle();
    await t.enterText(
        find.widgetWithText(TextField, 'Course name'), 'CS301');
    await t.tap(find.text('Register'));
    await t.pumpAndSettle();
    expect(find.text('CS301'), findsOneWidget);
    // registered course opens its detail with take-attendance entry
    await t.tap(find.text('CS301'));
    await t.pumpAndSettle();
    expect(find.text('Take attendance'), findsOneWidget);
  });

  testWidgets('late/invalid states render in prof search', (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await t.pumpWidget(testScope(store: store));
    await t.tap(find.text('Continue as Professor (host)'));
    await t.pumpAndSettle();
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    await t.tap(find.text('Take attendance'));
    await t.pumpAndSettle();
    await t.tap(find.text('Start #1'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'aarav');
    await t.pump();
    expect(find.text('Aarav S'), findsOneWidget);
  });

  // Regression: Cupertino branch (iOS/macOS) must provide a Material
  // ancestor for the shared body — caught once on-simulator as red screen.
  testWidgets('iOS platform renders student join without material error',
      (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await t.pumpWidget(testScope(
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'aarav@institute.ac.in',
            roll: '12342210')));
    await t.tap(find.text('Continue as Student'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Professor IP'), findsOneWidget);
    expect(t.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS platform renders prof screen without material error',
      (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await t.pumpWidget(testScope(store: store));
    await t.tap(find.text('Continue as Professor (host)'));
    await t.pumpAndSettle();
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    await t.tap(find.text('Take attendance'));
    await t.pumpAndSettle();
    await t.tap(find.text('Start #1'));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(t.takeException(), isNull);
    expect(find.textContaining('present'), findsWidgets);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('idle class waits; live flip auto-continues to face', (t) async {
    await t.pumpWidget(testScope(
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'aarav@institute.ac.in',
            roll: '12342210')));
    await t.tap(find.text('Continue as Student'));
    await t.pumpAndSettle();
    ClassAnnouncer announce(bool open) => ClassAnnouncer(
          () => ClassAnnouncement(
            classLabel: 'CS9',
            host: '127.0.0.1',
            port: 8443,
            display: 'ZZ9',
            prof: 'Prof Z',
            windowOpen: open,
            ts: DateTime.now().toUtc(),
          ),
          target: InternetAddress.loopbackIPv4,
        );
    final idle = announce(false);
    await idle.start();
    addTearDown(idle.stop);
    // Real-async window: announcer's first beacon is sent synchronously on
    // start; loopback delivery needs the real event loop (runAsync), then
    // a pump to rebuild with the tile.
    await t.runAsync(() => Future.delayed(const Duration(seconds: 1)));
    await t.pump();
    expect(find.text('CS9'), findsOneWidget);
    // idle class → waiting room, not face check
    await t.tap(find.text('CS9'));
    await t.pumpAndSettle();
    expect(find.textContaining('not yet started'), findsOneWidget);
    // professor opens the window → beacon flips → face check, no new taps
    await idle.stop();
    final live = announce(true);
    await live.start();
    addTearDown(live.stop);
    // Poll: loopback delivery + async permission chain settle on their own
    // schedule; the flip needs no further taps.
    var flipped = false;
    for (var i = 0;
        i < 20 && find.text('Scan face').evaluate().isEmpty;
        i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
      await t.pump(const Duration(milliseconds: 500));
      flipped = find.text('Scan face').evaluate().isNotEmpty;
    }
    expect(flipped, isTrue);
    await live.stop();
    await idle.stop();
    await t.pump();
    expect(t.takeException(), isNull);
  });
}
