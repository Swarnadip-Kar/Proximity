// Single-app entry: Prof + Student modes in one app (per updated requirement).
// Mobile devices switch modes; desktop runs Prof mode. Identical security all OS.
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'core/auth.dart';
import 'core/enrollment.dart';
import 'core/face_camera.dart';
import 'core/roster_repo.dart';
import 'mode.dart';
import 'screens/enrollment.dart';
import 'screens/prof_home.dart';
import 'screens/role_select.dart';
import 'screens/student_home.dart';

import 'package:proximity_face/face.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(FirebaseAuthService()),
        rosterRepositoryProvider
            .overrideWithValue(FirestoreRosterRepository()),
        faceCameraProvider.overrideWithValue(RealFaceCamera()),
        enrollmentControllerProvider.overrideWith(
          (ref) => EnrollmentController(
            auth: ref.watch(authServiceProvider),
            repo: ref.watch(rosterRepositoryProvider),
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
        AppMode.prof => const ProfHomeScreen(),
        AppMode.enroll => const EnrollmentScreen(),
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
