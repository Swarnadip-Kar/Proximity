// Tab-switch contracts (§3.1 slide + swipe rebuild): bottom-nav taps AND
// content flings switch tabs with one directional motion (direction follows
// tab order, [ProxDurations.tabSlide] on easeOutCubic — never
// double-animated), bar and content sync both ways. Per-tab Navigator
// stacks + scroll positions survive, reduce-motion falls back to instant
// opacity, the Mark gate binds swipes exactly like taps (unenrolled
// swipe-to-Mark snaps back + routes setup, never lands), and swipes only
// ever leave a tab root (a pushed sub-page keeps its own gestures/back).
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

/// Stepped settle (mirrors the shell suites): lets each periodic tick's
/// async tail settle instead of racing stagger one-shots at teardown.
Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _openTab(WidgetTester t, String label) async {
  final labelInBar = find.descendant(
    of: find.byType(BottomNavigationBar),
    matching: find.text(label),
  );
  expect(labelInBar, findsOneWidget, reason: 'tab $label exists in bar');
  await t.tap(labelInBar);
  await _settle(t);
}

/// Bottom-bar selected index (bar/content sync both ways).
int _barIndex(WidgetTester t) =>
    t.widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
        .currentIndex;

/// Finger swipe across tab content: negative dx pages forward (toward
/// higher indices), positive dx pages back.
Future<void> _swipe(WidgetTester t, Finder content, Offset offset) async {
  await t.fling(content, offset, _flingVelocity);
  await _settle(t);
}

/// True when [opacity] sits directly above a tab [Navigator] (through the
/// swipe [GestureDetector]); nested screen fades are excluded.
bool _isTabOpacity(AnimatedOpacity opacity) {
  final inner = opacity.child;
  if (inner is Navigator) return true;
  return inner is GestureDetector && inner.child is Navigator;
}

/// Our per-tab slide widgets: [SlideTransition] is used by other widgets
/// too, so we match the exact child chain (slide > tab opacity > tab
/// [Navigator]) instead of the type alone.
List<SlideTransition> _ourSlides(WidgetTester t) {
  final all = t.widgetList<SlideTransition>(find.descendant(
    of: find.byType(IndexedStack),
    // skipOffstage on the INNER matcher: inactive tabs are kept alive but
    // unpainted, and the outer flag alone does not reach them.
    matching: find.byType(SlideTransition, skipOffstage: false),
    skipOffstage: false,
  ));
  return all.where((w) {
    final c = w.child;
    return c is AnimatedOpacity && _isTabOpacity(c);
  }).toList();
}

/// Paint offsets of the currently-moving tab slides (at rest every slide
/// sits at [Offset.zero], so only a mid-flight switch shows up here).
List<double> _movingDx(WidgetTester t) => <double>[
      for (final w in _ourSlides(t))
        if (w.position.value != Offset.zero) w.position.value.dx,
    ];

/// Our per-tab opacity wrappers (same chain match as [_ourSlides]).
List<AnimatedOpacity> _tabOpacities(WidgetTester t) {
  return t
      .widgetList<AnimatedOpacity>(find.descendant(
        of: find.byType(IndexedStack),
        // Inactive tabs sit unpainted under the IndexedStack (keep-alive);
        // the flag belongs on the inner matcher (see above).
        matching: find.byType(AnimatedOpacity, skipOffstage: false),
        skipOffstage: false,
      ))
      .where(_isTabOpacity)
      .toList();
}

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
    testWidgets('rightward tap slides in from right; leftward mirrors',
        (t) async {
      await t.pumpWidget(_studentApp(linked: _linked));
      await _settle(t);
      expect(find.byType(StudentHomeScreen), findsOneWidget);

      // Mark(0) → Courses(1): incoming starts fully right, eases to rest.
      await t.tap(find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('Courses'),
      ));
      await t.pump();
      expect(_movingDx(t), [1.0]);
      await t.pump(const Duration(milliseconds: 110));
      final mid = _movingDx(t);
      expect(mid.length, 1);
      expect(mid.single, greaterThan(0.0));
      expect(mid.single, lessThan(1.0));
      await t.pump(ProxDurations.tabSlide);
      expect(_movingDx(t), isEmpty);
      await _settle(t);
      expect(find.byType(MyAttendanceScreen), findsOneWidget);

      // Same-tab tap restarts nothing (settled at rest).
      await t.tap(find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('Courses'),
      ));
      await t.pump();
      expect(_movingDx(t), isEmpty);
      await _settle(t);

      // Courses(1) → Mark(0): incoming starts fully left.
      await t.tap(find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('Mark'),
      ));
      await t.pump();
      expect(_movingDx(t), [-1.0]);
      await t.pump(ProxDurations.tabSlide);
      expect(_movingDx(t), isEmpty);
      await _settle(t);
      expect(find.byType(StudentHomeScreen), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('Mark gate still fires through the slide path', (t) async {
      await t.pumpWidget(_studentApp());
      await _settle(t);
      // Unenrolled → gate flow, never bare mark.
      expect(find.byType(SetupFlowScreen), findsOneWidget);

      await _openTab(t, 'Courses');
      expect(find.byType(SetupFlowScreen), findsNothing);

      // Returning to Mark re-arms the gate (slide path preserves _selectTab
      // gate behavior byte-identically).
      await _openTab(t, 'Mark');
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('student shell swipe', () {
    testWidgets('flings switch tabs both directions; bar stays in sync',
        (t) async {
      await t.pumpWidget(_studentApp(linked: _linked));
      await _settle(t);
      expect(find.byType(StudentHomeScreen), findsOneWidget);

      // Finger left pages forward: Mark → Courses with the same rightward
      // slide as taps (single motion — tap and swipe never double up).
      await t.fling(
          find.byType(StudentHomeScreen), const Offset(-400, 0), 800);
      await t.pump();
      expect(_movingDx(t), [1.0]);
      await _settle(t);
      expect(find.byType(MyAttendanceScreen), findsOneWidget);
      expect(_barIndex(t), 1);

      // Finger right pages back: Courses → Mark, mirrored slide.
      await t.fling(
          find.byType(MyAttendanceScreen), const Offset(400, 0), 800);
      await t.pump();
      expect(_movingDx(t), [-1.0]);
      await _settle(t);
      expect(find.byType(StudentHomeScreen), findsOneWidget);
      expect(_barIndex(t), 0);

      // Past the first edge: stays put, no animation.
      await t.fling(
          find.byType(StudentHomeScreen), const Offset(400, 0), 800);
      await t.pump();
      expect(_movingDx(t), isEmpty);
      await _settle(t);
      expect(_barIndex(t), 0);
      expect(t.takeException(), isNull);
    });

    testWidgets('slow drag does not switch tabs', (t) async {
      await t.pumpWidget(_studentApp(linked: _linked));
      await _settle(t);

      // ~100px/s: well under the swipe floor — vertical-list jitter and
      // hesitant drags never page.
      await t.timedDrag(find.byType(StudentHomeScreen),
          const Offset(-100, 0), const Duration(seconds: 1));
      await _settle(t);
      expect(find.byType(StudentHomeScreen), findsOneWidget);
      expect(_barIndex(t), 0);
      expect(t.takeException(), isNull);
    });

    testWidgets('unenrolled swipe-to-Mark snaps back + routes setup',
        (t) async {
      await t.pumpWidget(_studentApp());
      await _settle(t);
      expect(find.byType(SetupFlowScreen), findsOneWidget);

      // Leave Mark by tap (swipe is locked while the gate flow is pushed —
      // a pushed route is not a tab root).
      await _openTab(t, 'Courses');
      expect(find.byType(MyAttendanceScreen), findsOneWidget);

      // Swipe back toward Mark: routes setup, travels, snaps back —
      // never lands.
      await t.fling(
          find.byType(MyAttendanceScreen), const Offset(400, 0), 800);
      await _settle(t);
      expect(find.byType(MyAttendanceScreen), findsOneWidget);
      expect(_barIndex(t), 1);
      // No visible flow (never lands) …
      expect(find.byType(SetupFlowScreen), findsNothing);
      // … but the setup route was pushed on the Mark stack.
      expect(find.byType(SetupFlowScreen, skipOffstage: false),
          findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('reduce-motion swipe switches instantly', (t) async {
      await t.pumpWidget(_studentApp(linked: _linked, reduced: true));
      await _settle(t);
      expect(find.byType(StudentHomeScreen), findsOneWidget);

      // Slides stay parked: lands with no motion in flight.
      await t.fling(
          find.byType(StudentHomeScreen), const Offset(-400, 0), 800);
      await t.pump();
      expect(find.byType(MyAttendanceScreen), findsOneWidget);
      expect(_movingDx(t), isEmpty);
      await _settle(t);
      expect(_barIndex(t), 1);
      expect(t.takeException(), isNull);
    });
  });

  group('professor shell slide', () {
    testWidgets('Live → Account slides from right; Account → Live from left',
        (t) async {
      await t.pumpWidget(_profApp(InMemoryDeviceStore()));
      await _settle(t);
      expect(find.text('Go to Courses'), findsOneWidget);

      await t.tap(find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('Account'),
      ));
      await t.pump();
      expect(_movingDx(t), [1.0]);
      await t.pump(ProxDurations.tabSlide);
      expect(_movingDx(t), isEmpty);
      await _settle(t);

      await t.tap(find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('Live'),
      ));
      await t.pump();
      expect(_movingDx(t), [-1.0]);
      await _settle(t);
      expect(find.text('Go to Courses'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('in-tab Navigator stack survives slide switches', (t) async {
      final store = InMemoryDeviceStore();
      await store.addCourse('CS201');
      await t.pumpWidget(_profApp(store));
      await _settle(t);

      // Push the course overview on the Courses tab's own Navigator.
      await _openTab(t, 'Courses');
      await t.tap(find.text('CS201'));
      await _settle(t);
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
      await _settle(t);
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

    testWidgets('reduce-motion falls back to instant opacity (no slide)',
        (t) async {
      await t.pumpWidget(_profApp(InMemoryDeviceStore(), reduced: true));
      await _settle(t);
      expect(find.text('Go to Courses'), findsOneWidget);

      // Slides stay parked at rest, and every tab opacity is instant.
      expect(_ourSlides(t).length, 3);
      expect(_movingDx(t), isEmpty);
      final opacities = _tabOpacities(t);
      expect(opacities.length, 3);
      for (final e in opacities) {
        expect(e.duration, Duration.zero);
      }

      // Switches still land instantly with no slide mid-flight.
      await t.tap(find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('Courses'),
      ));
      await t.pump();
      expect(_movingDx(t), isEmpty);
      expect(find.text('Register new course'), findsOneWidget);
      await _settle(t);

      await t.tap(find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('Live'),
      ));
      await t.pump();
      expect(_movingDx(t), isEmpty);
      await _settle(t);
      expect(find.text('Go to Courses'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('professor shell swipe', () {
    testWidgets('flings page both directions; bar syncs; edges hold',
        (t) async {
      await t.pumpWidget(_profApp(InMemoryDeviceStore()));
      await _settle(t);
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
      await _settle(t);

      // Push the course overview on the Courses tab's own Navigator.
      await _openTab(t, 'Courses');
      await t.tap(find.text('CS201'));
      await _settle(t);
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
