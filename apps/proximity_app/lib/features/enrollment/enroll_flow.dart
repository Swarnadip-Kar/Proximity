// Enrollment bundle flow: route helpers + IA map.
//
// Bundle (approved IA — each screen breathes on its own page):
//   EnrollIntro   (enroll/intro)   — pre-context + account + device key
//   EnrollCapture (enroll/capture) — 3-angle guided scan, per-slot retake
//   EnrollResult  (enroll/result)  — save + claim outcome with next steps
// Forward moves log NAV; Done (EnrollNav.finish) pops every `enroll/…`
// route back to the opener.
//
// Behavioral law (the plugin owns detection + matching passively):
// guided centre → left → right stills, one capture per angle with dots +
// oval guidance; per-slot retake (a failed capture keeps the other slots);
// Cancel exits keeping progress, never burns; fail-closed (no validated
// capture → no save; Save blocked till the 3 validate via self-check);
// atomic claim (one device per Gmail + install binding + 7-day move +
// heartbeats); key always kept.
//
// PROPOSALS (not applied — off-limits files, for the owner):
// 1. Wire-up (lib/main.dart, lib/screens/student_home.dart,
//    lib/screens/landing.dart): route `PROX_MODE=enroll` previews and the
//    "Enroll this device" pushes from `EnrollFlow.openBundle(context)`
//    instead of `EnrollmentScreen()`; keep the old route until the pilot
//    confirms the bundle.
// 2. Collapse-dup (lib/screens/enrollment.dart): EnrollProgress /
//    EnrollAngleRow / EnrollNotice here absorb `_AnimatedEnrollProgress` /
//    `_AngleRow` / `_EnrollNotice` there line-for-line in motion language.
//    Once the bundle replaces the old screen, delete it and repoint its two
//    importers (main.dart, student_home.dart) — do not keep both.
// 3. Roll-field dup: the ID Number field appears on Intro (entry) and
//    Result (last-chance before Save). If that jars, extract a shared
//    `EnrollRollField` here — deliberately left inline for now (lean).
import 'package:flutter/material.dart';

import 'enroll_capture.dart';
import 'enroll_intro.dart';
import 'enroll_result.dart';
import 'enroll_widgets.dart';

abstract final class EnrollFlow {
  static const introRoute = '${EnrollNav.routePrefix}intro';
  static const captureRoute = '${EnrollNav.routePrefix}capture';
  static const resultRoute = '${EnrollNav.routePrefix}result';

  /// Bundle entry: pre-context + account + key.
  static Future<void> openBundle(BuildContext context) {
    EnrollLog.nav('enroll bundle opened (intro)');
    return Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: introRoute),
        builder: (_) => const EnrollIntroScreen(),
      ),
    );
  }

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
