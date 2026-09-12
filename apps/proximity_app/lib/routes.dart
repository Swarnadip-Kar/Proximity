// Proximity named-route table (foundation track shared infra).
//
// Approved IA, one line per node. Names use the bundle convention already
// established in the tree (bare `bundle/page`, no leading slash — matches
// `EnrollNav.routePrefix` so `popUntil` prefix matches keep working):
//
//   Entry:          welcome · roles · device
//   Prof setup:     prof/courses · prof/courses/<course> (overview)
//                   prof/courses/<course>/export (in-tab drill-down only;
//                   named session/course deep-links are unsupported)
//   Prof live:      live/<course> (Take host; any section suffix lands
//                   on the host — no standalone section screens)
//   Student mark:   (in-tab only — no named routes; the shell lock +
//                   root-navigator SetupFlowScreen auto-push is the gate)
//   Enroll:         enroll/capture · enroll/result (the standalone intro
//                   route is deleted with the legacy bundle entry; the
//                   serialized SetupFlowScreen is the only enrollment flow
//                   and embeds the capture/result screens as steps)
//   Records:        records/mine (in-tab drill-down only; named
//                   course deep-links are unsupported)
//   Account:         account/face-id (isolated status page; the
//                   consolidated account page is the tab root in shells)
//   Shared:         debug/log (filterable full-screen terminal)
//
// Status: wired. Entry/enroll/debug/records + prof setup builders
// point at the feature bundle screens; live paths build the Take host
// (it owns hosting/window/draft orchestration); mark lives in-tab in the
// shell (phases, not pages; take_attendance +
// `MaterialApp.home` + `PROX_MODE` previews + web records-only behavior
// are preserved (see `main.dart` wiring).
//
// In-tab drill-down is the only supported entry: named deep-links are
// unsupported (no intent-filters/URL handlers). In-tab pushes resolve
// their record objects from the store directly; unknown names render
// guidance + NAV log, never a crash.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:proximity_ble/ble.dart';

import 'core/platformx.dart';
import 'features/face_identity/face_blocked.dart';
import 'design/tokens.dart';
import 'features/account/face_id_screen.dart';
import 'features/debug/debug_log_screen.dart';
import 'features/setup/enroll_capture.dart';
import 'features/setup/enroll_result.dart';
import 'features/setup/device_identity_screen.dart';
import 'features/setup/welcome_screen.dart';
import 'features/records/course_overview_screen.dart';
import 'features/records/export_center_screen.dart';
import 'features/records/my_attendance_screen.dart';
import 'features/records/prof_courses_screen.dart';
import 'screens/landing.dart';
import 'screens/take_attendance.dart';
import 'widgets/prox_buttons.dart';
import 'widgets/prox_scaffold.dart';
import 'widgets/prox_states.dart';

/// Deep-link arguments. Plain data (course/session ids + section hint) so
/// `pushNamed` stays serializable and loggable; the router never ferries
/// record objects (screen tracks resolve those from the store).
class ProxRouteArgs {
  final String course;
  final String sessionId;
  final String section;
  const ProxRouteArgs(
      {this.course = '', this.sessionId = '', this.section = ''});

  static ProxRouteArgs fromSettings(RouteSettings settings) {
    final a = settings.arguments;
    if (a is ProxRouteArgs) return a;
    if (a is Map) {
      return ProxRouteArgs(
        course: '${a['course'] ?? ''}',
        sessionId: '${a['sessionId'] ?? ''}',
        section: '${a['section'] ?? ''}',
      );
    }
    return const ProxRouteArgs();
  }

  /// Reproducing context for NAV/STATE log lines (ids only, no keys/faces).
  String get summary => [
        if (course.isNotEmpty) 'course=$course',
        if (sessionId.isNotEmpty) 'session=$sessionId',
        if (section.isNotEmpty) 'section=$section',
      ].join(' ');
}

/// Canonical IA paths. Static nodes are constants; parameterized nodes
/// are builders so call sites read as the IA (`ProxRoutes.live('CS201')`).
abstract final class ProxRoutes {
  // Entry.
  static const welcome = 'welcome';
  static const roles = 'roles';
  static const device = 'device';

  // Prof setup.
  static const profCourses = 'prof/courses';

  // Prof live (Take tab is the single host).
  static String live(String course) => 'live/$course';

  // Enroll (identical strings to EnrollFlow — one convention, not two).
  static const enrollCapture = 'enroll/capture';
  static const enrollResult = 'enroll/result';

  // Still-capture sheet (RealStillCapturer — marking + enrollment angles).
  // Named so EnrollNav.finish pops it with the bundle; native-only so the
  // web records build redirects instead of landing on a dead camera.
  static const faceCapture = 'face/capture';

  // Records.
  static const myAttendance = 'records/mine';

  // Account (one consolidated page is the tab root; face-id stays its own
  // pushed page per §5.2 so the never-preview rule can't inherit stray
  // image chrome — in-tab push already names this; the table entry makes
  // deep-links resolve too).
  static const faceId = 'account/face-id';

  // Shared.
  static const debugLog = 'debug/log';

  /// Routes that need native capabilities (BLE, camera/face, hosting,
  /// enrollment claim). The web records build never marks: entry, records
  /// and the debug terminal degrade or render everywhere; everything here
  /// redirects (see [webGuardRedirect]) instead of landing on a dead end.
  /// Kept alongside [isMobileOnly] deliberately: this gate is about the
  /// *web* records build (which cannot host BLE/HTTPS either), while
  /// isMobileOnly is about the *face/device trust stack* (desktop can
  /// host live/* fine, but can never enroll). Different sets,
  /// different reasons — collapsing them would wrongly block desktop
  /// hosting or wrongly allow desktop enrollment.
  /// Pure — unit-testable without widgets.
  // enroll/intro + mark/* intentionally absent from both guard sets
  // (deleted routes — no named routes; mark lives in-tab only).
  static bool isNativeOnly(String name) =>
      name == enrollCapture ||
      name == enrollResult ||
      name == faceCapture ||
      name.startsWith('live/');

  /// Web records-only guard: the fallback deep-link for native-only paths
  /// on web, null when the path may render. Screens ALSO carry their own
  /// banners/hidden actions, so this is defense in depth, not the only
  /// gate. Pure — unit-testable without widgets.
  static String? webGuardRedirect(String name) =>
      (kIsWeb && isNativeOnly(name)) ? myAttendance : null;

  /// Mobile-only set (Tracks 2+3 L2): enrollment needs the
  /// on-device face/device trust stack (plugin + HW key), which exists
  /// only on Android/iOS. Professors hosting live/* stay available on
  /// desktop (no face needed there) — only enroll/* redirects.
  /// Pure — unit-testable without widgets.
  static bool isMobileOnly(String name) => name.startsWith('enroll/');

  /// Records-only-device guard: mobile-only deep-links on desktop/web land
  /// on records/mine with a guidance card instead of a dead end. Takes an
  /// explicit [mobile] (defaults to the live [canUseFace]) so tests pin
  /// the matrix without platform overrides. Pure — unit-testable.
  static String? mobileGuardRedirect(String name, {bool? mobile}) =>
      (isMobileOnly(name) && !(mobile ?? canUseFace())) ? myAttendance : null;
}

/// Navigator observer that logs every route event NAV (pushes, pops,
/// replaces — named or ad-hoc `MaterialPageRoute`). Unnamed pushes log
/// their widget type so the pre-migration screens are visible too.
/// Route traffic is low-volume; no throttling needed.
class ProxRouteObserver extends NavigatorObserver {
  String _label(Route<dynamic>? route) {
    if (route == null) return 'null';
    final name = route.settings.name;
    final args = ProxRouteArgs.fromSettings(route.settings).summary;
    final what =
        (name != null && name.isNotEmpty) ? name : route.runtimeType.toString();
    return args.isEmpty ? what : '$what ($args)';
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    BleLog.log(ProxLogTags.nav, '→ ${_label(route)}');
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    BleLog.log(ProxLogTags.nav, '← ${_label(route)}');
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    BleLog.log(ProxLogTags.nav, '× ${_label(route)}');
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    BleLog.log(ProxLogTags.nav, '⇄ ${_label(oldRoute)} ⇒ ${_label(newRoute)}');
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

/// Guidance page for mobile-only flows opened on records-only devices
/// (Tracks 2+3 L2): the redirect target of [ProxRoutes.mobileGuardRedirect].
/// Explains the mobile requirement; records below are unaffected.
class MobileOnlyGuidanceScreen extends StatelessWidget {
  final String route;
  const MobileOnlyGuidanceScreen({super.key, required this.route});

  @override
  Widget build(BuildContext context) {
    final flow = route.startsWith('enroll/') ? 'Face enrollment' : 'Marking';
    return ProxScreen(
      title: 'Mobile only',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaceBlockedCard(flow: flow),
          const SizedBox(height: 12),
          ProxSecondaryButton(
            label: const Text('Open my records'),
            // Replace (never push): back from records must not loop
            // back onto guidance.
            onPressed: () =>
                ProxNav.replaceNamed(context, ProxRoutes.myAttendance),
          ),
        ],
      ),
    );
  }
}

/// Guidance page for unknown/missing deep-links. Logs STATE with the
/// missing context so a miss is debuggable, never silent.
class ProxRoutePlaceholder extends StatelessWidget {
  final String title;
  final String detail;
  const ProxRoutePlaceholder(
      {super.key, required this.title, required this.detail});

  @override
  Widget build(BuildContext context) {
    return ProxScreen(
      title: title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ProxEmptyState(message: title, icon: Icons.route_outlined),
          ProxSyncNote(detail),
        ],
      ),
    );
  }
}

/// Guard wrapper for exact-table builders: web + mobile guards run BEFORE
/// the table so exact names cannot bypass them (`MaterialApp.routes` wins
/// over `onGenerateRoute`, and the in-tab router does an exact lookup
/// first too). Guarded names render records/guidance, never the inner
/// screen. Pure at lookup time except the live platform reads inside the
/// guard predicates (tests pin the matrix via platform overrides).
WidgetBuilder _guardedRoute(String name, WidgetBuilder inner) {
  return (BuildContext context) {
    final web = ProxRoutes.webGuardRedirect(name);
    if (web != null) {
      BleLog.log(ProxLogTags.nav, 'web guard (table): $name ⇒ $web');
      return const MyAttendanceScreen();
    }
    final mobile = ProxRoutes.mobileGuardRedirect(name);
    if (mobile != null) {
      BleLog.log(ProxLogTags.nav, 'mobile guard (table): $name ⇒ guidance');
      return MobileOnlyGuidanceScreen(route: name);
    }
    return inner(context);
  };
}

/// Exact-name table for `MaterialApp.routes`. Parameterized IA nodes live
/// in [proxOnGenerateRoute]; unknown names fall to [proxOnUnknownRoute].
Map<String, WidgetBuilder> buildProxRoutes() => {
      // Entry (feature screens; landing is a thin Welcome-vs-RoleHub router).
      ProxRoutes.welcome:
          _guardedRoute(ProxRoutes.welcome, (_) => const WelcomeScreen()),
      ProxRoutes.roles:
          _guardedRoute(ProxRoutes.roles, (_) => const LandingScreen()),
      ProxRoutes.device: _guardedRoute(
          ProxRoutes.device, (_) => const DeviceIdentityScreen()),
      // Prof setup (records bundle — self-sufficient, absorbs the old
      // course page split: picker + overview + export + detail/edit).
      ProxRoutes.profCourses: _guardedRoute(
          ProxRoutes.profCourses, (_) => const ProfCoursesScreen()),
      // Enroll (feature bundle; same names EnrollFlow pushes).
      ProxRoutes.enrollCapture: _guardedRoute(
          ProxRoutes.enrollCapture, (_) => const EnrollCaptureScreen()),
      ProxRoutes.enrollResult: _guardedRoute(
          ProxRoutes.enrollResult, (_) => const EnrollResultScreen()),
      // Records (bundle — absorbs the old my-attendance + student-course).
      ProxRoutes.myAttendance: _guardedRoute(
          ProxRoutes.myAttendance, (_) => const MyAttendanceScreen()),
      // Account: face-id stays its own route (see ProxRoutes.faceId) —
      // the consolidated account page itself is the tab root in shells.
      ProxRoutes.faceId:
          _guardedRoute(ProxRoutes.faceId, (_) => const FaceIdScreen()),
      // Shared.
      ProxRoutes.debugLog:
          _guardedRoute(ProxRoutes.debugLog, (_) => const DebugLogScreen()),
    };

/// Parameterized IA nodes (`live/<course>[/section]` and
/// `prof/courses/<course>[/export]`). Returns null when [settings.name]
/// is not an IA path so `onUnknownRoute` handles it.
Route<dynamic>? proxOnGenerateRoute(RouteSettings settings) {
  final name = settings.name ?? '';
  final args = ProxRouteArgs.fromSettings(settings);

  // Web records-only guard first: native-only deep-links land on records
  // instead of a screen whose actions are all hidden on web.
  final redirect = ProxRoutes.webGuardRedirect(name);
  if (redirect != null) {
    BleLog.log(ProxLogTags.nav, 'web guard: $name ⇒ $redirect');
    return MaterialPageRoute(
      settings: RouteSettings(name: redirect, arguments: settings.arguments),
      builder: (_) => const MyAttendanceScreen(),
    );
  }

  // Tracks 2+3 L2 mobile guard: enroll/* needs the on-device
  // face/device stack (Android/iOS only). Records-only devices land on
  // guidance, never a dead camera screen.
  final mobileRedirect = ProxRoutes.mobileGuardRedirect(name);
  if (mobileRedirect != null) {
    BleLog.log(ProxLogTags.nav, 'mobile guard: $name ⇒ guidance');
    return MaterialPageRoute(
      settings: RouteSettings(name: name, arguments: settings.arguments),
      builder: (_) => MobileOnlyGuidanceScreen(route: name),
    );
  }

  // Prof live: the Take tab hosts the single live screen (it owns
  // hosting/window/draft orchestration). Any section suffix lands on the
  // host — there are no standalone section screens.
  if (name.startsWith('live/')) {
    final rest = name.substring('live/'.length);
    // Explicit empty handling: `live/` with no course is malformed —
    // never fall back to args, let onUnknownRoute render guidance.
    if (rest.isEmpty) {
      BleLog.log(ProxLogTags.nav, 'live deep-link missing course — unknown');
      return null;
    }
    final pathCourse = rest.split('/').first;
    if (pathCourse.isEmpty) {
      BleLog.log(ProxLogTags.nav, 'live deep-link missing course — unknown');
      return null;
    }
    // Path segment wins on args conflict (the path is the address);
    // a mismatch is logged, never silent.
    final argCourse = args.course;
    if (argCourse.isNotEmpty && argCourse != pathCourse) {
      BleLog.log(ProxLogTags.nav,
          'live deep-link mismatch args=$argCourse path=$pathCourse — prefer path');
    }
    final course = pathCourse;
    BleLog.log(ProxLogTags.nav, 'live deep-link course=$course');
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => TakeAttendanceScreen(courseName: course),
    );
  }

  // Prof setup: overview owns managing the course; the export center owns
  // review/export of the past (in-tab drill-down only).
  if (name.startsWith('prof/courses/')) {
    final rest = name.substring('prof/courses/'.length);
    // Explicit trailing-slash handling: ignore empty segments so
    // `CS101/` == `CS101` and `CS101/export/` == `CS101/export`.
    final segs = rest.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) {
      BleLog.log(
          ProxLogTags.nav, 'course deep-link missing course — unknown');
      return null;
    }
    // Same prefer-path rule as live/: the path is the address.
    final pathCourse = segs.first;
    final argCourse = args.course;
    if (argCourse.isNotEmpty && argCourse != pathCourse) {
      BleLog.log(ProxLogTags.nav,
          'course deep-link mismatch args=$argCourse path=$pathCourse — prefer path');
    }
    final course = pathCourse;
    if (segs.length > 1 && segs.last == 'export') {
      BleLog.log(ProxLogTags.nav, 'export deep-link course=$course');
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => ExportCenterScreen(courseName: course),
      );
    }
    BleLog.log(ProxLogTags.nav, 'course deep-link course=$course');
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => CourseOverviewScreen(courseName: course),
    );
  }
  return null;
}

/// Unknown names: guidance + NAV line, never a framework red screen.
Route<dynamic> proxOnUnknownRoute(RouteSettings settings) {
  final name = settings.name ?? '(unnamed)';
  BleLog.log(ProxLogTags.nav, 'unknown route: $name');
  return MaterialPageRoute(
    settings: settings,
    builder: (_) => const ProxRoutePlaceholder(
      title: 'Unknown route',
      detail: 'This link does not match the route table yet. '
          'Go back and continue from the home screens.',
    ),
  );
}

/// Push helpers (screen tracks migrate ad-hoc pushes to these).
abstract final class ProxNav {
  static Future<T?> pushNamed<T extends Object?>(
    BuildContext context,
    String name, {
    ProxRouteArgs args = const ProxRouteArgs(),
  }) {
    final summary = args.summary;
    BleLog.log(
        ProxLogTags.nav, 'push $name${summary.isEmpty ? '' : ' ($summary)'}');
    return Navigator.of(context).pushNamed<T>(name, arguments: args);
  }

  /// Replace helper for guidance exits (back must never loop guidance).
  static Future<T?> replaceNamed<T extends Object?, TO extends Object?>(
    BuildContext context,
    String name, {
    ProxRouteArgs args = const ProxRouteArgs(),
  }) {
    final summary = args.summary;
    BleLog.log(ProxLogTags.nav,
        'replace $name${summary.isEmpty ? '' : ' ($summary)'}');
    return Navigator.of(context)
        .pushReplacementNamed<T, TO>(name, arguments: args);
  }

  static Future<void> openDebugLog(BuildContext context) =>
      pushNamed(context, ProxRoutes.debugLog);
}
