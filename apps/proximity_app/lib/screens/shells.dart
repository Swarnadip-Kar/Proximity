// Student + professor app shells (§3.1/§3.5): IndexedStack 3-tab bodies
// (student Mark/Courses/Account; professor Live/Courses/Account) where each
// tab keeps its own Navigator — every tab preserves its stack + scroll
// position while switching. Tab chrome only: tab content screens are owned
// by their sections and render here untouched.
//
// Back contract (§3.5): in-tab back pops that tab's stack only, never
// crosses tabs, never leaves the shell; tab-root back never exits the shell
// and never tears down a live window — first press hints, double-press
// leaves the app (OS-level, no session teardown of ours). The old
// PopScope→setMode(unset) pattern is gone (deleted at each site, not
// moved here); mode switches happen only through explicit UI (account
// switch, role continue, debug previews).
//
// Mark enrollment gate (§3.4): tapping Mark while
// [linkedIdentityProvider] is null pushes the SetupFlowScreen at its
// computed start step (one flow, shared with the fresh-install path).
// Completion lands on mark/browse (the gate stays shut once linked).
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';

import '../core/auth.dart';
import '../core/device_store.dart';
import '../design/tokens.dart';
import '../features/account/account_screen.dart';
import '../features/records/my_attendance_screen.dart';
import '../features/records/prof_courses_screen.dart';
import '../main.dart';
import '../mode.dart';
import '../routes.dart';
import '../screens/setup_flow_screen.dart';
import '../screens/student_home.dart';
import '../widgets/prox_buttons.dart';
import '../widgets/web_banner.dart';
import 'take_attendance.dart';

/// Shared-axis push transition (§3.2): forward slides + fades in over
/// [ProxDurations.push]; the outgoing page fades toward 60% and scales to
/// 98% for the depth cue; back is the exact reverse. Reduced motion
/// collapses to a [ProxDurations.reducedFade] opacity fade.
PageRoute<T> proxSharedAxisRoute<T>(
  BuildContext context, {
  required Widget child,
  String? name,
  Object? arguments,
}) {
  final reduced = ProxMotion.reduced(context);
  return PageRouteBuilder<T>(
    settings: RouteSettings(name: name, arguments: arguments),
    transitionDuration:
        reduced ? ProxDurations.reducedFade : ProxDurations.push,
    reverseTransitionDuration:
        reduced ? ProxDurations.reducedFade : ProxDurations.push,
    pageBuilder: (_, __, ___) => child,
    transitionsBuilder: (context, animation, secondary, child) {
      if (ProxMotion.reduced(context)) {
        return FadeTransition(opacity: animation, child: child);
      }
      final incoming = CurvedAnimation(
        parent: animation,
        curve: ProxCurves.emphasized,
      );
      final outgoing = CurvedAnimation(
        parent: secondary,
        curve: Curves.easeOut,
      );
      return FadeTransition(
        opacity: Tween<double>(begin: 1, end: 0.6).animate(outgoing),
        child: ScaleTransition(
          scale: Tween<double>(begin: 1, end: 0.98).animate(outgoing),
          child: FadeTransition(
            opacity: Tween<double>(begin: 0, end: 1).animate(incoming),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.12, 0),
                end: Offset.zero,
              ).animate(incoming),
              child: child,
            ),
          ),
        ),
      );
    },
  );
}

/// Account-tab icon: signed-in initial (Gmail-photo-only would need a photo
/// field — [SignedAccount] carries none and no auth plumbing is invented
/// here; see the integration log). Active tab gets the accent.brand ring.
class _AccountTabIcon extends ConsumerWidget {
  final bool active;
  const _AccountTabIcon({required this.active});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ProximityColors.of(context);
    final acct = ref.watch(accountProvider).valueOrNull;
    final name = (acct?.displayName ?? '').trim();
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: active ? Border.all(color: c.accentBrand, width: 2) : null,
      ),
      child: CircleAvatar(
        radius: 10,
        backgroundColor: c.contentTertiary.withValues(alpha: 0.25),
        child: Text(
          initial,
          style: TextStyle(fontSize: 11, color: c.contentPrimary),
        ),
      ),
    );
  }
}

/// 4dp vertical settle on the tab icon over the tab cross-fade (§3.1).
class _SettleIcon extends StatelessWidget {
  final bool active;
  final Widget child;
  const _SettleIcon({required this.active, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // Re-run the settle whenever activation flips.
      key: ValueKey<bool>(active),
      tween: Tween(begin: 4, end: 0),
      duration: ProxMotion.reduced(context)
          ? Duration.zero
          : ProxDurations.tabCrossFade,
      builder: (_, v, icon) =>
          Transform.translate(offset: Offset(0, v), child: icon!),
      child: child,
    );
  }
}

BottomNavigationBarItem _tabItem({
  required Widget icon,
  required Widget activeIcon,
  required String label,
  required bool active,
  required bool narrow,
}) {
  // Icon-only below the 360dp breakpoint (§3.1 — labels handled by the
  // bar); inactive stays outlined, active filled, in both modes.
  return BottomNavigationBarItem(
    icon: _SettleIcon(active: active, child: icon),
    activeIcon: _SettleIcon(active: active, child: activeIcon),
    label: narrow ? null : label,
    tooltip: label,
  );
}

/// Token-driven bottom bar: surface above surface.base with a hairline top
/// divider, active tab filled icon + label in accent.brand, inactive
/// outlined.
Widget _shellBar({
  required BuildContext context,
  required int index,
  required List<BottomNavigationBarItem> items,
  required ValueChanged<int> onTap,
}) {
  final c = ProximityColors.of(context);
  final narrow = MediaQuery.sizeOf(context).width < 360;
  return DecoratedBox(
    decoration: BoxDecoration(
      color: c.surfaceRaised,
      border: Border(top: BorderSide(color: c.divider)),
    ),
    // §10: Scaffold lays the bottom bar flush at the screen edge with no
    // system-inset padding of its own (verified in the framework's
    // _ScaffoldLayout — `bottom - bottomWidgetsHeight`, no viewPadding).
    // The SafeArea keeps taps + labels above the host gesture/nav area;
    // the bar's own background still fills the inset behind it.
    child: SafeArea(
      top: false,
      child: BottomNavigationBar(
        currentIndex: index,
        onTap: onTap,
        type: BottomNavigationBarType.fixed,
        elevation: 2,
        backgroundColor: c.surfaceRaised,
        selectedItemColor: c.accentBrand,
        unselectedItemColor: c.contentSecondary,
        selectedFontSize: 12,
        unselectedFontSize: 12,
        selectedLabelStyle: ProxType.label(color: c.accentBrand),
        unselectedLabelStyle: ProxType.label(color: c.contentSecondary),
        showSelectedLabels: !narrow,
        showUnselectedLabels: !narrow,
        items: items,
      ),
    ),
  );
}

/// Per-tab navigator: tab root at '/', every other name resolves exactly
/// like the root router (same table + guards + unknown placeholder), so
/// in-tab pushes and deep-link shapes behave identically wherever they
/// land.
Route<dynamic>? _tabRoute(RouteSettings s, Widget root) {
  if (s.name == null || s.name == '/') {
    return MaterialPageRoute(
      settings: const RouteSettings(name: '/'),
      builder: (_) => root,
    );
  }
  final exact = buildProxRoutes()[s.name];
  if (exact != null) return MaterialPageRoute(settings: s, builder: exact);
  return proxOnGenerateRoute(s);
}

/// Shared shell back handling (§3.5): pop the current tab's stack only;
/// at a tab root, hint — never exit the shell, never touch live windows.
/// Double-press within 2s leaves the app (OS-level; no teardown of ours).
void _shellBack(
  BuildContext context,
  GlobalKey<NavigatorState> tabNav,
  DateTime? lastBack,
  ValueChanged<DateTime?> setLastBack,
) {
  final nav = tabNav.currentState;
  if (nav != null && nav.canPop()) {
    nav.pop();
    return;
  }
  final now = DateTime.now();
  // Double-back window: UI affordance timing only (not a frozen constant).
  if (lastBack != null &&
      now.difference(lastBack) < const Duration(seconds: 2)) {
    setLastBack(null);
    if (!kIsWeb) SystemNavigator.pop();
    return;
  }
  setLastBack(now);
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
    content: Text('Press back again to leave the app'),
    duration: Duration(seconds: 2),
  ));
}

/// Student shell: Mark · Courses · Account (§3.1).
class StudentShell extends ConsumerStatefulWidget {
  const StudentShell({super.key});

  @override
  ConsumerState<StudentShell> createState() => _StudentShellState();
}

class _StudentShellState extends ConsumerState<StudentShell> {
  var _index = 0;
  final _markNav = GlobalKey<NavigatorState>();
  final _coursesNav = GlobalKey<NavigatorState>();
  final _accountNav = GlobalKey<NavigatorState>();
  DateTime? _lastBack;

  /// True while the gate flow route is on the Mark stack (prevents
  /// duplicate pushes from re-taps + listener races).
  var _flowOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_index == 0) _gateMark();
    });
  }

  GlobalKey<NavigatorState> _nav(int i) =>
      [_markNav, _coursesNav, _accountNav][i];

  void _selectTab(int i) {
    setState(() => _index = i);
    if (i == 0) _gateMark();
  }

  /// Mark enrollment gate (§3.4): unenrolled tapping Mark routes into the
  /// SetupFlowScreen at its computed start step. Gate signal is
  /// [linkedIdentityProvider] — the same enrollment signal the Mark browse
  /// card and join gate already use (a set linked identity means this
  /// device completed the claim; see the integration log for the
  /// candidates audit).
  void _gateMark() {
    if (!mounted || _flowOpen) return;
    if (ref.read(linkedIdentityProvider) != null) return;
    final nav = _markNav.currentState;
    if (nav == null) return;
    _flowOpen = true;
    BleLog.log('NAV', 'mark gate: unenrolled → setup flow');
    nav
        .push(proxSharedAxisRoute(
          context,
          name: 'setup-flow',
          child: SetupFlowScreen(
            onFirstBack: () async {
              // Back from the first step → Account/RoleHub, never bare mark.
              if (!mounted) return;
              final n = _markNav.currentState;
              if (n != null && n.canPop()) n.pop();
              _selectTab(2);
            },
            onComplete: () async {
              // Done → land on mark/browse (linked by now; gate stays shut).
              if (!mounted) return;
              final n = _markNav.currentState;
              if (n != null && n.canPop()) n.pop();
            },
          ),
        ))
        .then((_) => _flowOpen = false);
  }

  void _armGate() {
    ref.listen<LinkedIdentity?>(linkedIdentityProvider, (prev, next) {
      // Signed out (or claim cleared) while on Mark: re-enter the flow.
      if (prev != null && next == null && mounted && _index == 0) {
        _gateMark();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _armGate();
    final narrow = MediaQuery.sizeOf(context).width < 360;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _shellBack(context, _nav(_index), _lastBack, (v) => _lastBack = v);
      },
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < 3; i++)
              AnimatedOpacity(
                // Tab-switch cross-fade (120ms); the IndexedStack keeps
                // every tab's stack + scroll alive underneath.
                opacity: i == _index ? 1 : 0,
                duration: ProxMotion.reduced(context)
                    ? Duration.zero
                    : ProxDurations.tabCrossFade,
                child: Navigator(
                  key: _nav(i),
                  onGenerateRoute: (s) => _tabRoute(
                    s,
                    [
                      const StudentHomeScreen(),
                      const MyAttendanceScreen(),
                      const StudentAccountScreen(),
                    ][i],
                  ),
                  onUnknownRoute: proxOnUnknownRoute,
                ),
              ),
          ],
        ),
        bottomNavigationBar: _shellBar(
          context: context,
          index: _index,
          onTap: _selectTab,
          items: [
            _tabItem(
              icon: const Icon(Icons.radar_outlined),
              activeIcon: const Icon(Icons.radar),
              label: 'Mark',
              active: _index == 0,
              narrow: narrow,
            ),
            _tabItem(
              icon: const Icon(Icons.layers_outlined),
              activeIcon: const Icon(Icons.layers),
              label: 'Courses',
              active: _index == 1,
              narrow: narrow,
            ),
            _tabItem(
              icon: const _AccountTabIcon(active: false),
              activeIcon: const _AccountTabIcon(active: true),
              label: 'Account',
              active: _index == 2,
              narrow: narrow,
            ),
          ],
        ),
      ),
    );
  }
}

/// Professor shell: Live · Courses · Account (§3.1).
class ProfShell extends ConsumerStatefulWidget {
  const ProfShell({super.key});

  @override
  ConsumerState<ProfShell> createState() => _ProfShellState();
}

class _ProfShellState extends ConsumerState<ProfShell> {
  var _index = 0;
  final _liveNav = GlobalKey<NavigatorState>();
  final _coursesNav = GlobalKey<NavigatorState>();
  final _accountNav = GlobalKey<NavigatorState>();
  DateTime? _lastBack;

  GlobalKey<NavigatorState> _nav(int i) =>
      [_liveNav, _coursesNav, _accountNav][i];

  void _selectTab(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 360;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _shellBack(context, _nav(_index), _lastBack, (v) => _lastBack = v);
      },
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < 3; i++)
              AnimatedOpacity(
                opacity: i == _index ? 1 : 0,
                duration: ProxMotion.reduced(context)
                    ? Duration.zero
                    : ProxDurations.tabCrossFade,
                child: Navigator(
                  key: _nav(i),
                  onGenerateRoute: (s) => _tabRoute(
                    s,
                    [
                      _LiveRoot(onNeedCourses: () => _selectTab(1)),
                      const ProfCoursesScreen(),
                      const ProfAccountScreen(),
                    ][i],
                  ),
                  onUnknownRoute: proxOnUnknownRoute,
                ),
              ),
          ],
        ),
        bottomNavigationBar: _shellBar(
          context: context,
          index: _index,
          onTap: _selectTab,
          items: [
            _tabItem(
              icon: const Icon(Icons.radio_outlined),
              activeIcon: const Icon(Icons.radio),
              label: 'Live',
              active: _index == 0,
              narrow: narrow,
            ),
            _tabItem(
              icon: const Icon(Icons.layers_outlined),
              activeIcon: const Icon(Icons.layers),
              label: 'Courses',
              active: _index == 1,
              narrow: narrow,
            ),
            _tabItem(
              icon: const _AccountTabIcon(active: false),
              activeIcon: const _AccountTabIcon(active: true),
              label: 'Account',
              active: _index == 2,
              narrow: narrow,
            ),
          ],
        ),
      ),
    );
  }
}

/// Live-tab root: pick a registered course to host. Records actions
/// (register/rename) live on the Courses tab — this root only opens the
/// existing host screen for a course. Web records builds cannot host
/// (live/* stays native-only per the guards), so they get guidance, never
/// a hosting affordance.
class _LiveRoot extends ConsumerStatefulWidget {
  final VoidCallback onNeedCourses;
  const _LiveRoot({required this.onNeedCourses});

  @override
  ConsumerState<_LiveRoot> createState() => _LiveRootState();
}

class _LiveRootState extends ConsumerState<_LiveRoot> {
  late final Future<List<dynamic>> _courses;

  @override
  void initState() {
    super.initState();
    _courses = ref.read(deviceStoreProvider).readCourses();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return AdaptiveScaffold(
        title: 'Live',
        body: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 460),
              child: Column(
                children: [
                  // Exact records-only banner, same as everywhere; the line
                  // below it is the only new chrome copy in this shell.
                  WebRecordsBanner(),
                  SizedBox(height: 8),
                  Text(
                    'Hosting needs the native or desktop app — this web '
                    'build is records only.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return AdaptiveScaffold(
      title: 'Live',
      body: FutureBuilder<List<dynamic>>(
        future: _courses,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final courses = snap.data ?? const [];
          if (courses.isEmpty) {
            return Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    children: [
                      const Text(
                        'No courses yet — register one in Courses to '
                        'start hosting.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      ProxSecondaryButton(
                        label: const Text('Go to Courses'),
                        onPressed: widget.onNeedCourses,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: courses.length,
            itemBuilder: (context, i) {
              final name = (courses[i] as dynamic).name as String;
              return ListTile(
                title: Text(name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  BleLog.log('NAV', 'live root → host $name');
                  Navigator.of(context).push(proxSharedAxisRoute(
                    context,
                    name: ProxRoutes.live(name),
                    child: TakeAttendanceScreen(courseName: name),
                  ));
                },
              );
            },
          );
        },
      ),
    );
  }
}
