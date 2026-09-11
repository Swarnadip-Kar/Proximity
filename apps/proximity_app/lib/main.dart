// Single-app entry: Prof + Student modes in one app (per updated requirement).
// Mobile devices switch modes; desktop runs Prof mode. Identical security all OS.
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'core/auth.dart';
import 'core/ble_radio.dart';
import 'core/cloud_sync.dart';
import 'core/device_store.dart';
import 'core/enrollment.dart';
import 'core/host_driver.dart';
import 'core/platformx.dart';
import 'core/student_driver.dart';
import 'core/sync_hook.dart';
import 'design/app_theme.dart';
import 'features/account/theme_mode.dart';
import 'screens/setup_flow_screen.dart';
import 'screens/shells.dart';
import 'features/face_identity/device_key.dart';
import 'features/face_identity/face_verifier.dart';
import 'features/face_identity/pose_gate.dart';
import 'features/records/my_attendance_screen.dart';
import 'mode.dart';
import 'routes.dart';
import 'screens/landing.dart';
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
    names: const {
      'student1@example.com': 'Student One',
      'student2@example.com': 'Student Two'
    },
    rolls: const {
      'student1@example.com': '12342210',
      'student2@example.com': '12342211'
    },
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
  // Early edge-to-edge opt-in (API <35): must land before the first frame
  // so the Activity window draws behind the system bars from launch.
  // Native MainActivity + theme flags cover the splash; this covers the
  // Flutter view. Theme-aware icon brightness is re-synced in build
  // (_syncSystemChrome). Safe on iOS/desktop/Web (ignored there).
  try {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      statusBarColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    ));
  } catch (_) {}
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
  final DeviceStore store =
      (_debugMode == 'course' || _debugMode == 'take' || _debugMode == 'prof')
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
        final sameEmail = (cachedRole['email'] ?? '').toLowerCase() ==
            currentAcct.email.toLowerCase();
        final wantRole = m == AppMode.prof ? 'prof' : 'student';
        initialMode = (sameEmail && roleHas(cachedRole, wantRole)) ? m : null;
      } else if (currentAcct == null &&
          cachedRole == null &&
          m == AppMode.prof) {
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
  // Trust stack (Tracks 2+3 L3 DI): mobile-only plugin face verifier +
  // software DKey (the HW keystore/Enclave backend plugs into the
  // DeviceKey interface — deferred platform work; until then the level is
  // NONE, which claims no tier but still marks via the flagged
  // `device-none-fallback` — same ticket/Sig_s/face/sighting checks).
  // Desktop/web records builds get the fail-closed stubs: every
  // face/key op throws before anything signs — never a mock pass.
  final FaceVerifier faceVerifier;
  final DeviceKey deviceKey;
  if (canUseFace()) {
    faceVerifier = PluginFaceVerifier();
    deviceKey = SoftwareDeviceKey();
  } else {
    faceVerifier = const UnavailableFaceVerifier();
    deviceKey = const UnavailableDeviceKey();
  }
  final LinkedIdentity? initialLinked = stored == null
      ? null
      : LinkedIdentity(
          name: stored.name,
          gmail: stored.email,
          roll: stored.roll,
          org: stored.org);
  final im = initialMode;
  // Preseed enrollment with the signed-in account so the enroll screen
  // doesn't ask for Google twice after landing sign-in.
  final preseed = currentAcct;
  runApp(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(authService),
        cloudSyncProvider
            .overrideWithValue(FirestoreCloudSync(available: firebaseReady)),
        deviceStoreProvider.overrideWithValue(store),
        faceVerifierProvider.overrideWithValue(faceVerifier),
        deviceKeyProvider.overrideWithValue(deviceKey),
        // Real pose gate: ML Kit on native, fail-closed stub on
        // records builds (conditional export in pose_gate.dart).
        poseGateProvider.overrideWithValue(MlkitPoseGate()),
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
                // Real holder check: on-device plugin verifier (L1-gated).
                verifier: ref.watch(faceVerifierProvider),
                deviceKey: ref.watch(deviceKeyProvider),
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
            // Real enrollment: plugin verifier + device key (L1-gated).
            verifier: ref.watch(faceVerifierProvider),
            deviceKey: ref.watch(deviceKeyProvider),
            preseed: preseed,
            cloud: ref.watch(cloudSyncProvider),
          ),
        ),
      ],
      child: const ProximityApp(),
    ),
  );
  // Cold-start race cover: the engine applies its own window flags while
  // attaching/drawing the first frame, which can stomp the pre-runApp
  // opt-in above (background→foreground works because resume re-asserts).
  // Re-assert once the first frame is on screen — by then the first build
  // has recorded _lastResolvedBrightness, so icon contrast stays correct.
  WidgetsBinding.instance.addPostFrameCallback((_) => _reassertEdgeToEdge());
}

class ProximityApp extends ConsumerStatefulWidget {
  const ProximityApp({super.key});

  @override
  ConsumerState<ProximityApp> createState() => _ProximityAppState();
}

/// Last applied nav-bar icon brightness (the overlay style is re-sent
/// only on theme flips, never on every build).
Brightness? _lastChromeNavBrightness;

/// Last app-resolved brightness (theme choice, not platform), reused when
/// re-asserting chrome after OS/plugin resets (resume, metrics change).
Brightness? _lastResolvedBrightness;

/// Re-assert edge-to-edge after events that reset window flags: permission
/// sheets, camera/ML plugin activities, recent-apps return, keyboard
/// open/close, gesture↔3-button switches. Forces the mode call and the
/// overlay re-send with the last app brightness (never platform brightness,
/// so an explicit Light/Dark choice keeps its icon contrast).
void _reassertEdgeToEdge() {
  try {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  } catch (_) {}
  final b = _lastResolvedBrightness ??
      WidgetsBinding.instance.platformDispatcher.platformBrightness;
  _lastChromeNavBrightness = null;
  _syncSystemChrome(b);
}

/// Edge-to-edge system chrome for the mobile shells: transparent Android
/// system navigation bar so the shell chrome flows behind 3-button nav /
/// gesture lines of any height (the layout half — extendBody + dynamic
/// MediaQuery insets — lives in the shells, which rebuild on metrics
/// change). Android-only call (the nav bar is an Android concept; iOS is
/// fullscreen by default and needs no call); desktop/Web untouched.
/// Status-bar fields stay null = unchanged. No `windowOptOutEdgeToEdge-
/// Enforcement` anywhere (that flag OPTS OUT of edge-to-edge; targetSdk
/// 36 enforces it on API 35+ and this call opts API ≤34 in — same end
/// state on every Android version).
void _syncSystemChrome(Brightness brightness) {
  if (!isAndroid) return;
  if (_lastChromeNavBrightness == brightness) return;
  _lastChromeNavBrightness = brightness;
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark,
    systemNavigationBarContrastEnforced: false,
  ));
}

/// The engine owns the flush; this only wakes it: connectivity-return edge
/// (platform hint, server probe decides), app resume, and the 15min
/// backstop while the outbox is non-empty.
class _ProximityAppState extends ConsumerState<ProximityApp>
    with WidgetsBindingObserver {
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  Future<SyncProf?> _profOf() => readSyncProf(ref);

  /// Arms the connectivity-hint subscription only where the platform
  /// plugin actually answers: a missing plugin (widget tests, Linux
  /// desktop) reports through FlutterError at EventChannel-listen time,
  /// which no stream onError can catch — so probe first with a catchable
  /// Future and skip the subscription when it refuses. No timeout here:
  /// a hung probe must not leave a wall-clock Timer pending past widget
  /// disposal (a dangling Future is harmless; a Timer fails tests). Sync
  /// still triggers on resume + backstop there; the hint is advisory.
  Future<void> _armConnectivityHint() async {
    try {
      final store = ref.read(deviceStoreProvider);
      final cloud = ref.read(cloudSyncProvider);
      syncEngine.startBackstop(store: store, cloud: cloud, profOf: _profOf);
      try {
        await Connectivity().checkConnectivity();
      } catch (_) {
        return; // No plugin on this platform — resume/backstop cover sync.
      }
      if (!mounted) return;
      // Platform hint ONLY (never trusted): a return hint schedules the
      // ~5s debounced server probe inside the engine; only a real
      // offline→online edge flushes.
      _connSub = Connectivity().onConnectivityChanged.listen(
          (List<ConnectivityResult> results) {
        final hintOnline = results.any((r) => r != ConnectivityResult.none);
        try {
          syncEngine.onConnectivityHint(hintOnline,
              store: ref.read(deviceStoreProvider),
              cloud: ref.read(cloudSyncProvider),
              profOf: _profOf);
        } catch (_) {}
        // Channel errors must never surface: the hint is advisory, the
        // server probe is ground truth.
      }, onError: (_) {});
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_armConnectivityHint());
  }

  @override
  void dispose() {
    _connSub?.cancel();
    syncEngine.stopBackstop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      try {
        syncEngine.onAppResume(
            store: ref.read(deviceStoreProvider),
            cloud: ref.read(cloudSyncProvider),
            profOf: _profOf);
      } catch (_) {}
      // Plugin activities / permission sheets / recents reset window flags.
      _reassertEdgeToEdge();
    }
  }

  // NOTE: no didChangeMetrics override here. Re-calling
  // setEnabledSystemUIMode inside didChangeMetrics triggers a new metrics
  // notification, which loops forever ("Sending viewport metrics" spam).
  // Resume + native focus handling + build-time sync cover resets.

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(appModeProvider);
    // Stale-stack reset (account scope): both shells are keyed by the
    // signed-in Gmail — the sync session covers the stream loading gap so
    // the key is stable across it — so an account switch / sign-out
    // remounts the shell and drops every per-tab Navigator stack
    // (mark/courses/account) holding the previous identity's screens.
    // `setMode(unset)` needs no key (the home swap unmounts the shells);
    // lock-transition parking + the single setup-flow push stay owned by
    // the shells' gate (read-only here).
    String shellAccount = '';
    try {
      shellAccount = ref
              .watch(accountProvider)
              .valueOrNull
              ?.email
              .trim()
              .toLowerCase() ??
          '';
    } catch (_) {}
    if (shellAccount.isEmpty) {
      try {
        shellAccount =
            ref.watch(authServiceProvider).current?.email.trim().toLowerCase() ??
                '';
      } catch (_) {}
    }
    if (shellAccount.isEmpty) shellAccount = 'signed-out';
    // Account-section addition: the persisted Dark/Light/System choice
    // (features/account/theme_mode.dart). Defaults to system.
    final themeMode = ref.watch(themeModeProvider);
    final resolvedBrightness = switch (themeMode) {
      ThemeMode.dark => Brightness.dark,
      ThemeMode.light => Brightness.light,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };
    // Theme-aware nav-bar icon contrast for the transparent system bar
    // (cached inside; no-op off Android).
    _lastResolvedBrightness = resolvedBrightness;
    _syncSystemChrome(resolvedBrightness);
    return MaterialApp(
      title: 'Proximity',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
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
        // Native students land on the 3-tab shell (Mark gate inside).
        AppMode.student => kIsWeb
            ? const MyAttendanceScreen()
            : StudentShell(key: ValueKey('student-shell-$shellAccount')),
        // Professor 3-tab shell (Live/Courses/Account).
        AppMode.prof =>
            ProfShell(key: ValueKey('prof-shell-$shellAccount')),
        // Fresh-install entry: the ONE serialized setup flow (the
        // Mark-gate path pushes this same screen onto the Mark tab).
        AppMode.enroll => SetupFlowScreen(
            onFirstBack: () async {
              // The flow is the app home here: nothing above Account
              // exists yet — hint instead of landing on a bare screen.
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Complete setup to continue'),
                  duration: Duration(seconds: 2),
                ));
              }
            },
            onComplete: () async {
              // Claim done → land on mark/browse, never the roles hub.
              // Mounted-guarded: the flow may have been dismissed under us
              // before completion lands.
              if (!context.mounted) return;
              await setMode(ref, AppMode.student);
            },
          ),
        AppMode.take => const TakeAttendanceScreen(courseName: 'CS201'),
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

  /// Explicit leading widget (e.g. a Leave-with-save back button). Null
  /// keeps the platform default (automatic back affordance) everywhere —
  /// existing callers are unaffected.
  final Widget? leading;

  /// Optional floating action button. Passed through to Material Scaffold.
  final Widget? floatingActionButton;

  const AdaptiveScaffold(
      {super.key,
      required this.title,
      required this.body,
      this.actions,
      this.leading,
      this.floatingActionButton});

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final cupertino =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    if (!cupertino) {
      // Mobile edge-to-edge: scaffold background + AppBar bleed behind the
      // transparent system bars (see _syncSystemChrome + android styles).
      // Inset handling lives in the bodies, not here: tab roots clear via
      // the shell's _ShellEdgeBody, landing/capture chrome seat their own
      // bottom SafeAreas (all viewPadding-driven, zero hardcoded values).
      // extendBody is a no-op without a bottom bar but keeps the contract
      // explicit; desktop/Web have zero system insets so render unchanged.
      return Scaffold(
        extendBody: isMobile,
        appBar: AppBar(title: Text(title), actions: actions, leading: leading),
        body: body,
        floatingActionButton: floatingActionButton,
      );
    }
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(title),
        leading: leading,
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
