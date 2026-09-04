// Single-app entry: Prof + Student modes in one app (per updated requirement).
// Mobile devices switch modes; desktop runs Prof mode. Identical security all OS.
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'core/auth.dart';
import 'core/ble_radio.dart';
import 'core/device_store.dart';
import 'core/enrollment.dart';
import 'core/face_camera.dart';
import 'core/host_driver.dart';
import 'core/roster_repo.dart';
import 'core/student_driver.dart';
import 'mode.dart';
import 'screens/courses.dart';
import 'screens/enrollment.dart';
import 'screens/role_select.dart';
import 'screens/student_home.dart';
import 'screens/take_attendance.dart';

import 'package:proximity_ble/ble.dart';
import 'package:proximity_face/face.dart';
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
    w1: const {'aarav@x.in': true, 'diya@x.in': false},
    w2: const {'aarav@x.in': true, 'diya@x.in': true},
    names: const {'aarav@x.in': 'Aarav S', 'diya@x.in': 'Diya R'},
    rolls: const {'aarav@x.in': '12342210', 'diya@x.in': '12342211'},
  ));
  await store.appendHistory(ClassRecord(
    courseId: 'CS202',
    classLabel: 'CS202',
    dateIso: '2026-09-04',
    w1: const {'aarav@x.in': true},
    w2: const {'aarav@x.in': false},
    names: const {'aarav@x.in': 'Aarav S'},
    rolls: const {'aarav@x.in': '12342210'},
  ));
  return store;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
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
  // Restore the saved profile mode (preview flag wins when given).
  String? savedMode;
  try {
    savedMode = await store.readMode();
  } catch (_) {}
  final AppMode? initialMode =
      hasPreviewMode ? null : modeFromName(savedMode);
  // One shared BLE engine (radio selected per OS at startup).
  final bleEngine = ProxBleEngine(radio: platformRadio());
  final LinkedIdentity? initialLinked = stored == null
      ? null
      : LinkedIdentity(
          name: stored.name, gmail: stored.email, roll: stored.roll);
  runApp(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(FirebaseAuthService()),
        rosterRepositoryProvider
            .overrideWithValue(FirestoreRosterRepository()),
        deviceStoreProvider.overrideWithValue(store),
        faceCameraProvider.overrideWithValue(RealFaceCamera()),
        hostDriverProvider.overrideWith((ref) => RealHostDriver(
              store: ref.watch(deviceStoreProvider),
              repo: ref.watch(rosterRepositoryProvider),
              engine: bleEngine,
            )),
        studentDriverProvider.overrideWith((ref) => RealStudentDriver(
              store: ref.watch(deviceStoreProvider),
              // TODO(P1-face): EdgeFace-XS embedder; mock probe until then.
              embedder: MockFaceEmbedder(
                enrolled: const [1, 0, 0, 0],
                probe: const [1, 0, 0, 0],
              ),
              engine: bleEngine,
            )),
        bleEngineProvider.overrideWithValue(bleEngine),
        if (initialLinked != null)
          linkedIdentityProvider.overrideWith((ref) => initialLinked),
        if (initialMode != null)
          appModeProvider.overrideWith((ref) => initialMode),
        enrollmentControllerProvider.overrideWith(
          (ref) => EnrollmentController(
            auth: ref.watch(authServiceProvider),
            repo: ref.watch(rosterRepositoryProvider),
            store: ref.watch(deviceStoreProvider),
            // TODO(P1-face): camera frames + EdgeFace-XS embedder. Mock
            // returns a fixed probe so the flow is testable end-to-end.
            embedder: MockFaceEmbedder(
              enrolled: const [1, 0, 0, 0],
              probe: const [1, 0, 0, 0],
            ),
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
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4F46E5),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF4F46E5),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: switch (mode) {
        AppMode.unset => const RoleSelectScreen(),
        AppMode.student => const StudentHomeScreen(),
        AppMode.prof => const ProfCoursesScreen(),
        AppMode.enroll => const EnrollmentScreen(),
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
