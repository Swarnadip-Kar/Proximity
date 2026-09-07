// Single-app entry: Prof + Student modes in one app (per updated requirement).
// Mobile devices switch modes; desktop runs Prof mode. Identical security all OS.
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_face/face.dart';

import 'firebase_options.dart';
import 'core/auth.dart';
import 'core/ble_radio.dart';
import 'core/cloud_sync.dart';
import 'core/device_store.dart';
import 'core/edgeface.dart';
import 'core/enrollment.dart';
import 'core/face_detect.dart';
import 'core/face_camera.dart';
import 'core/host_driver.dart';
import 'core/student_driver.dart';
import 'design/app_theme.dart';
import 'features/enrollment/enroll_intro.dart';
import 'features/records/my_attendance_screen.dart';
import 'features/records/prof_courses_screen.dart';
import 'mode.dart';
import 'routes.dart';
import 'screens/landing.dart';
import 'screens/student_home.dart';
import 'screens/take_attendance.dart';

import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

/// No-sign preview flags (simulator UI polish without taps/accounts):
/// PROX_MODE=student|prof|enroll|take shows that screen directly;
/// prof/course/take seed demo courses + history.
const _debugMode = String.fromEnvironment('PROX_MODE', defaultValue: 'unset');

Future<DeviceStore> _debugSeededStore() async {
  final store = InMemoryDeviceStore();
  await store.addCourse('CS201');
  await store.addCourse('CS202');
  await store.appendHistory(ClassRecord(
    courseId: 'CS201',
    classLabel: 'CS201',
    dateIso: '2026-09-03',
    w1: const {'student1@example.com': true, 'student2@example.com': false},
    w2: const {'student1@example.com': true, 'student2@example.com': true},
    names: const {'student1@example.com': 'Student One', 'student2@example.com': 'Student Two'},
    rolls: const {'student1@example.com': '12342210', 'student2@example.com': '12342211'},
  ));
  await store.appendHistory(ClassRecord(
    courseId: 'CS202',
    classLabel: 'CS202',
    dateIso: '2026-09-04',
    w1: const {'student1@example.com': true},
    w2: const {'student1@example.com': false},
    names: const {'student1@example.com': 'Student One'},
    rolls: const {'student1@example.com': '12342210'},
  ));
  return store;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase is Android/iOS/macOS only (firebase_options throws
  // UnsupportedError on Windows/Linux/web). Fail-soft: the app still
  // starts offline — professors can host locally; sign-in screens explain
  // the platform limit instead of crashing on startup.
  var firebaseReady = false;
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    firebaseReady = true;
  } catch (_) {
    firebaseReady = false;
  }
  // Restore linked identity from secure device storage so sign-in state
  // (Firebase Auth) + identity survive restarts with zero taps.
  // Fail-open: secure storage may be unavailable (e.g. unsigned sim
  // builds) — the app still starts, user simply enrolls.
  final DeviceStore store = (_debugMode == 'course' ||
          _debugMode == 'take' ||
          _debugMode == 'prof')
      ? await _debugSeededStore()
      : SecureDeviceStore();
  StoredEnrollment? stored;
  try {
    stored = await store.readEnrollment();
  } catch (_) {
    stored = null;
  }
  // Restore the last-used mode (preview flag wins when given).
  // One Gmail may hold BOTH roles now: routing only checks that the cached
  // roles belong to the currently signed-in account AND include the saved
  // mode's role — never locks the user to a single mode. Offline professors
  // (skipped sign-in) restore by mode.
  String? savedMode;
  try {
    savedMode = await store.readMode();
  } catch (_) {}
  Map<String, String>? cachedRole;
  try {
    cachedRole = await store.readRole();
  } catch (_) {}
  final authService = FirebaseAuthService(available: firebaseReady);
  SignedAccount? currentAcct;
  try {
    currentAcct = authService.current;
  } catch (_) {}
  AppMode? initialMode;
  if (!hasPreviewMode) {
    final m = modeFromName(savedMode);
    if (m != null) {
      if (currentAcct != null && cachedRole != null) {
        final sameEmail =
            (cachedRole['email'] ?? '').toLowerCase() ==
                currentAcct.email.toLowerCase();
        final wantRole = m == AppMode.prof ? 'prof' : 'student';
        initialMode =
            (sameEmail && roleHas(cachedRole, wantRole)) ? m : null;
      } else if (currentAcct == null && cachedRole == null && m == AppMode.prof) {
        initialMode = m; // offline professor who skipped sign-in
      } else {
        initialMode = null; // landing decides
      }
    }
  }
  // One shared BLE engine (radio selected per OS at startup).
  final bleEngine = ProxBleEngine(radio: platformRadio());
  // Radio-readiness gate: a scan started while Bluetooth is off defers
  // instead of dying (engine restarts it when BT powers on). Only the
  // certain off state defers — on/unavailable (desktop, sims, BlueZ
  // shim) keep the old fail-fast semantics.
  bleEngine.radioReady = () async {
    try {
      return await bluetoothState() != BtState.off;
    } catch (_) {
      return true;
    }
  };
  // Real face stack, loaded once: BlazeFace detect+align feeding the
  // vendored EdgeFace-XS TFLite. Fail-closed when a model file is missing
  // (face checks throw FaceModelMissing; SK never signs) — never a mock
  // pass in production. Web records builds never check faces: mock
  // embedder + fake detector (no camera/BLE UI exists there).
  final FaceEmbedder faceEmbedder;
  final FaceDetector faceDetector;
  if (kIsWeb) {
    faceEmbedder = MockFaceEmbedder(
      enrolled: const [1, 0, 0, 0],
      probe: const [1, 0, 0, 0],
    );
    faceDetector = FakeFaceDetector();
  } else {
    final real = await loadFaceEmbedder();
    faceEmbedder = real;
    faceDetector = real.detector;
  }
  final LinkedIdentity? initialLinked = stored == null
      ? null
      : LinkedIdentity(
          name: stored.name, gmail: stored.email, roll: stored.roll);
  final im = initialMode;
  // Preseed enrollment with the signed-in account so the enroll screen
  // doesn't ask for Google twice after landing sign-in.
  final preseed = currentAcct;
  runApp(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(authService),
        cloudSyncProvider.overrideWithValue(
            FirestoreCloudSync(available: firebaseReady)),
        deviceStoreProvider.overrideWithValue(store),
        faceCameraProvider.overrideWithValue(RealFaceCamera()),
        // Shared BlazeFace detector (loaded once with the embedder above;
        // fake on web records builds).
        faceDetectorProvider.overrideWithValue(faceDetector),
        hostDriverProvider.overrideWith((ref) => kIsWeb
            ? FakeHostDriver()
            : RealHostDriver(
                store: ref.watch(deviceStoreProvider),
                engine: bleEngine,
              )),
        studentDriverProvider.overrideWith((ref) => kIsWeb
            ? FakeStudentDriver()
            : RealStudentDriver(
                store: ref.watch(deviceStoreProvider),
                // Real holder check: vendored EdgeFace-XS (loaded above).
                embedder: faceEmbedder,
                engine: bleEngine,
              )),
        bleEngineProvider.overrideWithValue(bleEngine),
        if (initialLinked != null)
          linkedIdentityProvider.overrideWith((ref) => initialLinked),
        if (im != null) appModeProvider.overrideWith((ref) => im),
        enrollmentControllerProvider.overrideWith(
          (ref) => EnrollmentController(
            auth: ref.watch(authServiceProvider),
            store: ref.watch(deviceStoreProvider),
            // Real enrollment embedding: vendored EdgeFace-XS (loaded above).
            embedder: faceEmbedder,
            preseed: preseed,
            cloud: ref.watch(cloudSyncProvider),
          ),
        ),
      ],
      child: const ProximityApp(),
    ),
  );
}

class ProximityApp extends ConsumerWidget {
  const ProximityApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(appModeProvider);
    return MaterialApp(
      title: 'Proximity',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      // Phase 1 visual identity: one theme from the design tokens —
      // Space Grotesk display + Inter body, intentional palette.
      theme: proxLightTheme(),
      darkTheme: proxDarkTheme(),
      // Route table wired (entry/enroll/records → feature bundle; live/mark
      // sections → their host shells which retain orchestration). `home` +
      // PROX_MODE previews still drive launch; every push/pop logs NAV via
      // the observer. Web records-only guards live in the table (native-only
      // deep-links → records on web) with per-screen banners as second gate.
      routes: buildProxRoutes(),
      onGenerateRoute: proxOnGenerateRoute,
      onUnknownRoute: proxOnUnknownRoute,
      navigatorObservers: [ProxRouteObserver()],
      home: switch (mode) {
        // Thin entry router: Welcome (signed out) vs RoleHub (signed in).
        AppMode.unset => const LandingScreen(),
        // Web records builds never mark: students land on records.
        AppMode.student =>
          kIsWeb ? const MyAttendanceScreen() : const StudentHomeScreen(),
        AppMode.prof => const ProfCoursesScreen(),
        // Bundle entry (pre-context + account + key); capture/result follow.
        AppMode.enroll => const EnrollIntroScreen(),
        AppMode.take =>
          const TakeAttendanceScreen(courseName: 'CS201'),
      },
    );
  }
}

/// Cupertino-adaptive scaffold helper: uses CupertinoPageScaffold on iOS/macOS
/// when [adaptive] is true, Material Scaffold elsewhere. Same flow all OS.
class AdaptiveScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget>? actions;
  const AdaptiveScaffold(
      {super.key, required this.title, required this.body, this.actions});

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final cupertino =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    if (!cupertino) {
      return Scaffold(
        appBar: AppBar(title: Text(title), actions: actions),
        body: body,
      );
    }
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(title),
        trailing: actions == null
            ? null
            : Row(mainAxisSize: MainAxisSize.min, children: actions!),
      ),
      // Transparent Material ancestor so the single shared body (ListTile,
      // TextField, buttons) works identically under Cupertino navigation.
      // Same flow, same widgets, all OS.
      child: SafeArea(
        child: Material(type: MaterialType.transparency, child: body),
      ),
    );
  }
}
