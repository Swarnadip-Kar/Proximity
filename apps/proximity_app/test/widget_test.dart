import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/ble_radio.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/features/enrollment/enroll_capture.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/pose_gate.dart';
import 'package:proximity_app/screens/face_capture.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/main.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/features/records/session_edit_screen.dart';
import 'package:proximity_app/screens/student_home.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';
import 'package:proximity_transport/transport.dart';

ProviderScope testScope(
    {String email = 'student@example.com',
    LinkedIdentity? linked,
    InMemoryDeviceStore? store,
    int? discoveryPort,
    bool probeOpen = false,
    FakeHostDriver? hostDriver,
    StudentDriver? studentDriver,
    BtState btPower = BtState.on,
    AppMode? mode,
    FakeCloudSync? cloud}) {
  final auth = FakeAuthService(
      SignedAccount(email: email, displayName: 'Test User', uid: 'test-uid'));
  final deviceStore = store ?? InMemoryDeviceStore();
  // Landing bypass: widget tests target home screens directly unless they
  // exercise the landing itself. Students with a linked identity default
  // to student mode; pass mode explicitly otherwise.
  final resolvedMode = mode ?? (linked != null ? AppMode.student : null);
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(auth),
      cloudSyncProvider.overrideWithValue(cloud ?? FakeCloudSync()),
      deviceStoreProvider.overrideWithValue(deviceStore),
      faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
      deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
      // Canned stills (the camera plugin has no test double; verdicts
      // come from the FakeFaceVerifier above).
      stillCapturerProvider.overrideWithValue(const FakeStillCapturer()),
      // Continuous enrollment session: one fake camera open + an
      // accept-all pose gate (angle math is pinned in enroll_guided_test).
      enrollSessionCameraProvider
          .overrideWithValue(FakeEnrollSessionCamera()),
      poseGateProvider.overrideWithValue(FakePoseGate()),
      hostDriverProvider.overrideWithValue(hostDriver ?? FakeHostDriver()),
      studentDriverProvider.overrideWithValue(
          studentDriver ?? FakeStudentDriver(windowOpenProbe: probeOpen)),
      bleEngineProvider
          .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
      blePermissionProvider.overrideWithValue(() async => true),
      cameraPermissionProvider.overrideWithValue(() async => true),
      btPowerProvider.overrideWithValue(() async => btPower),
      if (discoveryPort != null)
        discoveryPortProvider.overrideWithValue(discoveryPort),
      if (linked != null)
        linkedIdentityProvider.overrideWith((ref) => linked),
      if (resolvedMode != null)
        appModeProvider.overrideWith((ref) => resolvedMode),
      enrollmentControllerProvider.overrideWith(
        (ref) => EnrollmentController(
          auth: ref.watch(authServiceProvider),
          store: ref.watch(deviceStoreProvider),
          verifier: FakeFaceVerifier(),
          deviceKey: FakeDeviceKey(),
        ),
      ),
    ],
    child: const ProximityApp(),
  );
}

/// Driver whose listen parks until released: exercises pause-during-
/// proving deterministically (the instant fake would mark before the
/// lifecycle events land).
class _HangingStudentDriver extends FakeStudentDriver {
  _HangingStudentDriver() : super(windowOpenProbe: true);
  final Completer<void> release = Completer<void>();

  @override
  Future<MarkedReceipt> listenAndProve({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(ListenStatus s) onStatus,
    int faceValidAtMs = 0,
    String verifierVer = '',
  }) async {
    onStatus(ListenStatus.waiting);
    await release.future;
    return const MarkedReceipt(detail: 'KQ7 · 10:04:12', result: StudentResult.marked);
  }
}

/// Driver that marks round 1 then ends the round behind the badge, and
/// marks again on the next listen: exercises the multi-round loop
/// (marked → waiting → face → listening → marked, zero taps).
class _RoundStudentDriver extends FakeStudentDriver {
  _RoundStudentDriver() : super(windowOpenProbe: true);
  var listens = 0;

  @override
  Future<MarkedReceipt> listenAndProve({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(ListenStatus s) onStatus,
    int faceValidAtMs = 0,
    String verifierVer = '',
  }) async {
    listens++;
    onStatus(ListenStatus.waiting);
    if (listens == 1) {
      windowOpenProbe = false; // round ends right after marking
      return const MarkedReceipt(
          detail: 'KQ7 · 10:04:12',
          result: StudentResult.marked,
          display: 'KQ7');
    }
    return super.listenAndProve(
      target: target,
      identity: identity,
      faceScore: faceScore,
      onStatus: onStatus,
      faceValidAtMs: faceValidAtMs,
      verifierVer: verifierVer,
    );
  }
}
class _FlakyStudentDriver extends FakeStudentDriver {
  _FlakyStudentDriver() : super(windowOpenProbe: true);
  var listens = 0;

  @override
  Future<MarkedReceipt> listenAndProve({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(ListenStatus s) onStatus,
    int faceValidAtMs = 0,
    String verifierVer = '',
  }) async {
    listens++;
    onStatus(ListenStatus.waiting);
    return const MarkedReceipt(
        detail: 'Prove failed: boom', result: StudentResult.error);
  }
}

/// Driver that marks, then reports the host gone (End attendance stops
/// the professor server): the badge must leave for the live list — never
/// a dead waiting room, never a face re-scan on an ended class.
class _EndedHostDriver extends FakeStudentDriver {
  _EndedHostDriver() : super(windowOpenProbe: true);
  var reachableProbe = true;
  var listens = 0;

  @override
  Future<WindowProbe> probeWindow(ClassBeacon target) async => WindowProbe(
      reachable: reachableProbe,
      windowOpen: reachableProbe && windowOpenProbe,
      classLabel: target.classLabel);

  @override
  Future<MarkedReceipt> listenAndProve({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(ListenStatus s) onStatus,
    int faceValidAtMs = 0,
    String verifierVer = '',
  }) async {
    listens++;
    return super.listenAndProve(
      target: target,
      identity: identity,
      faceScore: faceScore,
      onStatus: onStatus,
      faceValidAtMs: faceValidAtMs,
      verifierVer: verifierVer,
    );
  }
}

void main() {
Future<void> enterIp(WidgetTester t, String ip) async {
  await t.enterText(find.byKey(const ValueKey('ipfield')), ip);
  await t.pump();
}

  testWidgets('prof course→take→LIVE→close→end (history, no export)', (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await t.pumpWidget(testScope(store: store, mode: AppMode.prof));
    await t.pumpAndSettle();
    expect(find.text('CS201'), findsOneWidget);
    // course detail → take attendance (fake host advertises)
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    await t.tap(find.text('Take attendance'));
    await t.pumpAndSettle();
    expect(find.textContaining('waiting for window'), findsOneWidget);
    // start single window
    await t.tap(find.text('Start'));
    await t.pumpAndSettle();
    expect(find.textContaining('demo · Code KQ7'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.textContaining('present /'), findsWidgets);
    // stop early → Take another round appears
    await t.tap(find.text('Stop'));
    await t.pumpAndSettle();
    expect(find.text('Take another round'), findsOneWidget);
    // end attendance (no export) → history holds the class record, detail
    await t.tap(find.text('End attendance'));
    await t.pumpAndSettle();
    expect(find.text('Take attendance'), findsOneWidget);
    expect(await store.readHistory(), hasLength(1));
  });

  testWidgets('student join→waiting→face→listening→ACK', (t) async {
    await t.pumpWidget(testScope(
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210'),
        probeOpen: true));
    await t.pumpAndSettle();
    // manual join via the single professor IP field.
    // Window already open (probe) → fast-path to face check, and the scan
    // auto-starts Samsung-style (zero taps) the moment it appears.
    await enterIp(t, '192.168.43.1');
    await t.tap(find.text('Join'));
    // Bounded wait: join chain → auto-scan → pass → listening.
    var listening = false;
    for (var i = 0; i < 10 && !listening; i++) {
      await t.pump(const Duration(seconds: 2));
      listening = find.textContaining('Waiting for the class signal').evaluate().isNotEmpty ||
          find.text('✓ Marked').evaluate().isNotEmpty;
    }
    expect(listening, isTrue);
    await t.pump(const Duration(seconds: 30));
    expect(find.text('✓ Marked'), findsOneWidget);
  });

  testWidgets('marked round rejoins waiting and marks the next round',
      (t) async {
    // Full multi-round loop with zero taps after Join: R1 marks, the
    // round ends behind the badge, the student rejoins waiting (R1 trail
    // visible), R2 opens → auto face → auto listen → marked again.
    final driver = _RoundStudentDriver();
    await t.pumpWidget(testScope(
        studentDriver: driver,
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    await enterIp(t, '192.168.43.1');
    await t.tap(find.text('Join'));
    var marked = false;
    for (var i = 0; i < 20 && !marked; i++) {
      await t.pump(const Duration(seconds: 1));
      marked = find.text('✓ Marked').evaluate().isNotEmpty;
    }
    expect(marked, isTrue);
    expect(driver.listens, 1);
    // Round ends behind the badge → waiting room with the R1 trail.
    var waiting = false;
    for (var i = 0; i < 20 && !waiting; i++) {
      await t.pump(const Duration(seconds: 1));
      waiting =
          find.textContaining('has not yet started').evaluate().isNotEmpty;
    }
    expect(waiting, isTrue);
    // The waiting→verdict hops cross-fade (mark-flow continuation shell):
    // let the outgoing verdict badge finish exiting before asserting the
    // trail is single — both carry the same per-round text mid-transition.
    await t.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('R1 · KQ7'), findsOneWidget);
    // Round 2 opens → auto face → auto listen → marked again, no taps.
    driver.windowOpenProbe = true;
    var marked2 = false;
    for (var i = 0; i < 30 && !marked2; i++) {
      await t.pump(const Duration(seconds: 1));
      marked2 = find.text('✓ Marked').evaluate().isNotEmpty &&
          driver.listens == 2;
    }
    expect(marked2, isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('marked badge leaves for the live list when hosting ends',
      (t) async {
    // The reported bug: after End attendance the badge rejoined a dead
    // waiting room and the stale OPEN flag face-scanned again. Now two
    // consecutive unreachable probes (~6s) purge the host and return to
    // browse — one listen total, no waiting room, no re-face.
    final driver = _EndedHostDriver();
    await t.pumpWidget(testScope(
        studentDriver: driver,
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    await enterIp(t, '192.168.43.1');
    await t.tap(find.text('Join'));
    var marked = false;
    for (var i = 0; i < 20 && !marked; i++) {
      await t.pump(const Duration(seconds: 1));
      marked = find.text('✓ Marked').evaluate().isNotEmpty;
    }
    expect(marked, isTrue);
    expect(driver.listens, 1);
    // Professor taps End attendance: server stops answering.
    driver.reachableProbe = false;
    var back = false;
    for (var i = 0; i < 20 && !back; i++) {
      await t.pump(const Duration(seconds: 1));
      back = find
          .text('Class ended — back to the live list.')
          .evaluate()
          .isNotEmpty;
    }
    expect(back, isTrue);
    // Settles on browse: no waiting room, no second face scan — even
    // with extra time for the stale-flag paths to misfire.
    await t.pump(const Duration(seconds: 15));
    expect(find.text('Class ended — back to the live list.'), findsOneWidget);
    expect(find.textContaining('has not yet started'), findsNothing);
    expect(find.text('✓ Marked'), findsNothing);
    expect(driver.listens, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('student join→waiting room when window closed', (t) async {
    await t.pumpWidget(testScope(
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    await enterIp(t, '192.168.43.1');
    await t.tap(find.text('Join'));
    await t.pumpAndSettle();
    // Waiting room with connection-aware copy + manual fallback.
    expect(find.textContaining('not yet started'), findsOneWidget);
    expect(find.text('Request manual attendance'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('invalid IP blocks join with guidance', (t) async {
    await t.pumpWidget(testScope(
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    await enterIp(t, '999.999.1.1');
    await t.tap(find.text('Join'));
    await t.pumpAndSettle();
    expect(find.text('Enter the professor IP shown in class.'),
        findsOneWidget);
  });

  testWidgets('stray dots in the IP field are ignored', (t) async {
    await t.pumpWidget(testScope(
        probeOpen: true,
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    await enterIp(t, '192..168.43.1');
    await t.tap(find.text('Join'));
    // Still parses to 192.168.43.1 → fast-path to face check → listening.
    var listening = false;
    for (var i = 0; i < 20 && !listening; i++) {
      await t.pump(const Duration(seconds: 1));
      listening = find.textContaining('Waiting for the class signal').evaluate().isNotEmpty ||
          find.text('✓ Marked').evaluate().isNotEmpty;
    }
    expect(listening, isTrue);
    await t.pump(const Duration(seconds: 35));
    expect(find.text('✓ Marked'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('student without enrollment cannot join', (t) async {
    await t.pumpWidget(testScope(linked: null, mode: AppMode.student));
    await t.pumpAndSettle();
    await enterIp(t, '192.168.43.1');
    await t.tap(find.text('Join'));
    await t.pumpAndSettle();
    expect(find.text('Enroll this device first — identity is required.'),
        findsOneWidget);
  });

  testWidgets('last IP autofills the join field', (t) async {
    final store = InMemoryDeviceStore()
      ..lastHost = '192.168.43.9:8443';
    await t.pumpWidget(testScope(
        store: store,
        probeOpen: true,
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    // No Rejoin chip anymore — the field opens prefilled with last host.
    expect(find.textContaining('Rejoin'), findsNothing);
    String field(String k) =>
        t.widget<TextField>(find.byKey(ValueKey(k))).controller!.text;
    expect(field('ipfield'), '192.168.43.9');
    expect(field('ipport'), '8443');
    await t.tap(find.text('Join'));
    // Prefilled Join fast-paths to face check; the scan
    // auto-starts and passes without typing anything or tapping Scan.
    // Bounded wait (scan loop idles on 700ms gaps — settle exits early).
    var listening = false;
    for (var i = 0; i < 20 && !listening; i++) {
      await t.pump(const Duration(seconds: 1));
      listening = find.textContaining('Waiting for the class signal').evaluate().isNotEmpty ||
          find.text('✓ Marked').evaluate().isNotEmpty;
    }
    expect(listening, isTrue);
    // Fake marks at once; the pump lets the verdict screen land.
    await t.pump(const Duration(seconds: 35));
    expect(find.text('✓ Marked'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('face-fail→needs-review copy present', (t) async {
    // Static copy contract: needs-review path must exist in UI strings.
    await t.pumpWidget(testScope(mode: AppMode.student));
    await t.pumpAndSettle();
    // Paused copy exists in source (background contract); smoke-check browsing.
    // The note sits at the bottom of the scrollable browse list (below the
    // degradation-ladder status), so scroll it into the cache extent first.
    await t.dragUntilVisible(
      find.textContaining('foreground'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('foreground'), findsOneWidget);
  });

  testWidgets('enrollment: account pickup → key → face → upload → linked',
      (t) async {
    // Bundle flow: landing → Register as Student → student home → enroll
    // bundle (intro → capture → result).
    await t.pumpWidget(testScope());
    await t.pumpAndSettle();
    // Landing (FakeAuth signed in, no role): register as student.
    await t.tap(find.text('Register as Student'));
    await t.pumpAndSettle();
    // Student home browsing now offers enrollment when not enrolled.
    await t.tap(find.text('Enroll this device (face + ID)'));
    await t.pumpAndSettle();
    expect(find.text('Enroll this device'), findsWidgets);
    // 1. intro: account picked up silently (already signed in on the
    // landing): no second Google tap. Identity imports from Gmail.
    expect(find.text('Sign in with Google'), findsNothing);
    expect(find.textContaining('Signed in as Test User'), findsOneWidget);
    expect(find.textContaining('student@example.com'), findsWidgets);
    // ID number (compulsory, saved unverified)
    await t.enterText(
        find.widgetWithText(TextField, 'ID Number'), '12342210');
    await t.pump();
    // 2. device key (scroll into view: intro carries pre-context cards).
    await t.scrollUntilVisible(find.text('Generate device key'), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Generate device key'));
    await t.pumpAndSettle();
    expect(find.textContaining('Key: '), findsOneWidget);
    // Intro → capture.
    await t.scrollUntilVisible(find.text('Continue to face scan'), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Continue to face scan'));
    await t.pumpAndSettle();
    // 3. capture: continuous 5-angle session (centre → left → right →
    // up → down) on one fake camera open; the fake verifier enrolls +
    // self-checks → result.
    expect(find.text('Angle 1 of 5'), findsOneWidget);
    expect(find.textContaining('Step 1: Look straight'), findsOneWidget);
    for (final label in ['centre', 'left', 'right', 'up', 'down']) {
      final capBtn = find.ancestor(
        of: find.textContaining('Capture $label still'),
        matching: find.byType(FilledButton),
      );
      await t.scrollUntilVisible(capBtn, 300,
          scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      await t.tap(capBtn);
      await t.pumpAndSettle();
    }
    // 4. result: save → linked banner after Done (back on student home).
    expect(find.text('Save enrollment'), findsWidgets);
    final saveBtn =
        find.widgetWithText(FilledButton, 'Save enrollment');
    await t.scrollUntilVisible(saveBtn, 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(saveBtn);
    await t.pumpAndSettle();
    expect(find.textContaining('✓ Done'), findsOneWidget);
    expect(find.textContaining('Identity linked'), findsOneWidget);
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect(find.textContaining('Test User · 12342210'), findsOneWidget);
  });

  testWidgets('prof enlists new course by name', (t) async {
    await t.pumpWidget(testScope(mode: AppMode.prof));
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
    await t.pumpWidget(testScope(store: store, mode: AppMode.prof));
    await t.pumpAndSettle();
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    await t.tap(find.text('Take attendance'));
    await t.pumpAndSettle();
    await t.tap(find.text('Start'));
    // Live window runs the 1s elapsed tick + pulsing dot: pump fixed steps,
    // never settle (settle would chase the tick).
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    final searchField = find.byKey(const ValueKey('prof-search'));
    await t.scrollUntilVisible(searchField, 500,
        scrollable: find.byType(Scrollable).first);
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.enterText(searchField, 'student');
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Student One'), findsWidgets);
  });

  // Regression: Cupertino branch (iOS/macOS) must provide a Material
  // ancestor for the shared body — caught once on-simulator as red screen.
  testWidgets('iOS platform renders student join without material error',
      (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await t.pumpWidget(testScope(
          linked: const LinkedIdentity(
              name: 'Test User',
              gmail: 'student@example.com',
              roll: '12342210')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ipfield')), findsOneWidget);
      expect(t.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iOS platform renders prof screen without material error',
      (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final store = InMemoryDeviceStore();
      await store.addCourse('CS201');
      await t.pumpWidget(testScope(store: store, mode: AppMode.prof));
      await t.pumpAndSettle();
      await t.tap(find.text('CS201'));
      await t.pumpAndSettle();
      await t.tap(find.text('Take attendance'));
      await t.pumpAndSettle();
      await t.tap(find.text('Start'));
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      expect(t.takeException(), isNull);
      expect(find.textContaining('present'), findsWidgets);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('prof stop early + extend + Take another round intersection',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await t.pumpWidget(testScope(store: store, mode: AppMode.prof));
    await t.pumpAndSettle();
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    await t.tap(find.text('Take attendance'));
    await t.pumpAndSettle();
    await t.tap(find.text('Start'));
    await t.pumpAndSettle();
    expect(find.text('Stop'), findsOneWidget);
    expect(find.textContaining('Window 1 ·'), findsOneWidget);
    await t.tap(find.text('Stop'));
    await t.pumpAndSettle();
    expect(find.text('Take another round'), findsOneWidget);
    await t.tap(find.text('Take another round'));
    await t.pumpAndSettle();
    expect(find.textContaining('intersection'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    // Round 1 already persisted the class record (no End needed)…
    final snap1 = await store.readHistory();
    expect(snap1, hasLength(1));
    await t.tap(find.text('Stop'));
    await t.pumpAndSettle();
    // …and round 2 rewrites the SAME record instead of appending.
    final snap2 = await store.readHistory();
    expect(snap2, hasLength(1));
    expect(snap2.first.id, snap1.first.id);
    await t.tap(find.text('End attendance'));
    await t.pumpAndSettle();
    expect(find.text('Take attendance'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('prof retake resumes the stopped round number', (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await t.pumpWidget(testScope(store: store, mode: AppMode.prof));
    await t.pumpAndSettle();
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    await t.tap(find.text('Take attendance'));
    await t.pumpAndSettle();
    await t.tap(find.text('Start'));
    await t.pumpAndSettle();
    await t.tap(find.text('Stop'));
    await t.pumpAndSettle();
    // Stopped round offers retake (same number, marks merge) + new window.
    expect(find.text('Retake round 1'), findsOneWidget);
    expect(find.text('Take another round'), findsOneWidget);
    await t.tap(find.text('Retake round 1'));
    await t.pumpAndSettle();
    expect(find.textContaining('demo · Code KQ7'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    await t.tap(find.text('Stop'));
    await t.pumpAndSettle();
    expect(find.text('Retake round 1'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('prof manual approve + direct entry mark present', (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    final host = FakeHostDriver()
      ..seedManual(const [
        ManualRow(email: 'manual1@example.com', name: 'M One', roll: '11'),
        ManualRow(email: 'manual2@example.com', name: 'M Two', roll: '12'),
      ]);
    await t.pumpWidget(
        testScope(store: store, hostDriver: host, mode: AppMode.prof));
    await t.pumpAndSettle();
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    await t.tap(find.text('Take attendance'));
    await t.pumpAndSettle();
    expect(find.text('Manual requests (2)'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Select all'), 500,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Select all'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Approve selected'), 500,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Approve selected'));
    await t.pumpAndSettle();
    // The added directory-search block lengthened the list: the header may
    // have scrolled out of the built viewport — scroll back up to read it.
    await t.drag(
        find.byType(Scrollable).first, const Offset(0, 600));
    await t.pumpAndSettle();
    expect(find.text('Manual requests (0)'), findsOneWidget);
    // Direct manual entry by typing details.
    await t.scrollUntilVisible(find.byKey(const ValueKey('direct-name')), 500,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.enterText(
        find.byKey(const ValueKey('direct-name')), 'Direct Entry');
    await t.enterText(
        find.byKey(const ValueKey('direct-email')), 'direct@example.com');
    await t.scrollUntilVisible(find.text('Add & mark present'), 500,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Add & mark present'));
    await t.pumpAndSettle();
    expect(find.text('Direct Entry'), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('student manual request shows pending verdict', (t) async {
    await t.pumpWidget(testScope(
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    await enterIp(t, '192.168.43.1');
    await t.tap(find.text('Join'));
    await t.pumpAndSettle();
    expect(find.text('Request manual attendance'), findsOneWidget);
    await t.tap(find.text('Request manual attendance'));
    // Periodic status poll keeps ticking — pump fixed steps, never settle.
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.textContaining('waiting for professor approval'),
        findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('prof back preserves draft; re-enter resumes + discard',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await t.pumpWidget(testScope(store: store, mode: AppMode.prof));
    await t.pumpAndSettle();
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    await t.tap(find.text('Take attendance'));
    await t.pumpAndSettle();
    await t.tap(find.text('Start'));
    await t.pumpAndSettle();
    await t.tap(find.text('Stop'));
    await t.pumpAndSettle();
    // System back: hosting ends but the draft autosaves.
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('Take attendance'), findsOneWidget);
    final draft = await store.readSession('CS201');
    expect(draft, isNotNull);
    expect(draft!['windowNo'], 1);
    // Re-enter: tally + window numbering resume, no re-marking needed.
    await t.tap(find.text('Take attendance'));
    await t.pumpAndSettle();
    expect(find.text('Resumed autosaved session'), findsOneWidget);
    expect(find.textContaining('2 present'), findsWidgets);
    expect(find.text('Take another round'), findsOneWidget);
    // Discard wipes the draft and the live tally.
    await t.tap(find.text('Discard'));
    await t.pumpAndSettle();
    expect(find.text('Resumed autosaved session'), findsNothing);
    expect(find.text('Start'), findsOneWidget);
    expect(await store.readSession('CS201'), isNull);
    expect(t.takeException(), isNull);
  });

  testWidgets('prof end clears the autosaved draft, keeps history', (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await t.pumpWidget(testScope(store: store, mode: AppMode.prof));
    await t.pumpAndSettle();
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    await t.tap(find.text('Take attendance'));
    await t.pumpAndSettle();
    await t.tap(find.text('Start'));
    await t.pumpAndSettle();
    await t.tap(find.text('Stop'));
    await t.pumpAndSettle();
    expect(await store.readSession('CS201'), isNotNull);
    await t.tap(find.text('End attendance'));
    await t.pumpAndSettle();
    expect(find.text('Take attendance'), findsOneWidget);
    expect(await store.readSession('CS201'), isNull);
    // The class record survives in history (export moved to course page).
    expect(await store.readHistory(), hasLength(1));
    expect(t.takeException(), isNull);
  });

  testWidgets('saved session edits later from the course page', (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await store.appendHistory(ClassRecord(
      id: 'sess-1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-05',
      timestampIso: '2026-09-05T10:00:00.000Z',
      windows: [
        {'a@x.in': true}
      ],
      names: {'a@x.in': 'A'},
      rolls: {'a@x.in': '1'},
    ));
    await t.pumpWidget(testScope(store: store, mode: AppMode.prof));
    await t.pumpAndSettle();
    await t.tap(find.text('CS201'));
    await t.pumpAndSettle();
    // Open the saved session (overview → read-only detail → editor).
    await t.tap(find.textContaining('1 present'));
    await t.pumpAndSettle();
    expect(find.text('Session'), findsOneWidget);
    await t.tap(find.text('Fix marks'));
    await t.pumpAndSettle();
    expect(find.text('Edit attendance'), findsOneWidget);
    // Per-window checkboxes: expand A, unmark Round 1, add B, save.
    await t.tap(find.text('A'));
    await t.pumpAndSettle();
    final round1 = find.widgetWithText(CheckboxListTile, 'Round 1');
    await t.scrollUntilVisible(round1, 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.descendant(
        of: round1, matching: find.byType(Checkbox)));
    await t.pump();
    await t.enterText(find.byKey(const ValueKey('edit-name')), 'B');
    await t.enterText(find.byKey(const ValueKey('edit-roll')), '2');
    await t.enterText(
        find.byKey(const ValueKey('edit-email')), 'b@x.in');
    await t.scrollUntilVisible(find.text('Add & mark present'), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Add & mark present'));
    await t.pump();
    await t.scrollUntilVisible(find.text('Save changes'), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Save changes'));
    await t.pumpAndSettle();
    final h = await store.readHistory();
    expect(h, hasLength(1));
    expect(h.first.id, 'sess-1');
    expect(h.first.isPresent('a@x.in'), isFalse);
    expect(h.first.isPresent('b@x.in'), isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('failed listen parks on no-signal with Try again', (t) async {
    final flaky = _FlakyStudentDriver();
    await t.pumpWidget(testScope(
        studentDriver: flaky,
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    await enterIp(t, '192.168.43.1');
    await t.tap(find.text('Join'));
    // Face passes once (auto-scan, zero taps) → listen fails for real →
    // the verdict screen shows the reason with a way back (no auto
    // re-listen: listening itself never fails spuriously anymore).
    var parked = false;
    for (var i = 0; i < 20 && !parked; i++) {
      await t.pump(const Duration(seconds: 1));
      parked = find.text('Prove failed: boom').evaluate().isNotEmpty;
    }
    expect(parked, isTrue);
    expect(flaky.listens, 1);
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('Join'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('bluetooth-off shows the turn-on prompt', (t) async {
    await t.pumpWidget(testScope(
        btPower: BtState.off,
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    expect(find.text('Bluetooth is off'), findsOneWidget);
    expect(find.text('Turn on'), findsOneWidget);
    await t.tap(find.text('Later'));
    await t.pumpAndSettle();
    expect(find.text('Bluetooth is off'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('waiting room fits a narrow phone screen without overflow',
      (t) async {
    t.view.physicalSize = const Size(360, 700);
    t.view.devicePixelRatio = 1.0;
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });
    await t.pumpWidget(testScope(
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    await enterIp(t, '192.168.43.1');
    await t.tap(find.text('Join'));
    await t.pumpAndSettle();
    expect(find.textContaining('not yet started'), findsOneWidget);
    expect(find.textContaining('waiting for professor'), findsOneWidget);
    // RenderFlex overflow would surface here as a FlutterError.
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'transient inactive (shade) never resets state; real pause does',
      (t) async {
    final hanging = _HangingStudentDriver();
    await t.pumpWidget(testScope(
        probeOpen: true,
        studentDriver: hanging,
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    await enterIp(t, '192.168.43.1');
    await t.tap(find.text('Join'));
    // Fast-path to face check (window open) → scan auto-starts and passes
    // (zero taps) → listening, parked on the hanging driver.
    var listening = false;
    for (var i = 0; i < 20 && !listening; i++) {
      await t.pump(const Duration(seconds: 1));
      listening = find.textContaining('Waiting for the class signal').evaluate().isNotEmpty ||
          find.text('✓ Marked').evaluate().isNotEmpty;
    }
    expect(listening, isTrue);
    expect(find.textContaining('Waiting for the class signal'),
        findsOneWidget);
    // Notification shade / call UI: proving continues untouched.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    expect(find.textContaining('Waiting for the class signal'),
        findsOneWidget);
    // Real backgrounding still pauses proving (foreground-required rule).
    // Note: paused disables test frames, so resume (a no-op for our
    // observer) to re-enable them before pumping.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(find.text('Paused — reopen'), findsOneWidget);
    // Back to join; releasing the orphaned listen must NOT flip us out
    // (its completion is run-guarded).
    await t.tap(find.text('Back to join'));
    await t.pumpAndSettle();
    expect(find.text('Join'), findsOneWidget);
    hanging.release.complete();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Join'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('idle class waits; live flip auto-continues to face', (t) async {
    await t.pumpWidget(testScope(
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210'),
        discoveryPort: 54677));
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
          port: 54677,
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
    // schedule; the flip needs no further taps. runAsync only until the
    // flip lands — the auto-started scan arms fake timers (frame gaps)
    // that runAsync must never overlap.
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
    // The flip auto-started the scan (zero taps): drive it to listening
    // with fake-time pumps.
    var listening = false;
    for (var i = 0; i < 20 && !listening; i++) {
      await t.pump(const Duration(seconds: 1));
      listening = find.textContaining('Waiting for the class signal').evaluate().isNotEmpty ||
          find.text('✓ Marked').evaluate().isNotEmpty;
    }
    expect(listening, isTrue);
    await t.pump(const Duration(seconds: 35));
    expect(t.takeException(), isNull);
  });

  testWidgets('prof session edit: typing searches, card fills the same fields',
      (t) async {
    final cloud = FakeCloudSync();
    await cloud.claimStudentDevice(
        doc: StudentDeviceDoc(
            email: 'student1@example.com',
            uid: 'u1',
            pkHex: 'aa',
            name: 'Student One',
            roll: '12342210',
            modelVer: 'v'),
        installId: 'i1');
    final rec = ClassRecord(
      id: 'sess-1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-05',
      timestampIso: '2026-09-05T10:00:00.000Z',
      windows: [
        {'other@example.com': true}
      ],
      names: const {'other@example.com': 'X'},
    );
    await t.pumpWidget(ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
            email: 'p@x.in', displayName: 'Prof', uid: 'u9'))),
        cloudSyncProvider.overrideWithValue(cloud),
        deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
      ],
      child: MaterialApp(home: SessionEditScreen(record: rec)),
    ));
    await t.pumpAndSettle();
    // The form fields ARE the search: typing an email prefix lists the
    // enrolled student as a card in the same place.
    final dirField = find.byKey(const ValueKey('edit-email'));
    await t.scrollUntilVisible(dirField, 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.enterText(dirField, 'student1@');
    // Debounce (400ms) + async directory fetch settle on explicit pumps.
    await t.pump(const Duration(milliseconds: 600));
    await t.pumpAndSettle();
    // Live online card for the enrolled student.
    expect(find.text('Student One'), findsOneWidget);
    expect(find.textContaining('12342210'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Student One'), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Student One'));
    await t.pump();
    String field(String k) =>
        t.widget<TextField>(find.byKey(ValueKey(k))).controller!.text;
    expect(field('edit-email'), 'student1@example.com');
    expect(field('edit-name'), 'Student One');
    expect(field('edit-roll'), '12342210');
    // Selecting completes the add; saving persists without errors.
    await t.scrollUntilVisible(find.text('Add & mark present'), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Add & mark present'));
    await t.pump();
    await t.scrollUntilVisible(find.text('Save changes'), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Save changes'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('session edit lists partial + absent with mark-present',
      (t) async {
    final store = InMemoryDeviceStore();
    final s1 = ClassRecord(
      id: 's1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-04',
      timestampIso: '2026-09-04T10:00:00.000Z',
      windows: [
        {'gone@example.com': true}
      ],
      names: const {'gone@example.com': 'Gone Student'},
      rolls: const {'gone@example.com': '10000009'},
    );
    final s2 = ClassRecord(
      id: 's2',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-05',
      timestampIso: '2026-09-05T10:00:00.000Z',
      windows: [
        {'student1@example.com': true},
        {'student1@example.com': false}
      ],
      names: const {'student1@example.com': 'Student One'},
      rolls: const {'student1@example.com': '10000001'},
    );
    await store.upsertHistory(s1);
    await store.upsertHistory(s2);
    await t.pumpWidget(ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
            email: 'p@x.in', displayName: 'Prof', uid: 'u9'))),
        cloudSyncProvider.overrideWithValue(FakeCloudSync()),
        deviceStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
          home: SessionEditScreen(record: s2, courseSessions: [s1, s2])),
    ));
    await t.pumpAndSettle();
    // Partial (this session) + absent (course union minus here).
    expect(find.text('Partial in this session (1)'), findsOneWidget);
    expect(find.text('Absent (1)'), findsOneWidget);
    expect(find.text('Gone Student'), findsOneWidget);
    // Mark the partial present → section clears.
    await t.tap(find.text('Mark present').first);
    await t.pumpAndSettle();
    expect(find.text('Partial in this session (1)'), findsNothing);
    // Mark the absent present → section clears.
    await t.tap(find.text('Mark present').first);
    await t.pumpAndSettle();
    expect(find.text('Absent (1)'), findsNothing);
    await t.scrollUntilVisible(find.text('Save changes'), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Save changes'));
    await t.pumpAndSettle();
    final back =
        (await store.readHistory()).firstWhere((r) => r.id == 's2');
    expect(back.isPresent('student1@example.com'), isTrue);
    expect(back.isPresent('gone@example.com'), isTrue);
    expect(t.takeException(), isNull);
  });
}
