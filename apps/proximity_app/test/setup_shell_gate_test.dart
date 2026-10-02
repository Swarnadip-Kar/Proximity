// Navigation-shell + enrollment-home widget contracts (§3.1/§3.3/§3.4/§3.5):
// shells render 3 tabs with token chrome and mount on Accounts; unenrolled
// students stay parked there with Mark/Courses locked (never bare
// mark/browse) while the shell auto-pushes ONE SetupFlowScreen on the root
// navigator (single-flight); locked taps/swipes re-trigger the push (no
// dead ends); enrolled students advance to Mark with no flow; the setup
// flow itself still starts at the first incomplete step; records/mine
// builds the records screen.
import 'dart:async';

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

    testWidgets(
        'unknown account parks locked without pushing any flow', (t) async {
      // Cold-start-after-update shape: Firebase has not restored the
      // session yet, so the account reads null. The shell must NOT read
      // that as unenrolled (that auto-pushes a phantom enrollment over
      // an enrolled user); it parks locked on Accounts until the account
      // listener re-resolves on arrival.
      await t.pumpWidget(helpers.testScope(
          signedOut: true,
          home: MaterialApp(
              theme: proxLightTheme(), home: const StudentShell())));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }

      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(
          find.byType(StudentAccountScreen).hitTestable(), findsOneWidget);
      expect(
          find.byType(StudentHomeScreen).hitTestable(), findsNothing);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });

    testWidgets('resolving shows checking state, never silence',
        (t) async {
      // Slow store read (biometric-gated on device): while the resolve
      // awaits it, the locked shell names the wait instead of parking
      // dead. Answering empty then concludes unenrolled → flow pushes.
      final store = _GatedEnrollStore();
      await t.pumpWidget(helpers.testScope(
          store: store,
          home: MaterialApp(
              theme: proxLightTheme(), home: const StudentShell())));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Checking enrollment…'), findsOneWidget);
      expect(find.byType(SetupFlowScreen), findsNothing);
      // Resolve slot rides below the pages, just above the tab bar —
      // never pushing the Account page down from the top.
      expect(
        t.getTopLeft(find.text('Checking enrollment…')).dy,
        greaterThan(400),
      );
      store.gate.complete(null);
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('Checking enrollment…'), findsNothing);
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });

    testWidgets('transient store failure shows retry, pushes nothing',
        (t) async {
      // Unknown is never unenrolled: no flow, no silence — a visible
      // banner whose Retry visibly re-attempts (reads climb, banner
      // persists while the store keeps failing).
      final store = _FailingEnrollStore();
      await t.pumpWidget(helpers.testScope(
          store: store,
          home: MaterialApp(
              theme: proxLightTheme(), home: const StudentShell())));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(
          find.text('Couldn’t reach secure storage — try again.'),
          findsOneWidget);
      expect(find.byType(SetupFlowScreen), findsNothing);
      // Error banner rides below the pages too (same slot as above).
      expect(
        t
            .getTopLeft(
                find.text('Couldn’t reach secure storage — try again.'))
            .dy,
        greaterThan(400),
      );
      final reads = store.reads;
      expect(reads, greaterThan(0));
      await t.tap(find.widgetWithText(TextButton, 'Retry'));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(store.reads, greaterThan(reads));
      expect(
          find.text('Couldn’t reach secure storage — try again.'),
          findsOneWidget);
      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(t.takeException(), isNull);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });

    testWidgets('locked account fires no entry read (no prompt race)',
        (t) async {
      // Cold-open race pin: while locked, the Account tab entry must not
      // fire its own biometric-gated read — it raced the shell resolve's
      // unlock prompt (overlapping prompts cancel; the scanned prompt
      // did nothing and the banner stayed). Exactly one read happens
      // here (the mount resolve): the account-arrival re-resolve hits
      // the dismissal park and stays silent (no second prompt uninvited),
      // and the entry never reads while locked.
      final store = _CountingDismissStore();
      await t.pumpWidget(helpers.testScope(
          store: store,
          home: MaterialApp(
              theme: proxLightTheme(), home: const StudentShell())));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(store.reads, 1);
      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(find.text('Unlock to continue — approve the phone prompt.'),
          findsOneWidget);
      expect(t.takeException(), isNull);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(store.reads, 1);
      // Explicit retry still re-prompts past the park (the park only
      // silences AUTOMATIC re-resolves): reads climb, banner persists
      // while the store keeps dismissing.
      await t.tap(find.widgetWithText(TextButton, 'Retry'));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(store.reads, 2);
      expect(find.text('Unlock to continue — approve the phone prompt.'),
          findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('stale dismiss never re-locks an unlocked shell',
        (t) async {
      // Pass-then-banner flake: the shell unlocks (prompt passed), then a
      // stale dismissed verdict lands (duplicate prompt canceled while one
      // was showing). The shell must stay on Mark — never re-lock, never
      // park, never push, never banner.
      final store = _FlakyPromptStore();
      late ProviderContainer container;
      await t.pumpWidget(helpers.testScope(
          store: store,
          home: MaterialApp(
              theme: proxLightTheme(),
              home: Builder(builder: (context) {
                container = ProviderScope.containerOf(context);
                return const StudentShell();
              }))));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      // Proven unlock: on Mark, no flow, no banner.
      expect(find.byType(StudentHomeScreen).hitTestable(), findsOneWidget);
      expect(find.byType(SetupFlowScreen), findsNothing);
      // A stale duplicate prompt verdict arrives (dismissed): the identity
      // listener re-resolves, the store replays the dismissal.
      container.read(linkedIdentityProvider.notifier).state = null;
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(find.byType(StudentHomeScreen).hitTestable(), findsOneWidget);
      expect(find.byType(SetupFlowScreen), findsNothing);
      expect(find.text('Unlock to continue — approve the phone prompt.'),
          findsNothing);
      expect(find.text('Checking enrollment…'), findsNothing);
      expect(t.takeException(), isNull);
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

/// Enrollment store that always replays a prompt dismissal while counting
/// reads (cold-open race pin: while locked, only the shell resolve itself
/// may read — display entries must stay silent).
class _CountingDismissStore extends InMemoryDeviceStore {
  int reads = 0;

  @override
  Future<StoredEnrollment?> readEnrollment() async {
    reads++;
    throw const SecureStoreDismissed();
  }
}

/// Enrollment store whose first read serves the doc (prompt passed) and
/// every later read replays a prompt dismissal (stale duplicate prompt
/// verdict stand-in): the shell must stay unlocked on Mark throughout.
class _FlakyPromptStore extends InMemoryDeviceStore {
  int reads = 0;

  @override
  Future<StoredEnrollment?> readEnrollment() async {
    reads++;
    if (reads == 1) {
      return StoredEnrollment(
        email: 'student@example.com',
        name: 'Test User',
        roll: 'R1',
        pkHex: 'cd' * 32,
        enrolledAt: DateTime.utc(2026, 1, 1),
      );
    }
    throw const SecureStoreDismissed();
  }
}

/// Enrollment store gated on a test-controlled future (slow biometric
/// read stand-in): the shell must show resolve progress while awaiting.
class _GatedEnrollStore extends InMemoryDeviceStore {
  Completer<StoredEnrollment?> gate = Completer<StoredEnrollment?>();

  @override
  Future<StoredEnrollment?> readEnrollment() => gate.future;
}

/// Enrollment store whose reads always fail transiently (flaky Keystore
/// stand-in): resolves must surface retry UI, never push, never silence.
class _FailingEnrollStore extends InMemoryDeviceStore {
  int reads = 0;

  @override
  Future<StoredEnrollment?> readEnrollment() async {
    reads++;
    throw StateError('disk full');
  }
}
