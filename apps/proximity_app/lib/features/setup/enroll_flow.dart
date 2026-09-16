// Enrollment route helpers + IA map (capture/result screens, embedded as
// SetupFlow steps; the standalone intro route is deleted with the legacy
// bundle entry — SetupFlow is the only enrollment flow).
//
//   EnrollCapture (enroll/capture) — continuous 5-angle session, per-slot
//   in-session retake
//   EnrollResult  (enroll/result)  — save + claim outcome with next steps
// Forward moves log NAV; Done (EnrollNav.finish) pops every `enroll/…`
// route back to the opener.
//
// Behavioral law (buckets really gated, plugin owns matching passively):
// one continuous camera session (open once, close on done/cancel); rim
// sweep glow + one static prompt over the live preview (silent
// auto-retry); every still classified into any matching unfilled bucket
// (ML Kit euler windows on the still file — never instruction-only);
// Cancel disposes the session and enrolls nothing;
// fail-closed (no validated capture → no save; Save blocked till the 5
// validate via self-check); atomic claim (one device per Gmail + install
// binding + 30-day move + heartbeats); key always kept.
// Back contract: see setup_step_scope.dart (canonical). Scope present →
// stepper only, never push/pop; scope absent → the pushes/pops below.
import 'package:flutter/material.dart';

import '../../routes.dart';
import 'enroll_widgets.dart';

abstract final class EnrollFlow {
  static const captureRoute = '${EnrollNav.routePrefix}capture';
  static const resultRoute = '${EnrollNav.routePrefix}result';

  /// Single-flight per route: a second open while the route is still on
  /// top is dropped, so a validated double-tap never stacks two results
  /// (back from the top result then lands on capture, not a second
  /// result). Flags clear when the pushed route pops.
  static bool _captureOpen = false;
  static bool _resultOpen = false;

  @visibleForTesting
  static void debugReset() {
    _captureOpen = false;
    _resultOpen = false;
  }

  /// Intro → Capture (key must exist; the button gates it).
  /// Delegates to [ProxNav.pushNamed] so the exact-table [_guardedRoute]
  /// guards apply (web/mobile redirects); single-flight flags preserved.
  static Future<void> openCapture(BuildContext context) {
    if (_captureOpen) return Future.value();
    _captureOpen = true;
    try {
      final future = ProxNav.pushNamed(context, ProxRoutes.enrollCapture);
      return future.whenComplete(() => _captureOpen = false);
    } catch (_) {
      _captureOpen = false;
      rethrow;
    }
  }

  /// Capture → Result (5/5 validated; the button gates it).
  /// Delegates to [ProxNav.pushNamed] so the exact-table [_guardedRoute]
  /// guards apply; single-flight flags preserved.
  static Future<void> openResult(BuildContext context) {
    if (_resultOpen) return Future.value();
    _resultOpen = true;
    try {
      final future = ProxNav.pushNamed(context, ProxRoutes.enrollResult);
      return future.whenComplete(() => _resultOpen = false);
    } catch (_) {
      _resultOpen = false;
      rethrow;
    }
  }
}
