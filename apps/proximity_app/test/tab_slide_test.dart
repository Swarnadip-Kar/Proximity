// Tab-switch contracts (§3.1 pager): bottom-nav taps animate the pager and
// finger drags track 1:1 with snap on release (WhatsApp pattern —
// PageView, so every tab including the centre pages identically). Bar and
// content sync both ways. Per-tab Navigator stacks + scroll positions
// survive (keep-alive pages), reduce-motion parks the pager (swipes off,
// taps jump), the Mark gate binds swipes exactly like taps (unenrolled
// swipe-to-Mark snaps back + routes setup, never lands), and swipes never
// leave a pushed sub-page (page lock).
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
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/account/account_screen.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/records/my_attendance_screen.dart';
import 'package:proximity_app/features/records/prof_courses_screen.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/screens/setup_flow_screen.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_app/screens/student_home.dart';
import 'package:proximity_ble/ble.dart';

const _linked = LinkedIdentity(
    name: 'Test User', gmail: 'student@example.com', roll: 'R1');

/// Fling velocity driven in tests: comfortably above the shell's
/// minimum-swipe floor, comfortably below anything exotic.
const _flingVelocity = 800.0;

List<Override> _overrides({LinkedIdentity? linked}) {
  return [
    authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
        email: 'student@example.com',
        displayName: 'Test User',
        uid: 'test-uid'))),
    cloudSyncProvider.overrideWithValue(FakeCloudSync()),
    deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
    faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
    deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
    hostDriverProvider.overrideWithValue(FakeHostDriver()),
    studentDriverProvider
        .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
    bleEngineProvider.overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
    blePermissionProvider.overrideWithValue(() async => true),
    btPowerProvider.overrideWithValue(() async => BtState.on),
    if (linked != null) linkedIdentityProvider.overrideWith((ref) => linked),
    enrollmentControllerProvider.overrideWith(
      (ref) => EnrollmentController(
        auth: ref.watch(authServiceProvider),
        store: ref.watch(deviceStoreProvider),
        verifier: FakeFaceVerifier(),
        deviceKey: FakeDeviceKey(),
      ),
    ),
  ];
}

Widget _studentApp({LinkedIdentity? linked, bool reduced = false}) {
  final shell = reduced
      ? Builder(
          builder: (c) => MediaQuery(
                data: MediaQuery.of(c).copyWith(disableAnimations: true),
                child: const StudentShell(),
              ))
      : const StudentShell();
  return ProviderScope(
    overrides: _overrides(linked: linked),
    child: MaterialApp(theme: proxLightTheme(), home: shell),
  );
}

Widget _profApp(InMemoryDeviceStore store, {bool reduced = false}) {
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
    child: MaterialApp(
      theme: proxLightTheme(),
      home: reduced
          ? Builder(
              builder: (c) => MediaQuery(
                    data: MediaQuery.of(c)
                        .copyWith(disableAnimations: true),
                    child: const ProfShell(),
                  ))
          : const ProfShell(),
    ),
  );
}

/// Stepped settle, canonical for the shell suites (also imported by
/// live_subtabs_freshness): lets each periodic tick's async tail settle
/// instead of racing stagger one-shots at teardown.
Future<void> steppedSettle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

/// Shell bar + tab finders (gradient-pill bar): tabs are keyed
/// `shell-tab-<label>` inside the `shell-bar` container.
Finder _tabInBar(String label) => find.descendant(
      of: find.byKey(const ValueKey('shell-bar')),
      matching: find.text(label),
    );

Future<void> _openTab(WidgetTester t, String label) async {
  final labelInBar = _tabInBar(label);
  expect(labelInBar, findsOneWidget, reason: 'tab $label exists in bar');
  await t.tap(labelInBar);
  await steppedSettle(t);
}

/// Bottom-bar selected index (bar/content sync both ways): the active
/// pill is the one whose AnimatedContainer carries the brand gradient.
/// Searches offstage too: the auto-pushed flow covers (offstages) the bar
/// while open, and sync assertions must still read it.
int _barIndex(WidgetTester t) {
  final isStudent = find
      .byKey(const ValueKey('shell-tab-Mark'), skipOffstage: false)
      .evaluate()
      .isNotEmpty;
  final labels =
      isStudent ? ['Mark', 'Courses', 'Account'] : ['Live', 'Courses', 'Account'];
  for (var i = 0; i < labels.length; i++) {
    // NOTE: every nested finder needs skipOffstage:false here — the
    // outer flag alone cannot resurrect widgets the inner matchers
    // already excluded.
    final containers = t.widgetList<AnimatedContainer>(find.descendant(
      of: find.byKey(ValueKey('shell-tab-${labels[i]}'),
          skipOffstage: false),
      matching: find.byType(AnimatedContainer, skipOffstage: false),
      skipOffstage: false,
    ));
    for (final ac in containers) {
      final d = ac.decoration;
      if (d is BoxDecoration && d.gradient != null) return i;
    }
  }
  return -1;
}

/// Finger swipe across tab content: negative dx pages forward (toward
/// higher indices), positive dx pages back.
Future<void> _swipe(WidgetTester t, Finder content, Offset offset) async {
  await t.fling(content, offset, _flingVelocity);
  await steppedSettle(t);
}

/// Shell pager position (fractional mid-flight, integer at rest).
/// While the auto-pushed setup flow covers the shell, TWO PageViews coexist
/// (shell 3-tab pager + flow 6-step stepper) and the covered shell is
/// offstage — so search offstage too and always read the shell pager
/// (exactly 3 tab pages); enrolled shells still host just the one pager.
double? _page(WidgetTester t) {
  final pagers = t
      .widgetList<PageView>(find.byType(PageView, skipOffstage: false));
  for (final p in pagers) {
    final d = p.childrenDelegate;
    if (d is SliverChildListDelegate && d.children.length == 3) {
      return p.controller?.page;
    }
  }
  return pagers.isEmpty ? null : pagers.first.controller?.page;
}

/// Backs out of the auto-pushed flow (one system back per flow step, then
/// the first-step pop) until it is gone. Bounded by the step count + 1.
Future<void> _dismissFlow(WidgetTester t) async {
  for (var i = 0;
      i < 7 && find.byType(SetupFlowScreen).evaluate().isNotEmpty;
      i++) {
    await t.binding.handlePopRoute();
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }
}

/// Rounded pager index for settled assertions.
int _pageIndex(WidgetTester t) => (_page(t) ?? -1).round();

/// The Courses-tab list scroll offset (direct [ScrollPosition] read —
/// card finders are unreliable across drags since off-viewport rows
/// unmount past the cache extent).
double _courseScroll(WidgetTester t) {
  final s = find.descendant(
    of: find.byType(ProfCoursesScreen),
    matching: find.byType(Scrollable),
  );
  expect(s, findsOneWidget);
  return t.state<ScrollableState>(s).position.pixels;
}

void main() {
  test('tabSlide token is WhatsApp-cadence on an easeOutCubic curve', () {
    expect(ProxDurations.tabSlide.inMilliseconds,
        inInclusiveRange(200, 250));
    expect(ProxCurves.standard, Curves.easeOutCubic);
    // The frozen cross-fade token still serves the 4dp icon settle only.
    expect(ProxDurations.tabCrossFade,
        const Duration(milliseconds: 120));
  });

  group('student shell slide', () {
    testWidgets('rightward tap pages forward; leftward mirrors', (t) async {
      await t.pumpWidget(_studentApp(linked: _linked));
      await steppedSettle(t);
      expect(find.byType(StudentHomeScreen), findsOneWidget);
      expect(_pageIndex(t), 0);

      // Mark(0) → Courses(1): pager eases 0 → 1 mid-flight, then rests.
      // (First pump delivers the tap through the gesture arena; the
      // second advances the pager animation.)
      await t.tap(_tabInBar('Courses'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 110));
      final mid = _page(t);
      expect(mid, isNotNull);
      expect(mid!, greaterThan(0.0));
      expect(mid, lessThan(1.0));
      await t.pump(ProxDurations.tabSlide);
      await steppedSettle(t);
      expect(_pageIndex(t), 1);
      expect(find.byType(MyAttendanceScreen), findsOneWidget);

      // Same-tab tap restarts nothing (settled at rest).
      await t.tap(_tabInBar('Courses'));
      await t.pump();
      expect(_pageIndex(t), 1);
      await steppedSettle(t);

      // Courses(1) → Mark(0): pager eases back.
      await t.tap(_tabInBar('Mark'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 110));
      final back = _page(t);
      expect(back, isNotNull);
      expect(back!, greaterThan(0.0));
      expect(back, lessThan(1.0));
      await t.pump(ProxDurations.tabSlide);
      await steppedSettle(t);
      expect(_pageIndex(t), 0);
      expect(find.byType(StudentHomeScreen), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('Locked tabs intercept through the slide path', (t) async {
      await t.pumpWidget(_studentApp());
      await steppedSettle(t);
      // Unenrolled mounts on Accounts with the auto-pushed flow (one).
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      // Back out to drive the pager itself: parked on Accounts.
      await _dismissFlow(t);
      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(_pageIndex(t), 2);

      // Courses tap parks on Accounts and re-pushes the flow (no dead
      // end — the flow push is the only way forward).
      await t.tap(_tabInBar('Courses'));
      await steppedSettle(t);
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      await _dismissFlow(t);
      expect(_pageIndex(t), 2);

      // Mark tap likewise: still Accounts underneath, still one flow.
      await t.tap(_tabInBar('Mark'));
      await steppedSettle(t);
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      // Drain the re-pushed flow entrance timers before teardown.
      await steppedSettle(t);
      expect(t.takeException(), isNull);
    });
  });

  group('student shell swipe', () {
    testWidgets('flings switch tabs both directions; bar stays in sync',
        (t) async {
      await t.pumpWidget(_studentApp(linked: _linked));
      await steppedSettle(t);
      expect(find.byType(StudentHomeScreen), findsOneWidget);

      // Finger left pages forward: Mark → Courses (pager ballistic).
      await t.fling(
          find.byType(StudentHomeScreen), const Offset(-400, 0), 800);
      await steppedSettle(t);
      expect(_pageIndex(t), 1);
      expect(find.byType(MyAttendanceScreen), findsOneWidget);
      expect(_barIndex(t), 1);

      // Finger right pages back: Courses → Mark.
      await t.fling(
          find.byType(MyAttendanceScreen), const Offset(400, 0), 800);
      await steppedSettle(t);
      expect(_pageIndex(t), 0);
      expect(find.byType(StudentHomeScreen), findsOneWidget);
      expect(_barIndex(t), 0);

      // Past the first edge: stays put.
      await t.fling(
          find.byType(StudentHomeScreen), const Offset(400, 0), 800);
      await steppedSettle(t);
      expect(_pageIndex(t), 0);
      expect(_barIndex(t), 0);
      expect(t.takeException(), isNull);
    });

    testWidgets('page tracks the finger mid-drag, snaps on release',
        (t) async {
      await t.pumpWidget(_studentApp(linked: _linked));
      await steppedSettle(t);
      final size = t.getSize(find.byType(PageView));

      // Slow finger drag left, held mid-flight: the page sits partway
      // (locked to the finger — the WhatsApp contract). Moved in steps
      // with pumps, like a real finger. Past halfway so release snaps
      // forward (zero-velocity release snaps to nearest).
      final gesture = await t.startGesture(
          t.getCenter(find.byType(StudentHomeScreen)));
      for (var k = 0; k < 6; k++) {
        await gesture.moveBy(Offset(-size.width * 0.1, 0));
        await t.pump();
      }
      final mid = _page(t);
      expect(mid, isNotNull);
      expect(mid!, greaterThan(0.35));
      expect(mid, lessThan(0.85));

      // Release: snaps forward to Courses.
      await gesture.up();
      await steppedSettle(t);
      expect(_pageIndex(t), 1);
      expect(find.byType(MyAttendanceScreen), findsOneWidget);
      expect(_barIndex(t), 1);
      expect(t.takeException(), isNull);
    });

    testWidgets('slow drag does not switch tabs', (t) async {
      await t.pumpWidget(_studentApp(linked: _linked));
      await steppedSettle(t);

      // ~100px/s short drag: snaps back to Mark on release.
      await t.timedDrag(find.byType(StudentHomeScreen),
          const Offset(-100, 0), const Duration(seconds: 1));
      await steppedSettle(t);
      expect(_pageIndex(t), 0);
      expect(find.byType(StudentHomeScreen), findsOneWidget);
      expect(_barIndex(t), 0);
      expect(t.takeException(), isNull);
    });

    testWidgets('unenrolled swipe toward locked tabs snaps back + flow',
        (t) async {
      await t.pumpWidget(_studentApp());
      await steppedSettle(t);
      // Mounts on Accounts (page 2) with the auto-pushed flow (one).
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      // Back out to drive the pager itself.
      await _dismissFlow(t);
      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(_pageIndex(t), 2);
      expect(_barIndex(t), 2);

      // Swipe back toward Courses (page 1, locked): travels, snaps back —
      // never lands — and re-triggers the flow (no dead ends).
      await t.fling(
          find.byType(StudentAccountScreen), const Offset(400, 0), 800);
      await steppedSettle(t);
      expect(_pageIndex(t), 2);
      expect(_barIndex(t), 2);
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      // Drain the re-pushed flow entrance timers before teardown.
      await steppedSettle(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('reduce-motion parks the pager: swipes off, taps jump',
        (t) async {
      await t.pumpWidget(_studentApp(linked: _linked, reduced: true));
      await steppedSettle(t);
      expect(find.byType(StudentHomeScreen), findsOneWidget);

      // Swipe does nothing while parked (motion-sensitive users page by
      // explicit tap only).
      await t.fling(
          find.byType(StudentHomeScreen), const Offset(-400, 0), 800);
      await steppedSettle(t);
      expect(_pageIndex(t), 0);
      expect(find.byType(StudentHomeScreen), findsOneWidget);
      expect(_barIndex(t), 0);

      // Taps jump with no motion in flight.
      await t.tap(_tabInBar('Courses'));
      await t.pump();
      expect(_pageIndex(t), 1);
      expect(find.byType(MyAttendanceScreen), findsOneWidget);
      await steppedSettle(t);
      expect(_barIndex(t), 1);
      expect(t.takeException(), isNull);
    });
  });

  group('professor shell slide', () {
    testWidgets('Live → Account pages forward; Account → Live mirrors',
        (t) async {
      await t.pumpWidget(_profApp(InMemoryDeviceStore()));
      await steppedSettle(t);
      expect(find.text('Go to Courses'), findsOneWidget);
      expect(_pageIndex(t), 0);

      await t.tap(_tabInBar('Account'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 110));
      final mid = _page(t);
      expect(mid, isNotNull);
      expect(mid!, greaterThan(0.0));
      await t.pump(ProxDurations.tabSlide);
      await steppedSettle(t);
      expect(_pageIndex(t), 2);

      await t.tap(_tabInBar('Live'));
      await t.pump(ProxDurations.tabSlide);
      await steppedSettle(t);
      expect(_pageIndex(t), 0);
      expect(find.text('Go to Courses'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('in-tab Navigator stack survives slide switches', (t) async {
      final store = InMemoryDeviceStore();
      await store.addCourse('CS201');
      await t.pumpWidget(_profApp(store));
      await steppedSettle(t);

      // Push the course overview on the Courses tab's own Navigator.
      await _openTab(t, 'Courses');
      await t.tap(find.text('CS201'));
      await steppedSettle(t);
      expect(find.text('Review & export'), findsOneWidget);

      // Round-trip through Account: the pushed route must still be there.
      await _openTab(t, 'Account');
      expect(find.text('Review & export'), findsNothing);
      await _openTab(t, 'Courses');
      expect(find.text('Review & export'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('scroll position survives slide switches', (t) async {
      final store = InMemoryDeviceStore();
      for (var i = 1; i <= 12; i++) {
        await store.addCourse('CS2${i.toString().padLeft(2, '0')}');
      }
      await t.pumpWidget(_profApp(store));
      await steppedSettle(t);
      await _openTab(t, 'Courses');

      final list = find.descendant(
        of: find.byType(ProfCoursesScreen),
        matching: find.byType(ListView),
      );
      expect(list, findsOneWidget);
      expect(_courseScroll(t), 0.0);
      await t.drag(list, const Offset(0, -400));
      await t.pump();
      final dragged = _courseScroll(t);
      expect(dragged, greaterThan(0.0));

      // Round-trip through Account: the list must not jump.
      await _openTab(t, 'Account');
      await _openTab(t, 'Courses');
      expect(_courseScroll(t), dragged);
      expect(t.takeException(), isNull);
    });

    testWidgets('reduce-motion parks the pager: taps jump, no flight',
        (t) async {
      await t.pumpWidget(_profApp(InMemoryDeviceStore(), reduced: true));
      await steppedSettle(t);
      expect(find.text('Go to Courses'), findsOneWidget);
      expect(_pageIndex(t), 0);

      // Taps jump with no motion mid-flight.
      await t.tap(_tabInBar('Courses'));
      await t.pump();
      expect(_pageIndex(t), 1);
      expect(find.text('Register new course'), findsOneWidget);
      await steppedSettle(t);

      await t.tap(_tabInBar('Live'));
      await t.pump();
      expect(_pageIndex(t), 0);
      await steppedSettle(t);
      expect(find.text('Go to Courses'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('professor shell swipe', () {
    testWidgets('flings page both directions; bar syncs; edges hold',
        (t) async {
      await t.pumpWidget(_profApp(InMemoryDeviceStore()));
      await steppedSettle(t);
      expect(find.text('Go to Courses'), findsOneWidget);

      await _swipe(t, find.text('Go to Courses'), const Offset(-400, 0));
      expect(find.byType(ProfCoursesScreen), findsOneWidget);
      expect(_barIndex(t), 1);

      await _swipe(t, find.byType(ProfCoursesScreen), const Offset(-400, 0));
      expect(_barIndex(t), 2);

      // Past the last edge: stays put (fling on account content).
      await _swipe(t, find.byType(ProfAccountScreen), const Offset(-400, 0));
      expect(_barIndex(t), 2);

      await _swipe(t, find.byType(ProfAccountScreen), const Offset(400, 0));
      expect(_barIndex(t), 1);
      expect(find.byType(ProfCoursesScreen), findsOneWidget);

      await _swipe(t, find.byType(ProfCoursesScreen), const Offset(400, 0));
      expect(_barIndex(t), 0);
      expect(find.text('Go to Courses'), findsOneWidget);

      // Past the first edge: stays put.
      await _swipe(t, find.text('Go to Courses'), const Offset(400, 0));
      expect(_barIndex(t), 0);
      expect(t.takeException(), isNull);
    });

    testWidgets('swipe over a pushed page does not switch tabs', (t) async {
      final store = InMemoryDeviceStore();
      await store.addCourse('CS201');
      await t.pumpWidget(_profApp(store));
      await steppedSettle(t);

      // Push the course overview on the Courses tab's own Navigator.
      await _openTab(t, 'Courses');
      await t.tap(find.text('CS201'));
      await steppedSettle(t);
      expect(find.text('Review & export'), findsOneWidget);

      // Both directions swallowed: the pushed route keeps its own
      // gestures, the tab stays put, the stack is untouched.
      await _swipe(t, find.text('Review & export'), const Offset(-400, 0));
      expect(_barIndex(t), 1);
      expect(find.text('Review & export'), findsOneWidget);

      await _swipe(t, find.text('Review & export'), const Offset(400, 0));
      expect(_barIndex(t), 1);
      expect(find.text('Review & export'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
