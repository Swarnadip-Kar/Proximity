// SetupFlowScreen — the ONE serialized enrollment flow (§3.3).
//
// One flow, two triggers: the fresh-install path (AppMode.enroll home) and
// the Mark-tab enrollment gate (shell pushes this when linkedIdentity is
// null). Pages, one purpose per page (## Setup pagination; container change,
// no route removal — standalone enroll/* routes stay for deep-links):
//   0 Sign in (welcome) → 1 Pick role (roles hub) → 2 Confirm device →
//   3 Account & key (ID + key) → 4 Capture face (5-angle session, camera
//   logic untouched) → 5 Done (save + claim outcome).
//
// (## About-page removal 2026-09-10: the About-to-enroll explainer page is
// gone from the flow; its sections stay live on the standalone
// deep-linkable EnrollIntroScreen.)
//
// Stepper chrome owned here: thin progress line (SetupProgressLine — no
// numbered circles, no step labels; the current title lives in each step's
// own app bar), 150ms step-slides (ProxDurations.step; reduced motion jumps
// with no slide). Step content lives in features/setup/; steps drive this
// stepper via SetupStepScope instead of pushing standalone routes (scope
// absent → legacy pushes preserved, so standalone enroll/* routes,
// deep-links, and widget tests behave as before).
//
// Starting index is computed from existing state (account → role cache →
// device key → controller phase), so returning users skip cleared steps;
// sign-in / sign-out / face-validation events auto-advance while visible.
// Back moves one step back; back from the first step calls [onFirstBack]
// (parent routes to Account/RoleHub — never bare mark/browse).
// Completion calls [onComplete] (parent lands on mark/browse or the
// in-progress window resume — never the roles hub).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';

import '../core/auth.dart';
import '../core/cloud_sync.dart';
import '../core/device_store.dart';
import '../core/enrollment.dart';
import '../design/tokens.dart';
import '../features/setup/device_intro_step.dart';
import '../features/setup/enroll_capture.dart';
import '../features/setup/enroll_result.dart';
import '../features/setup/role_hub_screen.dart';
import '../features/setup/setup_progress.dart';
import '../features/setup/setup_step_scope.dart';
import '../features/setup/welcome_screen.dart';

/// Pure start-step computation (unit-tested): first incomplete step from
/// existing state. Role means the *student* registration (prof-only
/// accounts still pick/merge the student role); key means the device key
/// exists; phase faceDone/uploaded means capture validated.
int setupStartIndex({
  required bool signedIn,
  required bool hasStudentRole,
  required bool hasKey,
  required EnrollPhase phase,
}) {
  if (!signedIn) return SetupStep.welcome;
  if (!hasStudentRole) return SetupStep.role;
  if (phase == EnrollPhase.uploaded || phase == EnrollPhase.faceDone) {
    return SetupStep.result;
  }
  if (hasKey) return SetupStep.capture;
  return SetupStep.device;
}

/// Serialized setup flow. See file docs for the step map and triggers.
class SetupFlowScreen extends ConsumerStatefulWidget {
  /// Back from the first step (parent routes to Account/RoleHub, or hints
  /// when the flow is the app home).
  final Future<void> Function() onFirstBack;

  /// Flow completed (Done on the result step — parent lands on
  /// mark/browse, never the roles hub).
  final Future<void> Function() onComplete;

  const SetupFlowScreen({
    super.key,
    required this.onFirstBack,
    required this.onComplete,
  });

  @override
  ConsumerState<SetupFlowScreen> createState() => _SetupFlowScreenState();
}

class _SetupFlowScreenState extends ConsumerState<SetupFlowScreen> {
  late final PageController _pages;
  var _index = SetupStep.welcome;
  var _settled = false;

  /// The capture step mounts its camera session lazily: building all pages
  /// upfront would open the camera on the sign-in step.
  var _seenCapture = false;

  @override
  void initState() {
    super.initState();
    _pages = PageController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Silent account pickup for the whole flow (mirrors the standalone
      // intro screen's post-frame pickup): steps read the draft account,
      // so the form (not a second sign-in button) greets returning
      // sessions. Fresh installs with no session keep the manual button.
      unawaited(
          ref.read(enrollmentControllerProvider.notifier).pickUpAccount());
      _resolveStart();
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// First incomplete step from existing state (account → role cache →
  /// device key → controller phase). Jump, never animate: this is initial
  /// placement, not a step transition.
  Future<void> _resolveStart() async {
    Map<String, String>? role;
    try {
      role = await ref.read(deviceStoreProvider).readRole();
    } catch (_) {}
    if (!mounted) return;
    final acct = ref.read(accountProvider).valueOrNull;
    final ctl = ref.read(enrollmentControllerProvider);
    final at = setupStartIndex(
      signedIn: acct != null,
      hasStudentRole:
          acct != null && roleHas(role, 'student', email: acct.email),
      hasKey: ctl.pkHex.isNotEmpty,
      phase: ctl.phase,
    );
    BleLog.log('NAV', 'setup flow start at step $at');
    setState(() {
      _index = at;
      _settled = true;
      if (at >= SetupStep.capture) _seenCapture = true;
    });
    _pages.jumpToPage(at);
  }

  Future<void> _goTo(int step) async {
    final at = step.clamp(SetupStep.welcome, SetupStep.count - 1);
    if (at >= SetupStep.capture && !_seenCapture) {
      setState(() => _seenCapture = true);
    }
    setState(() => _index = at);
    if (!mounted) return;
    // Reduced motion: jump with no slide (presentation only — the step
    // graph itself is unchanged).
    if (ProxMotion.reduced(context)) {
      _pages.jumpToPage(at);
      return;
    }
    await _pages.animateToPage(
      at,
      duration: ProxDurations.step,
      curve: ProxCurves.emphasized,
    );
  }

  Future<void> _next() =>
      _index >= SetupStep.count - 1 ? Future.value() : _goTo(_index + 1);

  /// Back moves one step back; back from the first step leaves to the
  /// parent (Account/RoleHub — never bare mark/browse).
  Future<void> _back() =>
      _index <= SetupStep.welcome ? widget.onFirstBack() : _goTo(_index - 1);

  void _armListeners() {
    ref.listen<AsyncValue<SignedAccount?>>(accountProvider, (prev, next) {
      if (!mounted || !_settled) return;
      final was = prev?.valueOrNull;
      final now = next.valueOrNull;
      if (was == null && now != null) {
        // Signed in inside the flow: the sign-in step just cleared.
        if (_index == SetupStep.welcome) _goTo(SetupStep.role);
      } else if (was != null && now == null) {
        // Signed out inside the flow: restart from sign-in.
        _goTo(SetupStep.welcome);
      } else if (was?.email.toLowerCase() != now?.email.toLowerCase() &&
          now != null) {
        // Account switch inside the flow: recompute from scratch.
        _resolveStart();
      }
    });
    ref.listen<EnrollPhase>(enrollmentControllerProvider.select((s) => s.phase),
        (prev, next) {
      if (!mounted || !_settled) return;
      // Capture validated while visible (the capture step also advances
      // itself — this is the redundant safety net, idempotent).
      if ((next == EnrollPhase.faceDone || next == EnrollPhase.uploaded) &&
          _index < SetupStep.result) {
        _goTo(SetupStep.result);
      }
    });
  }

  Widget _page(int step, SignedAccount? acct) {
    switch (step) {
      case SetupStep.welcome:
        return const WelcomeScreen();
      case SetupStep.role:
        if (acct == null) return const WelcomeScreen();
        return RoleHubScreen(
          key: ValueKey<String>(acct.email.toLowerCase()),
          account: acct,
        );
      case SetupStep.device:
        return const DeviceConfirmStep();
      case SetupStep.accountKey:
        return const AccountKeyStep();
      case SetupStep.capture:
        // Lazy camera session (see _seenCapture): an unvisited capture
        // step is an empty page, never an opened camera.
        return _seenCapture
            ? const EnrollCaptureScreen()
            : const SizedBox.shrink();
      case SetupStep.result:
      default:
        return const EnrollResultScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    _armListeners();
    final acct = ref.watch(accountProvider).valueOrNull;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // System/tab-root back inside the flow: one step back, or the
        // parent route (Account/RoleHub) from the first step. Never pops
        // the shell, never tears down a live window.
        if (didPop) return;
        if (_index > SetupStep.welcome) {
          _back();
        } else {
          widget.onFirstBack();
        }
      },
      child: Scaffold(
        // Single persistent progress overlay below the steps' own app bars
        // (at the body top, inside the safe area) — never one line per
        // page above the inner Scaffolds. Stepper behavior (start index,
        // listeners, lazy camera mount, step back) is untouched.
        body: SetupStepScope(
          index: _index,
          count: SetupStep.count,
          next: _next,
          back: _back,
          goTo: _goTo,
          complete: () => widget.onComplete(),
          child: Stack(
            children: [
              PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _index = i),
                children: [
                  for (var i = SetupStep.welcome; i < SetupStep.count; i++)
                    _page(i, acct),
                ],
              ),
              SetupProgressOverlay(
                  index: _index, count: SetupStep.count),
            ],
          ),
        ),
      ),
    );
  }
}
