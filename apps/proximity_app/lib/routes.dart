// Proximity named-route table (foundation track shared infra).
//
// Approved IA, one line per node. Names use the bundle convention already
// established in the tree (bare `bundle/page`, no leading slash — matches
// `EnrollNav.routePrefix` so `popUntil` prefix matches keep working):
//
//   Entry:          welcome · roles · device
//   Prof setup:     prof/courses · prof/courses/<course> (overview)
//                   prof/sessions/<id> (detail, read)
//                   prof/sessions/<id>/edit · prof/courses/<course>/export
//   Prof live:      live/<course> (counter + Stop)
//                   live/<course>/roster · live/<course>/inbox
//                   live/<course>/add · live/<course>/setup
//                   live/<course>/recover
//   Student mark:   mark/browse · mark/join · mark/waiting · mark/face
//                   mark/proving · mark/verdict · mark/manual
//                   (one continuation — phases, not pages)
//   Enroll:         enroll/intro · enroll/capture · enroll/result
//                   (adoption: identical strings to `EnrollFlow`, so bundle
//                   pushes and this table name the same routes)
//   Records:        records/mine · records/course/<course>
//   Shared:         debug/log (filterable full-screen terminal)
//
// Status: wired. Entry/enroll/debug/records + prof setup builders point
// at the feature bundle screens; live/mark sections build their host
// shells (take_attendance + student_home retain orchestration, features
// are presentational). `MaterialApp.home` + `PROX_MODE` previews + web
// records-only behavior are preserved (see `main.dart` wiring).
//
// Loaders: routes that need a record object resolve it from the store
// (session detail/edit, course attendance detail) and render guidance +
// STATE log on a miss — never a silent dead end, never a crash. Section
// routes (live roster/inbox/…, mark phases) build their host screen; the
// section hop itself is logged NAV with the section arg.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

import 'core/auth.dart';
import 'core/device_store.dart';
import 'core/platformx.dart';
import 'features/face_identity/face_blocked.dart';
import 'design/tokens.dart';
import 'features/debug/debug_log_screen.dart';
import 'features/enrollment/enroll_capture.dart';
import 'features/enrollment/enroll_intro.dart';
import 'features/enrollment/enroll_result.dart';
import 'features/entry/device_identity_screen.dart';
import 'features/entry/role_hub_screen.dart';
import 'features/entry/welcome_screen.dart';
import 'features/records/course_attendance_detail_screen.dart';
import 'features/records/course_overview_screen.dart';
import 'features/records/export_center_screen.dart';
import 'features/records/my_attendance_screen.dart';
import 'features/records/prof_courses_screen.dart';
import 'features/records/session_detail_screen.dart';
import 'features/records/session_edit_screen.dart';
import 'features/review/flagged_devices_screen.dart';
import 'screens/student_home.dart';
import 'screens/take_attendance.dart';
import 'widgets/course_attendance.dart';
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
  static String courseOverview(String course) => 'prof/courses/$course';
  static String sessionDetail(String sessionId) => 'prof/sessions/$sessionId';
  static String sessionEdit(String sessionId) =>
      'prof/sessions/$sessionId/edit';
  static String exportCenter(String course) => 'prof/courses/$course/export';

  // Prof live (one host screen; sections ride the path).
  static String live(String course) => 'live/$course';
  static String liveRoster(String course) => 'live/$course/roster';
  static String liveInbox(String course) => 'live/$course/inbox';
  static String liveAdd(String course) => 'live/$course/add';
  static String liveSetup(String course) => 'live/$course/setup';
  static String liveRecover(String course) => 'live/$course/recover';

  // Student mark (one continuation; phases ride the path).
  static const browse = 'mark/browse';
  static const join = 'mark/join';
  static const waiting = 'mark/waiting';
  static const face = 'mark/face';
  static const proving = 'mark/proving';
  static const verdict = 'mark/verdict';
  static const manualStatus = 'mark/manual';

  // Enroll (identical strings to EnrollFlow — one convention, not two).
  static const enrollIntro = 'enroll/intro';
  static const enrollCapture = 'enroll/capture';
  static const enrollResult = 'enroll/result';

  // Records.
  static const myAttendance = 'records/mine';
  static String courseAttendance(String course) => 'records/course/$course';

  // Professor review (Track 5 required): attestationAnomaly-flagged devices.
  static const flagged = 'prof/flagged';

  // Shared.
  static const debugLog = 'debug/log';

  /// Routes that need native capabilities (BLE, camera/face, hosting,
  /// enrollment claim). The web records build never marks: entry, records
  /// and the debug terminal degrade or render everywhere; everything here
  /// redirects (see [webGuardRedirect]) instead of landing on a dead end.
  /// Kept alongside [isMobileOnly] deliberately: this gate is about the
  /// *web* records build (which cannot host BLE/HTTPS either), while
  /// isMobileOnly is about the *face/device trust stack* (desktop can
  /// host live/* fine, but can never enroll/mark). Different sets,
  /// different reasons — collapsing them would wrongly block desktop
  /// hosting or wrongly allow desktop enrollment.
  /// Pure — unit-testable without widgets.
  static bool isNativeOnly(String name) =>
      name == enrollIntro ||
      name == enrollCapture ||
      name == enrollResult ||
      name.startsWith('live/') ||
      name.startsWith('mark/');

  /// Web records-only guard: the fallback deep-link for native-only paths
  /// on web, null when the path may render. Screens ALSO carry their own
  /// banners/hidden actions, so this is defense in depth, not the only
  /// gate. Pure — unit-testable without widgets.
  static String? webGuardRedirect(String name) =>
      (kIsWeb && isNativeOnly(name)) ? myAttendance : null;

  /// Mobile-only set (Tracks 2+3 L2): enrollment + marking need the
  /// on-device face/device trust stack (plugin + HW key), which exists
  /// only on Android/iOS. Professors hosting live/* stay available on
  /// desktop (no face needed there) — only enroll/* + mark/* redirect.
  /// Pure — unit-testable without widgets.
  static bool isMobileOnly(String name) =>
      name.startsWith('enroll/') || name.startsWith('mark/');

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
  void didReplace(
      {Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    BleLog.log(
        ProxLogTags.nav, '⇄ ${_label(oldRoute)} ⇒ ${_label(newRoute)}');
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
            onPressed: () => ProxNav.pushNamed(context, ProxRoutes.myAttendance),
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

/// Role hub route: the signed-in account picks its continuation. Watches
/// the account stream (signed-out deep-links fall back to Welcome —
/// same rule the landing router uses).
class RoleHubRoute extends ConsumerWidget {
  const RoleHubRoute({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountAsync = ref.watch(accountProvider);
    return accountAsync.when(
      data: (acct) =>
          acct == null ? const WelcomeScreen() : RoleHubScreen(account: acct),
      loading: () => const ProxScreen(
        title: 'Roles',
        child: ProxLoadingRow(label: 'Loading…'),
      ),
      error: (e, _) => ProxRoutePlaceholder(
        title: 'Sign-in unreadable',
        detail: 'Role hub could not read the account: $e',
      ),
    );
  }
}

/// Exact-name table for `MaterialApp.routes`. Parameterized IA nodes live
/// in [proxOnGenerateRoute]; unknown names fall to [proxOnUnknownRoute].
Map<String, WidgetBuilder> buildProxRoutes() => {
      // Entry (feature screens; landing is a thin Welcome-vs-RoleHub router).
      ProxRoutes.welcome: (_) => const WelcomeScreen(),
      ProxRoutes.roles: (_) => const RoleHubRoute(),
      ProxRoutes.device: (_) => const DeviceIdentityScreen(),
      // Prof setup (records bundle — self-sufficient, absorbs the old
      // course page split: picker + overview + export + detail/edit).
      ProxRoutes.profCourses: (_) => const ProfCoursesScreen(),
      // Student mark (one continuation inside StudentHomeScreen phases;
      // the shell retains discovery/waiting/proving orchestration, the
      // mark bundle stays presentational).
      ProxRoutes.browse: (_) => const StudentHomeScreen(),
      ProxRoutes.join: (_) => const StudentHomeScreen(),
      ProxRoutes.waiting: (_) => const StudentHomeScreen(),
      ProxRoutes.face: (_) => const StudentHomeScreen(),
      ProxRoutes.proving: (_) => const StudentHomeScreen(),
      ProxRoutes.verdict: (_) => const StudentHomeScreen(),
      ProxRoutes.manualStatus: (_) => const StudentHomeScreen(),
      // Enroll (feature bundle; same names EnrollFlow pushes).
      ProxRoutes.enrollIntro: (_) => const EnrollIntroScreen(),
      ProxRoutes.enrollCapture: (_) => const EnrollCaptureScreen(),
      ProxRoutes.enrollResult: (_) => const EnrollResultScreen(),
      // Records (bundle — absorbs the old my-attendance + student-course).
      ProxRoutes.myAttendance: (_) => const MyAttendanceScreen(),
      // Professor review (Track 5 required surface).
      ProxRoutes.flagged: (_) => const FlaggedDevicesScreen(),
      // Shared.
      ProxRoutes.debugLog: (_) => const DebugLogScreen(),
    };

/// Deep-link loader for one saved prof session (read or edit). Resolves
/// the record object from on-device history — the router never ferries
/// record objects, screens resolve them from the store. Missing ids render
/// guidance (logged STATE), never a crash.
class SessionRouteLoader extends ConsumerWidget {
  final String sessionId;
  final bool editing;
  const SessionRouteLoader(
      {super.key, required this.sessionId, this.editing = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(deviceStoreProvider);
    return FutureBuilder<List<ClassRecord>>(
      future: store.readHistory(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const ProxScreen(
            title: 'Session',
            child: ProxLoadingRow(label: 'Loading…'),
          );
        }
        final history = snap.data ?? const <ClassRecord>[];
        ClassRecord? found;
        for (final r in history) {
          if (r.id == sessionId) {
            found = r;
            break;
          }
        }
        final f = found;
        if (f == null) {
          BleLog.log(ProxLogTags.state,
              'route session $sessionId not on device — guidance');
          return ProxRoutePlaceholder(
            title: 'Not linked yet',
            detail:
                'Session $sessionId is not on this device yet — open it from its course for now.',
          );
        }
        if (editing) {
          return SessionEditScreen(
              record: f, courseSessions: history, readOnly: kIsWeb);
        }
        return SessionDetailScreen(record: f, courseSessions: history);
      },
    );
  }
}

/// Deep-link loader for one student's course (records/mine drill-down).
/// Resolves cached student sessions + viewer email from the store.
class CourseAttendanceRouteLoader extends ConsumerWidget {
  final String course;
  const CourseAttendanceRouteLoader({super.key, required this.course});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(deviceStoreProvider);
    final acct = ref.watch(accountProvider).valueOrNull;
    final email = acct?.email.toLowerCase() ?? '';
    return FutureBuilder<List<ClassRecord>>(
      future: store.readStudentSessions(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const ProxScreen(
            title: 'Course',
            child: ProxLoadingRow(label: 'Loading…'),
          );
        }
        final all = snap.data ?? const <ClassRecord>[];
        final sessions =
            all.where((s) => courseOfRecord(s) == course).toList();
        if (sessions.isEmpty) {
          BleLog.log(ProxLogTags.state,
              'route records/course/$course has no cached sessions — guidance');
          return ProxRoutePlaceholder(
            title: 'Not linked yet',
            detail:
                'No synced sessions for $course on this device yet — pull to refresh on records/mine first.',
          );
        }
        return CourseAttendanceDetailScreen(
            course: course, sessions: sessions, email: email);
      },
    );
  }
}

/// Parameterized IA nodes (`live/<course>[/section]`,
/// `prof/courses/<course>[/export]`, `prof/sessions/<id>[/edit]`,
/// `records/course/<course]`). Returns null when [settings.name] is not
/// an IA path so `onUnknownRoute` handles it.
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

  // Tracks 2+3 L2 mobile guard: enroll/* + mark/* need the on-device
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

  // Prof live: every section builds the host screen (sections split out
  // on the live track's migration); the section rides along as NAV context.
  if (name.startsWith('live/')) {
    final rest = name.substring('live/'.length);
    final course =
        args.course.isNotEmpty ? args.course : rest.split('/').first;
    if (course.isEmpty) return null;
    final section =
        args.section.isNotEmpty ? args.section : rest.split('/').skip(1).join('/');
    BleLog.log(ProxLogTags.nav,
        'live deep-link course=$course${section.isEmpty ? '' : ' section=$section'}');
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => TakeAttendanceScreen(courseName: course),
    );
  }

  // Prof setup: overview owns managing the course; the export center owns
  // review/export of the past; session detail/edit resolve their record
  // from history via loaders (missing ids render guidance, never a crash).
  if (name.startsWith('prof/courses/')) {
    final rest = name.substring('prof/courses/'.length);
    final segs = rest.split('/');
    final course = args.course.isNotEmpty ? args.course : segs.first;
    if (course.isEmpty) return null;
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
  if (name.startsWith('prof/sessions/')) {
    final rest = name.substring('prof/sessions/'.length);
    final id =
        args.sessionId.isNotEmpty ? args.sessionId : rest.split('/').first;
    if (id.isEmpty) return null;
    final editing = name.endsWith('/edit');
    BleLog.log(ProxLogTags.nav,
        'session deep-link session=$id (${editing ? 'edit' : 'read'})');
    return MaterialPageRoute(
      settings: settings,
      builder: (_) =>
          SessionRouteLoader(sessionId: id, editing: editing),
    );
  }

  // Records: per-course drill-down resolves cached student sessions +
  // viewer email via its loader.
  if (name.startsWith('records/course/')) {
    final rest = name.substring('records/course/'.length);
    final course = args.course.isNotEmpty ? args.course : rest.split('/').first;
    if (course.isEmpty) return null;
    BleLog.log(ProxLogTags.nav, 'records deep-link course=$course');
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => CourseAttendanceRouteLoader(course: course),
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
    BleLog.log(ProxLogTags.nav,
        'push $name${summary.isEmpty ? '' : ' ($summary)'}');
    return Navigator.of(context).pushNamed<T>(name, arguments: args);
  }

  static Future<void> openDebugLog(BuildContext context) =>
      pushNamed(context, ProxRoutes.debugLog);

  static Future<void> openCourse(BuildContext context, String course) =>
      pushNamed(context, ProxRoutes.courseOverview(course),
          args: ProxRouteArgs(course: course));

  static Future<void> openLive(BuildContext context, String course) =>
      pushNamed(context, ProxRoutes.live(course),
          args: ProxRouteArgs(course: course));

  static Future<void> openFlagged(BuildContext context) =>
      pushNamed(context, ProxRoutes.flagged);

  static Future<void> openWelcome(BuildContext context) =>
      pushNamed(context, ProxRoutes.welcome);
}
