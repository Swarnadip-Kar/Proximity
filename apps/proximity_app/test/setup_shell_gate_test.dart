// Navigation-shell + Setup-flow widget contracts (§3.1/§3.3/§3.4/§3.5):
// shells render 3 tabs with token chrome, the Mark gate routes unenrolled
// students into the SetupFlowScreen (never bare mark/browse), the flow
// starts at the first incomplete step, and the courses/mine alias builds
// the records screen.
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
import 'package:proximity_app/features/records/my_attendance_screen.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/routes.dart';
import 'package:proximity_app/features/setup/setup_step_scope.dart';
import 'package:proximity_app/screens/setup_flow_screen.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_app/screens/student_home.dart';
import 'package:proximity_ble/ble.dart';

const _linked = LinkedIdentity(
    name: 'Test User', gmail: 'student@example.com', roll: 'R1');

/// Shell tests pump the shells directly (not the full ProximityApp): the
/// sync host owns its own timers and is untouched by this section.
List<Override> _shellOverrides({
  String? email = 'student@example.com',
  LinkedIdentity? linked,
}) {
  return [
    authServiceProvider.overrideWithValue(FakeAuthService(
        email == null
            ? null
            : SignedAccount(
                email: email, displayName: 'Test User', uid: 'test-uid'))),
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

Widget _shellApp({required Widget home, List<Override>? extra}) {
  return ProviderScope(
    overrides: [
      ..._shellOverrides(),
      ...?extra,
    ],
    child: MaterialApp(theme: proxLightTheme(), home: home),
  );
}

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

  group('student shell', () {
    testWidgets('3 tabs render; unenrolled Mark routes into setup flow',
        (t) async {
      await t.pumpWidget(_shellApp(home: const StudentShell()));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }

      // Bottom bar: Mark · Courses · Account (wide test surface).
      expect(find.widgetWithText(BottomNavigationBar, 'Mark'), findsOneWidget);
      expect(
          find.widgetWithText(BottomNavigationBar, 'Courses'), findsOneWidget);
      expect(
          find.widgetWithText(BottomNavigationBar, 'Account'), findsOneWidget);

      // Mark gate: unenrolled → SetupFlowScreen at sign-in, never bare
      // mark/browse (no StudentHomeScreen visible above the flow).
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      expect(find.byType(StudentShell), findsOneWidget);
      expect(find.widgetWithText(BottomNavigationBar, 'Mark'), findsOneWidget);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });

    testWidgets('enrolled student lands on mark/browse', (t) async {
      await t.pumpWidget(ProviderScope(
        overrides: [
          ..._shellOverrides(),
          linkedIdentityProvider.overrideWith((ref) => _linked),
        ],
        child:
            MaterialApp(theme: proxLightTheme(), home: const StudentShell()),
      ));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }

      expect(find.byType(StudentHomeScreen), findsOneWidget);
      expect(find.byType(SetupFlowScreen), findsNothing);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });
  });

  group('professor shell', () {
    testWidgets('Live · Courses · Account with empty live root', (t) async {
      await t.pumpWidget(_shellApp(home: const ProfShell()));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }

      expect(find.widgetWithText(BottomNavigationBar, 'Live'), findsOneWidget);
      expect(
          find.widgetWithText(BottomNavigationBar, 'Courses'), findsOneWidget);
      expect(
          find.widgetWithText(BottomNavigationBar, 'Account'), findsOneWidget);
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

  group('router aliases + mark gate', () {
    testWidgets('courses/mine alias builds the records screen', (t) async {
      final builder = buildProxRoutes()[ProxRoutes.coursesMine];
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

    testWidgets('mark/browse gated when unenrolled', (t) async {
      final builder = buildProxRoutes()[ProxRoutes.browse];
      expect(builder, isNotNull);
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
              email: 'student@example.com',
              displayName: 'Test User',
              uid: 'test-uid'))),
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
          home: Builder(builder: (c) => builder!(c)),
        ),
      ));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      // Gate, not bare mark.
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      expect(find.byType(StudentHomeScreen), findsNothing);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });

    testWidgets('mark/browse passes through when enrolled', (t) async {
      final builder = buildProxRoutes()[ProxRoutes.browse];
      expect(builder, isNotNull);
      await t.pumpWidget(ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
              email: 'student@example.com',
              displayName: 'Test User',
              uid: 'test-uid'))),
          cloudSyncProvider.overrideWithValue(FakeCloudSync()),
          deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
          hostDriverProvider.overrideWithValue(FakeHostDriver()),
          studentDriverProvider
              .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
          bleEngineProvider
              .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
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
        child: MaterialApp(
          theme: proxLightTheme(),
          home: Builder(builder: (c) => builder!(c)),
        ),
      ));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(find.byType(StudentHomeScreen), findsOneWidget);
      expect(find.byType(SetupFlowScreen), findsNothing);
      // Drain stagger one-shots (stepped: lets each tick settle).
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
    });
  });
}
