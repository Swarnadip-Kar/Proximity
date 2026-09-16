// Navigation-shell + enrollment-home widget contracts (§3.1/§3.3/§3.4/§3.5):
// shells render 3 tabs with token chrome and mount on Accounts; unenrolled
// students stay parked there with Mark/Courses locked (never bare
// mark/browse) while the shell auto-pushes ONE SetupFlowScreen on the root
// navigator (single-flight); locked taps/swipes re-trigger the push (no
// dead ends); enrolled students advance to Mark with no flow; the setup
// flow itself still starts at the first incomplete step; records/mine
// builds the records screen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/account/account_screen.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/records/my_attendance_screen.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/routes.dart';
import 'package:proximity_app/features/setup/setup_step_scope.dart';
import 'package:proximity_app/screens/setup_flow_screen.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_app/screens/student_home.dart';

import 'widget_test.dart' as helpers;

const _linked = LinkedIdentity(
    name: 'Test User', gmail: 'student@example.com', roll: 'R1');

/// Shell ProviderScope shims removed (A4): shell pumps below use the
/// canonical widget_test.testScope with an explicit MaterialApp home.
/// One-off inline ProviderScopes (signed-out flow, router aliases) are
/// kept as-is: they pin distinct minimal-override shapes.

void main() {
  group('setupStartIndex (pure)', () {
    test('signed out → sign-in step', () {
      expect(
          setupStartIndex(
              signedIn: false,
              hasStudentRole: false,
              hasKey: false,
              phase: EnrollPhase.signedOut),
          0);
    });

    test('signed in without student role → role step', () {
      expect(
          setupStartIndex(
              signedIn: true,
              hasStudentRole: false,
              hasKey: false,
              phase: EnrollPhase.signedIn),
          1);
    });

    test('student role without key → device step (pagination split)', () {
      expect(
          setupStartIndex(
              signedIn: true,
              hasStudentRole: true,
              hasKey: false,
              phase: EnrollPhase.signedIn),
          SetupStep.device);
    });

    test('key without face → capture step', () {
      expect(
          setupStartIndex(
              signedIn: true,
              hasStudentRole: true,
              hasKey: true,
              phase: EnrollPhase.keyReady),
          SetupStep.capture);
    });

    test('validated face → result step', () {
      expect(
          setupStartIndex(
              signedIn: true,
              hasStudentRole: true,
              hasKey: true,
              phase: EnrollPhase.faceDone),
          SetupStep.result);
    });

    test('uploaded claim → result step', () {
      expect(
          setupStartIndex(
              signedIn: true,
              hasStudentRole: true,
              hasKey: true,
              phase: EnrollPhase.uploaded),
          SetupStep.result);
    });
  });

  /// Backs out of the auto-pushed flow step-by-step (system back moves
  /// one flow step back, then pops from the first step) until it is gone.
  /// Bounded: the flow has [SetupStep.count] steps, so count + 1 backs
  /// always suffice; stops early once popped. After the pop, further backs
  /// would only hit the shell's hint snackbar, so never over-run.
  Future<void> dismissFlow(WidgetTester t) async {
    for (var i = 0;
        i < SetupStep.count + 1 &&
            find.byType(SetupFlowScreen).evaluate().isNotEmpty;
        i++) {
      await t.binding.handlePopRoute();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
    }
  }

  group('student shell', () {
    testWidgets(
        '3 tabs render; unenrolled auto-pushes one flow, back-out parks locked',
        (t) async {
      await t.pumpWidget(helpers.testScope(
          home: MaterialApp(
              theme: proxLightTheme(), home: const StudentShell())));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }

      // Accounts-first + auto-push: exactly ONE setup flow covers the
      // shell on mount (fresh unenrolled → flow immediately); bare Mark
      // never shows. (The covered shell is offstage, so bar assertions
      // run after the back-out below, when it is onstage again.)
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      expect(
          find.byType(StudentHomeScreen).hitTestable(), findsNothing);
      // Back out of the flow: lands on locked Accounts (never bare Mark).
      await dismissFlow(t);
      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(
          find.byType(StudentAccountScreen).hitTestable(), findsOneWidget);
      expect(
          find.byType(StudentHomeScreen).hitTestable(), findsNothing);

      // Pill bar: Mark · Courses · Account (wide test surface).
      // Scoped to the bar: page bodies reuse the same words.
      final bar = find.byKey(const ValueKey('shell-bar'));
      expect(bar, findsOneWidget);
      expect(
          find.descendant(of: bar, matching: find.text('Mark')),
          findsOneWidget);
      expect(find.text('Courses'), findsWidgets);
      expect(
          find.descendant(of: bar, matching: find.text('Account')),
          findsOneWidget);

      // Locked Mark tap re-pushes the flow (no dead end — single-flight:
      // still exactly one flow, never bare Mark).
      await t.tap(find.descendant(
        of: find.byKey(const ValueKey('shell-bar')),
        matching: find.text('Mark'),
      ));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      expect(
          find.byType(StudentHomeScreen).hitTestable(), findsNothing);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });

    testWidgets('enrolled student lands on Mark', (t) async {
      await t.pumpWidget(helpers.testScope(
        linked: _linked,
        home:
            MaterialApp(theme: proxLightTheme(), home: const StudentShell()),
      ));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }

      // Mounts on Accounts, unlocks, advances to Mark — no flow involved.
      expect(find.byType(StudentHomeScreen).hitTestable(), findsOneWidget);
      expect(find.byType(SetupFlowScreen), findsNothing);
      // Enrolled → never: tab storms never prompt redundantly (the
      // reported original bug stays fixed).
      for (final label in ['Courses', 'Account', 'Mark']) {
        await t.tap(find.descendant(
          of: find.byKey(const ValueKey('shell-bar')),
          matching: find.text(label),
        ));
        await t.pump(const Duration(milliseconds: 200));
      }
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(find.byType(StudentHomeScreen).hitTestable(), findsOneWidget);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });
  });

  group('professor shell', () {
    testWidgets('Live · Courses · Account with empty live root', (t) async {
      await t.pumpWidget(helpers.testScope(
          home: MaterialApp(theme: proxLightTheme(), home: const ProfShell())));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }

      expect(find.byKey(const ValueKey('shell-bar')), findsOneWidget);
      expect(
          find.descendant(
            of: find.byKey(const ValueKey('shell-bar')),
            matching: find.text('Live'),
          ),
          findsOneWidget);
      expect(find.text('Courses'), findsWidgets);
      expect(
          find.descendant(
            of: find.byKey(const ValueKey('shell-bar')),
            matching: find.text('Account'),
          ),
          findsOneWidget);
      // No registered courses → guidance + Courses pointer (records-only
      // Courses tab owns registration).
      expect(find.text('Go to Courses'), findsOneWidget);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });
  });

  group('setup flow screen', () {
    testWidgets('signed out starts at sign-in with a thin progress line',
        (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(FakeAuthService()),
          cloudSyncProvider.overrideWithValue(FakeCloudSync()),
          deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
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
          home: SetupFlowScreen(
            onFirstBack: () async {},
            onComplete: () async {},
          ),
        ),
      ));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }

      // Sign-in step content + §3.3 chrome (thin line, no step labels).
      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });
  });

  group('router records', () {
    testWidgets('records/mine builds the records screen', (t) async {
      final builder = buildProxRoutes()[ProxRoutes.myAttendance];
      expect(builder, isNotNull);
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
              email: 'student@example.com',
              displayName: 'Test User',
              uid: 'test-uid'))),
          cloudSyncProvider.overrideWithValue(FakeCloudSync()),
          deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
        ],
        child: MaterialApp(
          theme: proxLightTheme(),
          home: Builder(builder: (c) => builder!(c)),
        ),
      ));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(find.byType(MyAttendanceScreen), findsOneWidget);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });

  });
}
