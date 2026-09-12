// Student + professor app shells (§3.1/§3.5): PageView 3-tab bodies
// (student Mark/Courses/Account; professor Live/Courses/Account) where each
// tab keeps its own Navigator — every tab preserves its stack + scroll
// position while switching, by tap or by finger-locked swipe (WhatsApp
// pattern: the page tracks the finger, snaps on release). Tab chrome only:
// tab content screens are owned by their sections and render here untouched.
//
// Back contract (§3.5): in-tab back pops that tab's stack only, never
// crosses tabs, never leaves the shell; tab-root back never exits the shell
// and never tears down a live window — first press hints, double-press
// leaves the app (OS-level, no session teardown of ours). The old
// PopScope→setMode(unset) pattern is gone (deleted at each site, not
// moved here); mode switches happen only through explicit UI (account
// switch, role continue, debug previews).
//
// Enrollment home (§3.4): the shell mounts on Accounts (index 2).
// Mark/Courses stay locked (dimmed tabs, taps/swipes park on Accounts)
// until the CURRENT account's enrollment resolves; the lock lifting on
// Accounts advances to Mark. Whenever a resolve concludes UNENROLLED the
// shell auto-pushes ONE SetupFlowScreen on the shell ROOT navigator
// (covers all tabs, single-flight + generation-guarded); locked-tab
// taps/swipes re-trigger the push via a re-resolve (no dead ends — the
// flow push is the only way forward). Completion pops (the identity
// listener's resolve then unlocks + advances to Mark); back-out pops to
// locked Accounts.
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';

import '../core/auth.dart';
import '../core/device_store.dart';
import '../core/platformx.dart';
import '../features/entry/entry_flow.dart';
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
import '../widgets/prox_cards.dart';
import '../widgets/prox_glass.dart';
import '../widgets/student_card.dart' show CourseLogo;
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
/// output); null/empty falls back to the signed-in initial. No ring —
/// active state comes from the pill + label (same as other tabs).
/// 26dp avatar fills the 22dp icon cell with presence.
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
          // Same cell as the tab icons so the row stays uniform.
          radius: ProxIconSizes.lg / 2,
          backgroundColor: c.contentTertiary.withValues(alpha: 0.25),
          child: Text(
            initial,
            style: TextStyle(
                fontSize: ProxType.labelSize, color: c.contentPrimary),
          ),
        );
    final photoUrl = (acct?.photoUrl ?? '').trim();
    if (photoUrl.isEmpty) return initialsAvatar();
    return ClipOval(
      child: Image.network(
        photoUrl,
        width: ProxIconSizes.lg,
        height: ProxIconSizes.lg,
        fit: BoxFit.cover,
        // Failed loads fall back to initials, never a broken icon.
        errorBuilder: (_, __, ___) => initialsAvatar(),
      ),
    );
  }
}

/// Tab motion (§3.1): taps animate the pager over [ProxDurations.tabSlide]
/// on [ProxCurves.standard]; finger drags track 1:1 (WhatsApp pattern)
/// and snap on release. Reduced motion parks the pager (swipes off, taps
/// jump). Swipes never leave a pushed sub-page (page lock) and never land
/// on a gated Mark (gate snap-back).
///
/// Keep-alive wrapper: each tab page stays mounted inside the PageView
/// (same guarantee the old IndexedStack gave), so every tab's Navigator
/// stack + scroll position survives switches. Without this the pager
/// destroys far pages outside its cache extent.
///
/// Each page carries a stable key: the pager + keep-alive bucket match
/// pages by index, and the children hold GlobalKey'd Navigators — an
/// explicit page identity guarantees a slot can never graft the wrong
/// Navigator element across eviction/reinsertion churn (page jumps that
/// cross a page, gate snap-backs, lock-gated re-resolves). Keys never
/// affect layout.
class _KeepAlivePage extends StatefulWidget {
  final Widget child;
  const _KeepAlivePage({super.key, required this.child});

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Edge-to-edge shell body: pads ONLY the system bottom inset (Android
/// 3-button nav / gesture line, iOS Home indicator) from live MediaQuery
/// viewPadding — zero hardcoded inset values, and MediaQuery also
/// rebuilds this automatically on metrics change (rotation, cutout
/// appearance, nav-mode switch, Home-indicator devices vs older ones).
/// Top/left/right are untouched (app bars and tab screens own those).
/// Paired with [Scaffold.extendBody] on the shells: the frosted bar +
/// scaffold background bleed behind the system bars while tab content
/// always clears them. Scroll content intentionally slides behind the
/// translucent bar (see [ProxGlassBottomBar]). No-op on desktop/Web
/// (zero system insets there), so those platforms render unchanged.
class _ShellEdgeBody extends StatelessWidget {
  final Widget child;
  const _ShellEdgeBody({required this.child});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      left: false,
      right: false,
      bottom: true,
      child: child,
    );
  }
}

/// Locks pager swipes while any tab holds a pushed sub-page: pushed
/// routes own horizontal gestures, so the shell must not steal them.
/// Recomputed from live Navigator state on every push/pop.
class _TabNavObserver extends NavigatorObserver {
  final VoidCallback onChanged;
  _TabNavObserver(this.onChanged);

  void _notify() => onChanged();

  @override
  void didPush(Route route, Route? previousRoute) => _notify();

  @override
  void didPop(Route route, Route? previousRoute) => _notify();

  @override
  void didRemove(Route route, Route? previousRoute) => _notify();

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) => _notify();
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

/// One tab in the shell bar: icon pair + label. Active state lives in the
/// bar render (index + MediaQuery), not the item.
/// [enabled] dims the tab when its destination is gated (student Mark /
/// Courses while unenrolled) — taps are intercepted by the shell, so this
/// is a visual + semantics affordance, not the enforcement.
@immutable
class _ShellTab {
  final Widget icon;
  final Widget activeIcon;
  final String label;
  final bool enabled;
  const _ShellTab({
    required this.icon,
    required this.activeIcon,
    required this.label,
    this.enabled = true,
  });
}

_ShellTab _tabItem({
  required Widget icon,
  required Widget activeIcon,
  required String label,
  bool enabled = true,
}) {
  // Icon pair + label only (§3.1): active/narrow live in the bar render
  // (_shellBar index + MediaQuery → _ShellBarTab); inactive stays outlined,
  // active filled, in both modes.
  return _ShellTab(
      icon: icon, activeIcon: activeIcon, label: label, enabled: enabled);
}

/// Frosted glass bottom bar with sliding gradient pill indicator.
///
/// Active tab: filled icon + label in white over the brand gradient pill.
/// Inactive tabs: outlined icon + muted label. The pill cross-fades between
/// positions on [ProxDurations.tabIndicator]. The bar sits in a
/// [ProxGlassBottomBar] so content scrolls behind with a blur transition.
///
/// Sizing (one step up from the original compact bar, token-driven):
/// icons [ProxIconSizes.lg], labels 13sp semibold ([ProxType.labelSize]),
/// pill padding vertical xs / horizontal sm, bar padding vertical xs /
/// horizontal sm.
Widget _shellBar({
  required BuildContext context,
  required int index,
  required List<_ShellTab> items,
  required ValueChanged<int> onTap,
}) {
  final narrow = MediaQuery.sizeOf(context).width < 360;

  final glass = ProxGlass.of(context);
  return ClipRRect(
    key: const ValueKey('shell-bar'),
    borderRadius: ProxRadii.sheetTopRadius,
    child: BackdropFilter(
      filter: ImageFilter.blur(
        sigmaX: glass.blurSigma,
        sigmaY: glass.blurSigma,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: glass.tintColor.withValues(alpha: glass.tintOpacity),
          borderRadius: ProxRadii.sheetTopRadius,
          border: Border(
            top: BorderSide(color: glass.borderColor, width: 0.5),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                vertical: ProxSpacing.xs, horizontal: ProxSpacing.sm),
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    flex: 1,
                    // xs gutter each side -> sm gap between pills,
                    // highlights never touch.
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: ProxSpacing.xs),
                      child: _ShellBarTab(
                        key: ValueKey('shell-tab-${items[i].label}'),
                        tab: items[i],
                        active: i == index,
                        narrow: narrow,
                        onTap: () => onTap(i),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Individual tab: gradient pill when active, plain when idle.
/// Icon on top, label below, both center-aligned; icon settles 4dp on
/// activation; label uses 13sp semibold ([ProxType.labelSize]).
class _ShellBarTab extends StatelessWidget {
  final _ShellTab tab;
  final bool active;
  final bool narrow;
  final VoidCallback onTap;

  const _ShellBarTab({
    super.key,
    required this.tab,
    required this.active,
    required this.narrow,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final icon = _SettleIcon(
      active: active,
      child: active ? tab.activeIcon : tab.icon,
    );
    final label = !narrow
        ? Padding(
            padding: const EdgeInsets.only(top: ProxSpacing.xs),
            child: Text(
              tab.label,
              style: ProxType.label(
                color: active ? Colors.white : c.contentSecondary,
              ).copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: ProxType.labelSize),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          )
        : const SizedBox.shrink();

    // NOTE: no Center/Align/Container-alignment anywhere in this subtree:
    // the Scaffold bottom-bar slot measures with unbounded height and
    // expanding alignment widgets resolve to full-screen height, collapsing
    // the body to zero (see tab_slide swipe tests). Min-sizing Row/Column
    // only — the outer Row centers the pill horizontally, heights hug
    // content.
    final pill = AnimatedContainer(
      duration:
          ProxMotion.effective(context, ProxDurations.tabIndicator),
      curve: ProxCurves.standard,
      // Equal-width cells: fixed padding for active + idle so the
      // highlight never shifts width on selection. Width comes from
      // the outer Expanded, not content hug. xs/sm steps keep the tab
      // cell above the 48px min-tap contract with lg icons.
      padding: const EdgeInsets.symmetric(
          vertical: ProxSpacing.xs, horizontal: ProxSpacing.sm),
      decoration: BoxDecoration(
        gradient: active ? c.gradientBrand : null,
        borderRadius: BorderRadius.circular(ProxRadii.pill),
        boxShadow: active
            ? [
                BoxShadow(
                  color: c.accentBrand.withValues(alpha: 0.28),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconTheme(
            data: IconThemeData(
              color: active ? Colors.white : c.contentSecondary,
              size: ProxIconSizes.lg,
            ),
            child: icon,
          ),
          // Column width caps at the cell width (outer Flexible), so a
          // long label ellipsizes instead of overflowing the pill. No
          // Flexible here: the bar slot is unbounded vertically, so
          // vertical flex would break (see NOTE above).
          label,
        ],
      ),
    );

    return Semantics(
      button: true,
      selected: active,
      enabled: tab.enabled,
      label: tab.label,
      hint: tab.enabled ? null : 'Requires enrollment',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // Flexible (loose) caps the pill at the cell width on narrow
        // phones — the label ellipsizes instead of striping. Still
        // min-sizing vertically, so the bar height hugs content.
        // Disabled tabs (gated destinations) render dimmed via a static
        // Opacity — no animation, settle-safe. Enforcement lives in the
        // shell's tab selection, not here.
        child: Opacity(
          opacity: tab.enabled ? 1.0 : 0.45,
          // Equal-width highlight: outer Expanded cells are identical
          // flex:1, pill is the direct child so it fills the full cell
          // width. No inner Row/Flexible — content hug was causing
          // Mark < Courses/Account widths.
          child: pill,
        ),
      ),
    );
  }
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
///
/// Veto-consulting (F08): forwards via [NavigatorState.maybePop] — never
/// `canPop` + direct `pop` — so a pushed Take route's PopScope(canPop:false)
/// veto runs its awaited teardown (timers→save→endHosting) instead of being
/// forcibly popped with hosting up. A vetoed pop (still canPop) returns
/// early with no hint/exit; only a true tab-root (nothing to pop) reaches
/// the hint/exit below. Take's single-flight (_leaving/_bypass) covers a
/// second back arriving mid-await (its re-fired intercept no-ops).
Future<void> _shellBack(
  BuildContext context,
  GlobalKey<NavigatorState> tabNav,
  DateTime? lastBack,
  ValueChanged<DateTime?> setLastBack,
) async {
  final nav = tabNav.currentState;
  if (nav != null && nav.canPop()) {
    await nav.maybePop();
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
  /// Accounts-first start: fresh installs, re-sign-ins and unenrolled
  /// accounts land on the Account tab (index 2), where enrollment lives.
  /// Mark/Courses stay disabled until enrollment resolves (see
  /// [_tabsLocked]); an enrolled resolve advances to Mark below.
  var _index = 2;
  final _markNav = GlobalKey<NavigatorState>();
  final _coursesNav = GlobalKey<NavigatorState>();
  final _accountNav = GlobalKey<NavigatorState>();
  DateTime? _lastBack;
  // Pager driver (WhatsApp pattern): taps animate, finger drags track 1:1
  // and snap on release. [_pageLocked] parks swipes while any tab holds a
  // pushed sub-page (recomputed from live Navigator state on push/pop).
  late final PageController _pages = PageController(initialPage: 2);
  var _pageLocked = false;
  late final List<_TabNavObserver> _navObservers =
      List.generate(3, (_) => _TabNavObserver(_refreshPageLock));

  /// True while Mark/Courses are unreachable (no enrollment for the
  /// current account). Starts locked: a fresh start must prove enrollment
  /// before leaving Accounts. Unlocks only on a positive resolve.
  var _tabsLocked = true;

  /// Generation guard for the async resolve: rapid account-switch → tab
  /// switches overlap the store relink read; stale generations abort
  /// without navigating.
  var _gateGen = 0;

  /// Single-flight for the auto-pushed setup flow: true from the moment a
  /// push is scheduled until its route pops (any exit path). Re-taps,
  /// re-swipes and overlapping resolves all funnel through
  /// [_maybePushFlow], which no-ops while this is set — rapid storms
  /// settle on exactly one flow.
  var _flowOpen = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _refreshPageLock() {
    final locked = [_markNav, _coursesNav, _accountNav]
        .any((k) => k.currentState?.canPop() ?? false);
    if (locked != _pageLocked && mounted) {
      setState(() => _pageLocked = locked);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initialResolve());
    });
  }

  GlobalKey<NavigatorState> _nav(int i) =>
      [_markNav, _coursesNav, _accountNav][i];

  void _selectTab(int i) {
    if (i == _index) return;
    // Locked destinations never activate: park on Accounts and re-trigger
    // the setup flow (no-dead-end rule — the flow push is the only way
    // forward now the Account entry surfaces are gone). The push itself is
    // resolve-gated (see [_refreshEnrollmentState] → [_applyResolved]) so
    // a stale lock racing an enrolled relink never prompts redundantly.
    if (_tabsLocked && (i == 0 || i == 1)) {
      _stayOnAccountAndPushFlow();
      return;
    }
    setState(() => _index = i);
    _animateTo(i);
  }

  /// Locked-tap landing: park on Accounts, then re-resolve the CURRENT
  /// account — an unenrolled conclusion re-pushes the flow (single-flight).
  /// No snackbar: the pushed flow IS the hint (dropped to avoid snackbar
  /// storms on rapid taps; dimming + snap-back remain the visual layer).
  void _stayOnAccountAndPushFlow() {
    if (!mounted) return;
    if (_index != 2) {
      setState(() => _index = 2);
      _animateTo(2);
    }
    unawaited(_refreshEnrollmentState());
  }

  void _animateTo(int i) {
    if (!_pages.hasClients) return;
    if (ProxMotion.reduced(context)) {
      _pages.jumpToPage(i);
      return;
    }
    _pages.animateToPage(
      i,
      duration: ProxDurations.tabSlide,
      curve: ProxCurves.standard,
    );
  }

  /// Pager landing (§3.1): same lock as taps. A swipe toward a locked
  /// destination (Mark/Courses while unenrolled) snaps back to Accounts —
  /// locked tabs never land, never show bare mark — and re-triggers the
  /// setup flow via a re-resolve (no-dead-end rule). A swipe that somehow
  /// lands on a pushed sub-page also snaps back (belt to the [_pageLocked]
  /// physics suspenders).
  ///
  /// Account-switch race: the linked identity repopulates asynchronously
  /// ([relinkLinkedIdentity] reads the store after sign-in), so a sync
  /// null-check here would misread an enrolled returner. Snap back
  /// optimistically, then resolve the CURRENT account before landing —
  /// the resolve pushes only when genuinely unenrolled.
  void _syncIndexFromPage(int page) {
    if (page == _index) return;
    bool canPop = false;
    try {
      canPop = _nav(page).currentState?.canPop() ?? false;
    } catch (_) {
      canPop = false;
    }
    if (canPop) {
      try {
        if (_pages.hasClients) _pages.jumpToPage(_index);
      } catch (_) {}
      return;
    }
    if (_tabsLocked && (page == 0 || page == 1)) {
      try {
        if (_pages.hasClients) _pages.jumpToPage(_index);
      } catch (_) {}
      unawaited(_refreshEnrollmentState());
      return;
    }
    if (!mounted) return;
    setState(() => _index = page);
  }

  /// True when [linked] is bound to [acct] (same Gmail, case-insensitive).
  /// A stale linked identity from a previous account never counts — the
  /// gate + join paths must resolve the CURRENT account, never any cached
  /// enrollment.
  bool _linkedMatchesAccount(SignedAccount? acct, LinkedIdentity? linked) {
    final want = acct?.email.trim().toLowerCase() ?? '';
    if (want.isEmpty || linked == null) return false;
    return linked.gmail.trim().toLowerCase() == want;
  }

  /// Resolve the CURRENT account's enrollment: fast-path on the live
  /// linked identity, else one relink attempt (stored enrollment read for
  /// this Gmail — covers the sign-in → tab-build race where linked is
  /// still null). Returns true = enrolled (gate stays shut), false =
  /// genuinely unenrolled (push), null = stale/aborted (newer gate owns
  /// the decision — caller must do nothing, never push/pop).
  SignedAccount? _readCurrentAccount() {
    try {
      final streamed = ref.read(accountProvider).valueOrNull;
      if (streamed != null) return streamed;
    } catch (_) {}
    // Stream loading gap (cold start / switch mid-flight): fall back to the
    // synchronous session so the gate never misreads a live session as
    // signed-out.
    try {
      return ref.read(authServiceProvider).current;
    } catch (_) {
      return null;
    }
  }

  Future<bool?> _resolveCurrentEnrollment(int gen) async {
    var acct = _readCurrentAccount();
    LinkedIdentity? linked;
    try {
      linked = ref.read(linkedIdentityProvider);
    } catch (_) {
      linked = null;
    }
    if (_linkedMatchesAccount(acct, linked)) return true;
    if (acct == null) return false;
    final want = acct.email.trim().toLowerCase();
    // Async gap: the store read + provider touch below may outlive a
    // rapid switch or disposal. [relinkLinkedIdentity] is fail-soft (never
    // throws, swallows dead-screen touches), so awaiting it is safe.
    try {
      await relinkLinkedIdentity(ref, acct);
    } catch (_) {}
    if (!mounted || gen != _gateGen) return null;
    final freshAcct = _readCurrentAccount();
    LinkedIdentity? freshLinked;
    try {
      freshLinked = ref.read(linkedIdentityProvider);
    } catch (_) {
      freshLinked = null;
    }
    final freshWant = freshAcct?.email.trim().toLowerCase() ?? '';
    if (freshWant != want) return null;
    return _linkedMatchesAccount(freshAcct, freshLinked);
  }

  /// First-frame resolve: the shell mounts on Accounts (index 2). An
  /// enrolled current account advances to Mark once proven; anything else
  /// stays on Accounts with Mark/Courses locked and auto-pushes the setup
  /// flow (single-flight). Generation-guarded so a switch racing mount
  /// cannot land the wrong tab or push a stale flow.
  Future<void> _initialResolve() async {
    if (!mounted) return;
    final gen = ++_gateGen;
    final resolved = await _resolveCurrentEnrollment(gen);
    if (!mounted || gen != _gateGen) return;
    if (resolved == null) return;
    _applyResolved(resolved, gen);
  }

  /// Applies a resolve result: unlocks + advances to Mark on enrolled,
  /// locks + parks on Accounts and auto-pushes ONE SetupFlowScreen when
  /// not. The Mark advance fires only on the locked → unlocked transition
  /// (or the initial resolve) while sitting on Accounts — an enrolled user
  /// browsing Accounts is never yanked away. The lock → Accounts move fires
  /// whenever the current tab is unreachable, so sign-out / unenrolled
  /// switches can never strand the UI on bare Mark/Courses. Enrolled never
  /// pushes (the reported original bug stays fixed): the push lives only
  /// on the unenrolled branch, behind the generation + single-flight
  /// guards in [_maybePushFlow].
  void _applyResolved(bool enrolled, int gen) {
    if (!mounted || gen != _gateGen) return;
    if (enrolled) {
      // Advance to Mark only from the Account ROOT: while the auto-pushed
      // flow is open above the shell, the user stays in it to finish
      // explicitly (Done pops to reveal the already-unlocked shell; the
      // identity listener's resolve advances to Mark underneath). Advancing
      // mid-flow would yank the pager under the flow's success screen.
      var atAccountRoot = true;
      try {
        atAccountRoot = !(_accountNav.currentState?.canPop() ?? false);
      } catch (_) {}
      final advancing = _tabsLocked && _index == 2 && atAccountRoot;
      if (_tabsLocked) setState(() => _tabsLocked = false);
      if (advancing && mounted && _index == 2) {
        setState(() => _index = 0);
        // Atomic jump, NOT the animated slide: the 2→0 slide crosses page
        // 1, whose intermediate onPageChanged would land [_index] on
        // Courses mid-flight (and any mid-flight rebuild can cancel the
        // animation, stranding pager + index desynced). Enforcement moves
        // land atomically; user taps/swipes keep the slide (always
        // single-step, never crossing). Jump fires a single onPageChanged
        // for the target, which [_syncIndexFromPage] early-returns on.
        try {
          if (_pages.hasClients) _pages.jumpToPage(0);
        } catch (_) {}
      }
      return;
    }
    if (!_tabsLocked && mounted) setState(() => _tabsLocked = true);
    if (mounted && _index != 2) {
      setState(() => _index = 2);
      _animateTo(2);
    }
    _maybePushFlow(gen);
  }

  /// Auto-push ONE SetupFlowScreen on the shell ROOT navigator (covers all
  /// tabs) whenever a resolve concludes UNENROLLED. Single-flight via
  /// [_flowOpen] (set synchronously before the push, cleared on pop by any
  /// exit path) + the existing generation guard (stale generations abort,
  /// re-checked here because the async resolve gap may have been overtaken
  /// between [_applyResolved] and now). `onComplete` pops (the identity
  /// listener's resolve then unlocks + advances to Mark); `onFirstBack`
  /// pops back to locked Accounts (never bare Mark — the lock + park above
  /// already ran). Mounted-checked throughout; Navigator lookup is
  /// fail-soft so a dead context never crashes. Rapid storms settle on
  /// exactly one flow: the first push wins, the rest no-op on [_flowOpen].
  void _maybePushFlow(int gen) {
    if (!mounted) return;
    if (gen != _gateGen) return;
    if (!_tabsLocked) return;
    if (_flowOpen) return;
    NavigatorState root;
    try {
      root = Navigator.of(context, rootNavigator: true);
    } catch (_) {
      return;
    }
    _flowOpen = true;
    BleLog.log('NAV', 'shell auto-push: unenrolled → setup flow');
    try {
      root
          .push(proxSharedAxisRoute(
            context,
            name: ProxRoutes.setupFlow,
            child: SetupFlowScreen(
              onFirstBack: () async {
                if (!mounted) return;
                try {
                  final n = Navigator.of(context, rootNavigator: true);
                  if (n.canPop()) n.pop();
                } catch (_) {}
              },
              onComplete: () async {
                if (!mounted) return;
                try {
                  final n = Navigator.of(context, rootNavigator: true);
                  if (n.canPop()) n.pop();
                } catch (_) {}
              },
            ),
          ))
          .then((_) {
        _flowOpen = false;
      });
    } catch (_) {
      _flowOpen = false;
    }
  }

  /// Re-resolve the CURRENT account's enrollment (initial mount, taps,
  /// swipes, identity / account changes, first registration all funnel
  /// here). Stale generations abort silently — the newest resolve owns
  /// navigation and the single auto-push.
  Future<void> _refreshEnrollmentState() async {
    if (!mounted) return;
    final gen = ++_gateGen;
    final resolved = await _resolveCurrentEnrollment(gen);
    if (!mounted || gen != _gateGen) return;
    if (resolved == null) return;
    _applyResolved(resolved, gen);
  }

  void _armGate() {
    // Called from build (like before): Riverpod scopes each `ref.listen`
    // to the build, so re-arming every build keeps exactly the current
    // subscription live without leaking across rebuilds.
    ref.listen<LinkedIdentity?>(linkedIdentityProvider, (prev, next) {
      if (!mounted) return;
      final p = prev?.gmail.trim().toLowerCase() ?? '';
      final n = next?.gmail.trim().toLowerCase() ?? '';
      if (p == n) return;
      // Any identity change re-resolves (sign-out / relink / claim /
      // switch / first registration). Generation guards the relink gap;
      // the resolver moves tabs as needed and auto-pushes one flow on an
      // unenrolled conclusion (single-flight).
      unawaited(_refreshEnrollmentState());
    });
    ref.listen<AsyncValue<SignedAccount?>>(accountProvider, (prev, next) {
      if (!mounted) return;
      SignedAccount? p;
      SignedAccount? n;
      try {
        p = prev?.valueOrNull;
      } catch (_) {
        p = null;
      }
      try {
        n = next.valueOrNull;
      } catch (_) {
        n = null;
      }
      final pe = p?.email.trim().toLowerCase() ?? '';
      final ne = n?.email.trim().toLowerCase() ?? '';
      if (pe == ne) return;
      unawaited(_refreshEnrollmentState());
    });
  }

  @override
  Widget build(BuildContext context) {
    _armGate();
    // Account Navigator (and its tab root) alive across sign-out/sign-in,
    // so the root is keyed by the signed-in Gmail — a switch unmounts the
    // previous account's page, dropping its cached reads, and mounts a
    // fresh one for the current account. Watched (not read) so the key
    // tracks the live account stream; signed out keys as 'signed-out', so
    // sign-out clears the displayed identity immediately.
    final accountTabKey = ValueKey(
        'student-account-${ref.watch(accountProvider).valueOrNull?.email.trim().toLowerCase() ?? 'signed-out'}');
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(
            _shellBack(context, _nav(_index), _lastBack, (v) => _lastBack = v));
      },
      child: Scaffold(
        // Mobile edge-to-edge: body + bar bleed behind the transparent
        // system bars (see [_ShellEdgeBody]); desktop/Web keep the
        // classic inset layout unchanged.
        extendBody: isMobile,
        body: _ShellEdgeBody(
          child: PageView(
            // Finger-locked paging (WhatsApp pattern): the page tracks the
            // finger 1:1 and snaps on release — every tab, centre included
            // (no gesture-arena fling to lose). [_KeepAlivePage] preserves
            // each tab's stack + scroll exactly as the old IndexedStack did.
            controller: _pages,
            physics: (_pageLocked || ProxMotion.reduced(context))
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            onPageChanged: _syncIndexFromPage,
            children: [
              for (var i = 0; i < 3; i++)
                _KeepAlivePage(
                  // Stable page identity (see [_KeepAlivePage]): the slot
                  // always retakes its own GlobalKey'd Navigator.
                  key: ValueKey('student-tab-$i'),
                  child: Navigator(
                    key: _nav(i),
                    observers: [_navObservers[i]],
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
            ],
          ),
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
              // Locked until enrollment resolves: dimmed + taps park on
              // Accounts (enforced in [_selectTab], not in the bar).
              enabled: !_tabsLocked,
            ),
            _tabItem(
              icon: const Icon(Icons.layers_outlined),
              activeIcon: const Icon(Icons.layers),
              label: 'Courses',
              enabled: !_tabsLocked,
            ),
            _tabItem(
              icon: const _AccountTabIcon(active: false),
              activeIcon: const _AccountTabIcon(active: true),
              label: 'Account',
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
  // Same pager driver as the student shell (see above).
  late final PageController _pages = PageController();
  var _pageLocked = false;
  late final List<_TabNavObserver> _navObservers =
      List.generate(3, (_) => _TabNavObserver(_refreshPageLock));

  GlobalKey<NavigatorState> _nav(int i) =>
      [_liveNav, _coursesNav, _accountNav][i];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _refreshPageLock() {
    final locked = [_liveNav, _coursesNav, _accountNav]
        .any((k) => k.currentState?.canPop() ?? false);
    if (locked != _pageLocked && mounted) {
      setState(() => _pageLocked = locked);
    }
  }

  void _selectTab(int i) {
    if (i == _index) {
      if (i == 0) _liveRootKey.currentState?.refresh();
      return;
    }
    setState(() => _index = i);
    if (i == 0) _liveRootKey.currentState?.refresh();
    if (_pages.hasClients) {
      if (ProxMotion.reduced(context)) {
        _pages.jumpToPage(i);
      } else {
        _pages.animateToPage(
          i,
          duration: ProxDurations.tabSlide,
          curve: ProxCurves.standard,
        );
      }
    }
  }

  /// Pager landing: no gate on this shell — every in-range swipe lands.
  /// A swipe that somehow lands on a pushed sub-page snaps back (belt to
  /// the [_pageLocked] physics suspenders).
  void _syncIndexFromPage(int page) {
    if (page == _index) return;
    if (_nav(page).currentState?.canPop() ?? false) {
      _pages.jumpToPage(_index);
      return;
    }
    setState(() => _index = page);
    if (page == 0) _liveRootKey.currentState?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    // Same stale-account keying as the student shell (see above): the
    // professor Account root is keyed by the signed-in Gmail so a switch
    // remounts it for the current account.
    final accountTabKey = ValueKey(
        'prof-account-${ref.watch(accountProvider).valueOrNull?.email.trim().toLowerCase() ?? 'signed-out'}');
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(
            _shellBack(context, _nav(_index), _lastBack, (v) => _lastBack = v));
      },
      child: Scaffold(
        // Mobile edge-to-edge: body + bar bleed behind the transparent
        // system bars (see [_ShellEdgeBody]); desktop/Web keep the
        // classic inset layout unchanged.
        extendBody: isMobile,
        body: _ShellEdgeBody(
          child: PageView(
            // Finger-locked paging (WhatsApp pattern) — see student shell.
            controller: _pages,
            physics: (_pageLocked || ProxMotion.reduced(context))
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            onPageChanged: _syncIndexFromPage,
            children: [
              for (var i = 0; i < 3; i++)
                _KeepAlivePage(
                  // Stable page identity (see [_KeepAlivePage]).
                  key: ValueKey('prof-tab-$i'),
                  child: Navigator(
                    key: _nav(i),
                    observers: [_navObservers[i]],
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
            ],
          ),
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
            ),
            _tabItem(
              icon: const Icon(Icons.layers_outlined),
              activeIcon: const Icon(Icons.layers),
              label: 'Courses',
            ),
            _tabItem(
              icon: const _AccountTabIcon(active: false),
              activeIcon: const _AccountTabIcon(active: true),
              label: 'Account',
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
  /// Called by the shell on every Live-tab select: the keep-alive pager +
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
          final courses = data.isNotEmpty && data[0] is List<Course>
              ? data[0] as List<Course>
              : const <Course>[];
          final history = data.length >= 2 && data[1] is List<ClassRecord>
              ? data[1] as List<ClassRecord>
              : const <ClassRecord>[];
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
                    // Host entry as a shared card (same shell as the
                    // Courses-tab pickers): course logo disc + name + date
                    // + host line + Host action. Push + log + route name.
                    // (Raw ListTile hover/focus paints a stock rectangle
                    // here — the design-system card replaces it.)
                    return Padding(
                      padding:
                          const EdgeInsets.only(bottom: ProxSpacing.sm),
                      child: ProxCard(
                        onTap: () {
                          BleLog.log('NAV', 'live root → host $name');
                          Navigator.of(context).push(proxSharedAxisRoute(
                            context,
                            name: ProxRoutes.live(name),
                            child: TakeAttendanceScreen(courseName: name),
                          ));
                        },
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            CourseLogo(course: name),
                            const SizedBox(width: ProxSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    name,
                                    style: ProxType.body(
                                        color: c.contentPrimary),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                  const SizedBox(height: 2),
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
                            ),
                            const SizedBox(width: ProxSpacing.sm),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Host',
                                  style: ProxType.label(
                                      color: c.accentBrand),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.play_arrow,
                                  color: c.accentBrand,
                                  size: ProxIconSizes.md,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
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
