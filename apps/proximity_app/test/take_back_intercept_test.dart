// Task 2 (back-intercept): the take route carries its own
// PopScope(canPop:false) so system back runs the SAME awaited teardown as
// the bar BackButton (timers → save draft → endHosting) before popping —
// instead of racing it through dispose's unawaited backstop.
//
// Pinned here, via the test back dispatcher on a pushed take screen:
// draft contains the marks, hosting is down, exactly one pop happened,
// and teardown ran exactly once (never a double-teardown).
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
import 'package:proximity_app/screens/take_attendance.dart';
import 'package:proximity_ble/ble.dart';

/// Fake host that counts endHosting calls: the awaited intercept teardown
/// calls it once. (dispose()'s own endHosting attempt is a best-effort
/// no-op — `ref` is unusable during State.dispose in this Riverpod
/// version, so its read throws and is caught; pre-existing, unchanged.)
/// A double-teardown (second back-press mid-await, handler re-fire) would
/// show up as 2+.
class _CountingHostDriver extends FakeHostDriver {
  int endHostingCalls = 0;

  @override
  Future<void> endHosting() async {
    endHostingCalls++;
    await super.endHosting();
  }
}

class _PopCounter extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route route, Route? previousRoute) => pops++;
}

Future<void> _pumpTakeHarness(
  WidgetTester t, {
  required InMemoryDeviceStore store,
  required _CountingHostDriver host,
  required _PopCounter pops,
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(store),
        hostDriverProvider.overrideWithValue(host),
        studentDriverProvider.overrideWithValue(FakeStudentDriver()),
        bleEngineProvider
            .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        cameraPermissionProvider.overrideWithValue(() async => true),
        btPowerProvider.overrideWithValue(() async => BtState.on),
      ],
      // App theme: the take screen reads the ProximityColors extension.
      child: MaterialApp(
        theme: proxLightTheme(),
        navigatorObservers: [pops],
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute(
                  builder: (_) =>
                      const TakeAttendanceScreen(courseName: 'CS201'),
                ),
              ),
              child: const Text('open-take'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open-take'));
  await t.pumpAndSettle();
  expect(find.byType(TakeAttendanceScreen), findsOneWidget);
  expect(host.isHosting, isTrue);
}

/// Shell-hosted Take harness (F08): the Take screen is pushed on the
/// professor shell's Live-tab Navigator (the real `_shellBack` path), not
/// the root navigator. System back must travel shell PopScope → `_shellBack`
/// → tab `maybePop` → Take PopScope veto → awaited teardown (timers→save→
/// endHosting) → pop — never a forcible `pop` with hosting left up, never
/// the shell hint/exit while Take is on the stack.
Future<void> _pumpShellTakeHarness(
  WidgetTester t, {
  required InMemoryDeviceStore store,
  required _CountingHostDriver host,
  required _PopCounter pops,
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(FakeAuthService(
            const SignedAccount(
                email: 'prof@example.com',
                displayName: 'Prof',
                uid: 'prof-uid'))),
        cloudSyncProvider.overrideWithValue(FakeCloudSync()),
        deviceStoreProvider.overrideWithValue(store),
        faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
        deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
        hostDriverProvider.overrideWithValue(host),
        studentDriverProvider
            .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
        bleEngineProvider
            .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        cameraPermissionProvider.overrideWithValue(() async => true),
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
      // App theme: the take screen reads the ProximityColors extension.
      child: MaterialApp(
        theme: proxLightTheme(),
        navigatorObservers: [pops],
        home: const ProfShell(),
      ),
    ),
  );
  await t.pumpAndSettle();
  // Live-tab root lists the course (offstage Courses-tab rows are excluded
  // from the default finder, so this is the Live host row).
  expect(find.text('CS201'), findsOneWidget);
  await t.tap(find.text('CS201'));
  await t.pumpAndSettle();
  expect(find.byType(TakeAttendanceScreen), findsOneWidget);
  expect(host.isHosting, isTrue);
}

void main() {
  testWidgets(
      'system back awaits teardown: draft kept, hosting down, one pop, no double-teardown',
      (t) async {
    final store = InMemoryDeviceStore();
    final host = _CountingHostDriver();
    final pops = _PopCounter();
    await _pumpTakeHarness(t, store: store, host: host, pops: pops);

    // Marks land in the live tally (as a professor manual entry would).
    await host.addManualEntry(email: 'a@x.in', name: 'A', roll: '1');
    await t.pump();
    expect(host.endHostingCalls, 0);

    // System back via the test back dispatcher → maybePop consults the
    // take route's PopScope veto → awaited teardown → pop.
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    // Exactly one pop: back on the opener, take gone.
    expect(pops.pops, 1);
    expect(find.text('open-take'), findsOneWidget);
    expect(find.byType(TakeAttendanceScreen), findsNothing);
    // Awaited teardown effects: draft holds the marks, hosting is down.
    final draft = await store.readSession('CS201');
    expect(draft, isNotNull);
    expect((draft!['names'] as Map).keys, contains('a@x.in'));
    expect(host.isHosting, isFalse);
    // No double-teardown: exactly the intercept's single awaited
    // endHosting (a second back-press mid-await or a re-fired handler
    // would add a second call).
    expect(host.endHostingCalls, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('double system back mid-await still tears down exactly once',
      (t) async {
    final store = InMemoryDeviceStore();
    final host = _CountingHostDriver();
    final pops = _PopCounter();
    await _pumpTakeHarness(t, store: store, host: host, pops: pops);

    await host.addManualEntry(email: 'a@x.in', name: 'A', roll: '1');
    await t.pump();

    // Two back presses with no settle between: the second must be ignored
    // by the single-flight guard, never a second teardown or second pop.
    await t.binding.handlePopRoute();
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    expect(pops.pops, 1);
    expect(find.text('open-take'), findsOneWidget);
    expect(find.byType(TakeAttendanceScreen), findsNothing);
    final draft = await store.readSession('CS201');
    expect(draft, isNotNull);
    expect((draft!['names'] as Map).keys, contains('a@x.in'));
    expect(host.isHosting, isFalse);
    expect(host.endHostingCalls, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'shell back consults Take veto: teardown runs, Take pops, no hint/exit',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    final host = _CountingHostDriver();
    final pops = _PopCounter();
    await _pumpShellTakeHarness(t, store: store, host: host, pops: pops);

    await host.addManualEntry(email: 'a@x.in', name: 'A', roll: '1');
    await t.pump();
    expect(host.endHostingCalls, 0);

    // System back → shell PopScope → _shellBack → tab maybePop → Take veto
    // → awaited teardown → pop. (Take lives on the tab navigator, so the
    // root-navigator pop counter stays put — the UI + teardown effects are
    // the contract here.)
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    // Take popped back to the Live root — never the shell hint, never an
    // app exit with hosting up.
    expect(find.byType(TakeAttendanceScreen), findsNothing);
    expect(find.text('CS201'), findsOneWidget);
    expect(find.text('Press back again to leave the app'), findsNothing);
    final draft = await store.readSession('CS201');
    expect(draft, isNotNull);
    expect((draft!['names'] as Map).keys, contains('a@x.in'));
    expect(host.isHosting, isFalse);
    expect(host.endHostingCalls, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('shell double-back mid-await still tears down exactly once',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    final host = _CountingHostDriver();
    final pops = _PopCounter();
    await _pumpShellTakeHarness(t, store: store, host: host, pops: pops);

    await host.addManualEntry(email: 'a@x.in', name: 'A', roll: '1');
    await t.pump();

    // Two shell backs dispatched without awaiting between: both must land
    // while the first teardown is still in flight, so the Take
    // single-flight (_leaving) swallows the second — one teardown, one
    // pop, Live root underneath, no hint. (Awaiting each handlePopRoute
    // in turn lets the Fake driver's fast teardown pop Take before the
    // second arrives, which would legitimately reinterpret it as a
    // shell-root hint — that sequential case is covered by the single-back
    // test above, not this mid-await guard.)
    final f1 = t.binding.handlePopRoute();
    final f2 = t.binding.handlePopRoute();
    await f1;
    await f2;
    await t.pumpAndSettle();

    expect(find.byType(TakeAttendanceScreen), findsNothing);
    expect(find.text('CS201'), findsOneWidget);
    expect(find.text('Press back again to leave the app'), findsNothing);
    final draft = await store.readSession('CS201');
    expect(draft, isNotNull);
    expect((draft!['names'] as Map).keys, contains('a@x.in'));
    expect(host.isHosting, isFalse);
    expect(host.endHostingCalls, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('shell-hosted bar Back runs teardown and pops, no hint',
      (t) async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    final host = _CountingHostDriver();
    final pops = _PopCounter();
    await _pumpShellTakeHarness(t, store: store, host: host, pops: pops);

    await host.addManualEntry(email: 'a@x.in', name: 'A', roll: '1');
    await t.pump();
    expect(host.endHostingCalls, 0);

    // Bar BackButton shares Take's _leave (timers→save→endHosting→pop),
    // the same awaited path the PopScope veto runs — never a forcible pop
    // with hosting up, never the shell hint/exit.
    expect(find.byType(BackButton), findsOneWidget);
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();

    expect(find.byType(TakeAttendanceScreen), findsNothing);
    expect(find.text('CS201'), findsOneWidget);
    expect(find.text('Press back again to leave the app'), findsNothing);
    final draft = await store.readSession('CS201');
    expect(draft, isNotNull);
    expect((draft!['names'] as Map).keys, contains('a@x.in'));
    expect(host.isHosting, isFalse);
    expect(host.endHostingCalls, 1);
    expect(t.takeException(), isNull);
  });
}
