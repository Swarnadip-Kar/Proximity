// Student + professor app shells (§3.1/§3.5): IndexedStack 3-tab bodies
// (student Mark/Courses/Account; professor Live/Courses/Account) where each
// tab keeps its own Navigator — every tab preserves its stack + scroll
// position while switching, by tap or by swipe. Tab chrome only: tab content
// screens are owned by their sections and render here untouched.
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
import '../widgets/clock.dart';
import '../widgets/prox_buttons.dart';
import '../widgets/web_banner.dart';
import 'take_attendance.dart';
import 'package:proximity_storage/storage.dart';

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

/// Account-tab icon: Google OAuth profile photo when the watched account
/// carries one (ordinary account metadata, NOT `face_verification`
/// output); null/empty falls back to the signed-in initial. Active tab
/// gets the accent.brand ring. Same 20dp avatar, same ring, no layout
/// change.
class _AccountTabIcon extends ConsumerWidget {
  final bool active;
  const _AccountTabIcon({required this.active});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ProximityColors.of(context);
    final acct = ref.watch(accountProvider).valueOrNull;
    final name = (acct?.displayName ?? '').trim();
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    Widget initialsAvatar() => CircleAvatar(
          radius: 10,
          backgroundColor: c.contentTertiary.withValues(alpha: 0.25),
          child: Text(
            initial,
            style: TextStyle(fontSize: 11, color: c.contentPrimary),
          ),
        );
    final photoUrl = (acct?.photoUrl ?? '').trim();
    final avatar = photoUrl.isEmpty
        ? initialsAvatar()
        : ClipOval(
            child: Image.network(
              photoUrl,
              width: 20,
              height: 20,
              fit: BoxFit.cover,
              // Failed loads fall back to initials, never a broken icon.
              errorBuilder: (_, __, ___) => initialsAvatar(),
            ),
          );
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: active ? Border.all(color: c.accentBrand, width: 2) : null,
      ),
      child: avatar,
    );
  }
}

/// Minimum fling velocity that counts as a tab-switch swipe (§3.1 swipe
/// rebuild): well above touch-slop noise, well below a deliberate fling
/// (tests drive 800–1000px/s). Direction comes from the velocity sign —
/// finger left pages forward, finger right pages back.
const _minSwipeVelocity = 200.0;

/// Directional tab-switch slide (§3.1, tester-directed): the single motion
/// for every tab switch, tap or swipe (never double-animated — swipes
/// funnel through the same [_selectTab] path as taps). Direction follows
/// tab order (+1 = tapped rightward / swiped forward, content slides in
/// from the right; −1 mirrors). One [ProxDurations.tabSlide] ease on
/// [ProxCurves.standard] (easeOutCubic); reduced motion parks the slide at
/// rest and collapses to instant opacity.
///
/// Keep-alive contract: the build shape is FIXED in every state (always
/// `SlideTransition > AnimatedOpacity > Navigator`, same unkeyed slot), so
/// the tab Navigator below never reparents across switches — every tab's
/// stack + scroll position survives exactly as with the old bare
/// [AnimatedOpacity]. Only the incoming tab's controller restarts, keyed
/// off [seq] (bumped per cross-tab switch, so unrelated rebuilds never
/// retrigger). Interruptible: a new switch restarts from its edge.
class _TabSlide extends StatefulWidget {
  final bool active;
  final double direction;
  final int seq;
  final bool reduced;
  final Widget child;
  const _TabSlide({
    required this.active,
    required this.direction,
    required this.seq,
    required this.reduced,
    required this.child,
  });

  @override
  State<_TabSlide> createState() => _TabSlideState();
}

class _TabSlideState extends State<_TabSlide>
    with SingleTickerProviderStateMixin {
  static const Animation<Offset> _rest =
      AlwaysStoppedAnimation<Offset>(Offset.zero);
  late final AnimationController _controller;
  CurvedAnimation? _curve;
  Animation<Offset> _slide = _rest;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: ProxDurations.tabSlide,
      vsync: this,
    );
  }

  @override
  void didUpdateWidget(covariant _TabSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.seq != oldWidget.seq &&
        widget.active &&
        widget.direction != 0 &&
        !widget.reduced) {
      _curve?.dispose();
      _curve = CurvedAnimation(
        parent: _controller,
        curve: ProxCurves.standard,
      );
      _slide = Tween<Offset>(
        begin: Offset(widget.direction, 0),
        end: Offset.zero,
      ).animate(_curve!);
      // Same restart the implicit animations make in didUpdateWidget.
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _curve?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: widget.reduced ? _rest : _slide,
      child: AnimatedOpacity(
        opacity: widget.active ? 1 : 0,
        duration: widget.reduced ? Duration.zero : ProxDurations.tabSlide,
        child: widget.child,
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
  // Tab-slide driver: [seq] restarts the incoming slide per cross-tab
  // switch, [dir] carries its direction (+1 from the right, −1 from the
  // left). Same-tab taps leave both untouched (no animation). Swipes
  // funnel through [_selectTab]/[_swipeTo], so tap and swipe share the one
  // motion and never double-animate.
  var _slideSeq = 0;
  var _slideDir = 0.0;

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
    if (i != _index) {
      _slideDir = i > _index ? 1 : -1;
      _slideSeq++;
    }
    setState(() => _index = i);
    if (i == 0) _gateMark();
  }

  /// Swipe landing (§3.1 swipe rebuild): same gate as taps. An unenrolled
  /// swipe toward Mark routes the setup flow, travels, and snaps back to
  /// the origin tab on the next frame — never lands, never shows bare
  /// mark (the flow covers Mark from the first frame there).
  void _swipeTo(int target) {
    if (target < 0 || target > 2 || target == _index) return;
    if (target == 0 && ref.read(linkedIdentityProvider) == null) {
      _gateMark();
      final origin = _index;
      _selectTab(target);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _selectTab(origin);
      });
      return;
    }
    _selectTab(target);
  }

  /// Horizontal fling anywhere on tab [i]'s content (vertical lists win
  /// their own axis in the arena, so scrolling never misfires). Root-only:
  /// a pushed sub-page keeps its own gestures and back behavior — the
  /// check reads the live Navigator state at gesture time, so no observer
  /// or rebuild is needed. Sub-threshold drags are ignored.
  void _onTabFling(int i, DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < _minSwipeVelocity) return;
    final nav = _nav(i).currentState;
    if (nav != null && nav.canPop()) return;
    _swipeTo(velocity < 0 ? i + 1 : i - 1);
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
    // Tester fix (stale account after switch): the IndexedStack keeps the
    // Account Navigator (and its tab root) alive across sign-out/sign-in,
    // so the root is keyed by the signed-in Gmail — a switch unmounts the
    // previous account's page, dropping its cached reads, and mounts a
    // fresh one for the current account. Watched (not read) so the key
    // tracks the live account stream; signed out keys as 'signed-out', so
    // sign-out clears the displayed identity immediately.
    final accountTabKey = ValueKey(
        'student-account-${ref.watch(accountProvider).valueOrNull?.email.trim().toLowerCase() ?? 'signed-out'}');
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
              _TabSlide(
                // Directional slide-in on tab switch; the IndexedStack
                // keeps every tab's stack + scroll alive underneath.
                // The detector adds the swipe path (fling → same funnel
                // as taps); vertical lists keep their own axis.
                active: i == _index,
                direction: _slideDir,
                seq: _slideSeq,
                reduced: ProxMotion.reduced(context),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: (d) => _onTabFling(i, d),
                  child: Navigator(
                    key: _nav(i),
                    onGenerateRoute: (s) => _tabRoute(
                      s,
                      [
                        const StudentHomeScreen(),
                        const MyAttendanceScreen(),
                        StudentAccountScreen(key: accountTabKey),
                      ][i],
                    ),
                    onUnknownRoute: proxOnUnknownRoute,
                  ),
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
  // Direct handle to the Live-tab root state: the per-tab Navigator caches
  // its route, so parent rebuilds never rebuild _LiveRoot — tab revisits
  // must explicitly refresh it (see _selectTab).
  final _liveRootKey = GlobalKey<_LiveRootState>();
  DateTime? _lastBack;
  // Same tab-slide driver as the student shell (see above).
  var _slideSeq = 0;
  var _slideDir = 0.0;

  GlobalKey<NavigatorState> _nav(int i) =>
      [_liveNav, _coursesNav, _accountNav][i];

  void _selectTab(int i) {
    if (i != _index) {
      _slideDir = i > _index ? 1 : -1;
      _slideSeq++;
    }
    setState(() => _index = i);
    if (i == 0) _liveRootKey.currentState?.refresh();
  }

  /// Swipe landing (§3.1 swipe rebuild): no gate on this shell — every
  /// in-range swipe switches through the same slide as taps.
  void _swipeTo(int target) {
    if (target < 0 || target > 2 || target == _index) return;
    _selectTab(target);
  }

  /// Horizontal fling on tab [i]'s content; root-only (see student shell).
  void _onTabFling(int i, DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < _minSwipeVelocity) return;
    final nav = _nav(i).currentState;
    if (nav != null && nav.canPop()) return;
    _swipeTo(velocity < 0 ? i + 1 : i - 1);
  }

  @override
  Widget build(BuildContext context) {
    // Same stale-account keying as the student shell (see above): the
    // professor Account root is keyed by the signed-in Gmail so a switch
    // remounts it for the current account.
    final accountTabKey = ValueKey(
        'prof-account-${ref.watch(accountProvider).valueOrNull?.email.trim().toLowerCase() ?? 'signed-out'}');
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
              _TabSlide(
                active: i == _index,
                direction: _slideDir,
                seq: _slideSeq,
                reduced: ProxMotion.reduced(context),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: (d) => _onTabFling(i, d),
                  child: Navigator(
                    key: _nav(i),
                    onGenerateRoute: (s) => _tabRoute(
                      s,
                      [
                        _LiveRoot(
                            key: _liveRootKey,
                            onNeedCourses: () => _selectTab(1)),
                        const ProfCoursesScreen(),
                        ProfAccountScreen(key: accountTabKey),
                      ][i],
                    ),
                    onUnknownRoute: proxOnUnknownRoute,
                  ),
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
///
/// Zero-intersection (tester fix): Live rows are host entry ONLY — radio
/// icon + `Tap to host live session` subtitle + `Host` trailing action,
/// no management (no register/rename/delete/export, no session counts).
/// Courses rows stay records/management only (verified records-only, no
/// hosting affordance there). The two pickers no longer read as the same
/// list.
class _LiveRoot extends ConsumerStatefulWidget {
  final VoidCallback onNeedCourses;
  const _LiveRoot({super.key, required this.onNeedCourses});

  @override
  ConsumerState<_LiveRoot> createState() => _LiveRootState();
}

class _LiveRootState extends ConsumerState<_LiveRoot> {
  late Future<List<dynamic>> _courses;

  Future<List<dynamic>> _loadLive() {
    final store = ref.read(deviceStoreProvider);
    return Future.wait([store.readCourses(), store.readHistory()]);
  }

  @override
  void initState() {
    super.initState();
    _courses = _loadLive();
  }

  /// Re-read the course catalog (same source the Courses tab writes via
  /// `store.addCourse`) + the history read the Courses picker already uses
  /// for its last-date labels (read-only reuse, no new query/semantics).
  /// Called by the shell on every Live-tab select: the IndexedStack +
  /// per-tab Navigator keeps this state alive, so the initState snapshot
  /// alone would stay stale forever and hide Courses-tab registrations.
  /// No filtering — empty state shows only when the catalog is truly empty.
  void refresh() {
    if (!mounted) return;
    setState(() {
      _courses = _loadLive();
    });
  }

  /// Newest history dateIso for [course], same membership + newest-first
  /// rule as the Courses picker (`courseId` match, legacy empty-courseId
  /// falls back to class-label match). Null when never hosted.
  String? _lastDateFor(String course, List<ClassRecord> history) {
    final sessions = history
        .where((r) =>
            r.courseId == course ||
            (r.courseId.isEmpty && r.classLabel == course))
        .toList()
      ..sort((a, b) => b.dateIso.compareTo(a.dateIso));
    return sessions.isEmpty ? null : sessions.first.dateIso;
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
    // Today's date header (tester fix, presentation only): the same frozen
    // records helpers as the take-screen header (`fullDateOf(todayIso())`)
    // so Live root reads consistently alongside it. Different screen, so
    // no duplication — the take header owns its in-class block, this owns
    // the tab-root line.
    final todayLine = fullDateOf(todayIso());
    return AdaptiveScaffold(
      title: 'Live',
      body: FutureBuilder<List<dynamic>>(
        future: _courses,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data ?? const [];
          final courses =
              data.isEmpty ? const <Course>[] : data[0] as List<Course>;
          final history = data.length < 2
              ? const <ClassRecord>[]
              : data[1] as List<ClassRecord>;
          if (courses.isEmpty) {
            return Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                children: [
                  // Live ticking clock, same as the student Mark tab.
                  const ClockHeader(),
                  const SizedBox(height: 8),
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
          // Tab header date + per-course last-hosted dates (tester fix,
          // presentation only): today line reuses the frozen take-header
          // format; each row reuses the frozen Courses-picker date format
          // (`lastDateLabel`) read-only from history, with an honest
          // `Not hosted yet` state when absent. Host entry only (no
          // management, no session counts): radio + host subtitle + Host.
          final c = ProximityColors.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                // Live ticking clock, same as the student Mark tab.
                child: ClockHeader(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 14,
                      color: c.contentPrimary,
                    ),
                    const SizedBox(width: ProxSpacing.sm),
                    Flexible(
                      child: Text(
                        todayLine,
                        style: ProxType.label(color: c.contentPrimary),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: courses.length,
                  itemBuilder: (context, i) {
                    final name = courses[i].name;
                    final lastDate = _lastDateFor(name, history);
                    // Frozen picker format for the date half; honest
                    // empty state otherwise. §10.1: the date line never
                    // ellipsizes (wraps); ellipsis lives only on the
                    // non-date host line below.
                    final dateLine = lastDate == null
                        ? 'Not hosted yet'
                        : 'Last hosted ${lastDateLabel(lastDate)}';
                    // Host entry only (no management): radio affordance +
                    // host subtitle + Host action. Push + log + route name
                    // unchanged (presentation/navigation only).
                    return ListTile(
                      leading: const Icon(Icons.radio_outlined),
                      title: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      isThreeLine: true,
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            dateLine,
                            style: ProxType.caption(
                                color: c.contentSecondary),
                            softWrap: true,
                            maxLines: 2,
                            overflow: TextOverflow.visible,
                          ),
                          const Text(
                            'Tap to host live session',
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ],
                      ),
                      trailing: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Host'),
                          SizedBox(width: 4),
                          Icon(Icons.play_arrow),
                        ],
                      ),
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
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
