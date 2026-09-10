// Enrollment bundle flow: route helpers + IA map.
//
// Bundle (approved IA — each screen breathes on its own page):
//   EnrollIntro   (enroll/intro)   — pre-context + account + device key
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
import 'package:flutter/material.dart';

import 'enroll_capture.dart';
import 'enroll_result.dart';
import 'enroll_widgets.dart';

abstract final class EnrollFlow {
  static const introRoute = '${EnrollNav.routePrefix}intro';
  static const captureRoute = '${EnrollNav.routePrefix}capture';
  static const resultRoute = '${EnrollNav.routePrefix}result';

  /// Intro → Capture (key must exist; the button gates it).
  static Future<void> openCapture(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: captureRoute),
        builder: (_) => const EnrollCaptureScreen(),
      ),
    );
  }

  /// Capture → Result (5/5 validated; the button gates it).
  static Future<void> openResult(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: resultRoute),
        builder: (_) => const EnrollResultScreen(),
      ),
    );
  }
}
