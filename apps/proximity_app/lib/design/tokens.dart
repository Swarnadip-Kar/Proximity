// Proximity design tokens — single source of visual + motion truth.
//
// Phase 1 foundation: every screen pulls durations, curves, spacing,
// radii, state colors and typography from here. No screen hand-rolls its
// own animation timing, button shape, or state color.
//
// Behavior contract: tokens are pure presentation. They never gate user
// actions, never change timing guarantees (BLE rotation, grace periods,
// timeouts), and never touch security properties. Animations built on
// these tokens must stay interruptible and skippable.
library;

import 'package:flutter/material.dart';

/// Duration scale. Named by intent, not by screen:
/// - [micro]: press ripples, icon toggles (120ms)
/// - [small]: fades, list-item entrances (200ms)
/// - [medium]: counters, AnimatedSwitcher flips, sheet slides (350ms)
/// - [large]: hero/verdict entrances, enrollment confirmations (600ms)
abstract final class ProxDurations {
  static const micro = Duration(milliseconds: 120);
  static const small = Duration(milliseconds: 200);
  static const medium = Duration(milliseconds: 350);
  static const large = Duration(milliseconds: 600);

  /// Stagger step for list entrances. Keep small so a 30-row class list
  /// finishes staging in < 1s and never delays scrolling or taps.
  static const staggerStep = Duration(milliseconds: 40);

  /// Maximum stagger delay cap — items beyond this delay animate together
  /// instead of cascading forever on long lists.
  static const staggerCap = Duration(milliseconds: 400);
}

/// Easing vocabulary. Rule of thumb (see PROXIMITY_DESIGN §7 flows):
/// - user directly triggered it (tap, approve, start) → [spring]
/// - system drove it (beacon arrived, counter ticked) → [standard]
/// - screen-level transition / continuation → [emphasized]
abstract final class ProxCurves {
  /// System-driven changes: counters, waiting-list inserts, beacon flips.
  static const Curve standard = Curves.easeOutCubic;

  /// Screen/section transitions that should read as continuations.
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;

  /// User-triggered taps: mild overshoot, physically plausible, settles fast.
  static const Curve spring = Curves.easeOutBack;

  /// Reserved for the ✓ Marked / verdict badge pop only. Nothing else
  /// should elastic-overshoot — it would cheapen the verdict language.
  static const Curve verdictSpring = Curves.elasticOut;

  /// Clocks, progress sweeps, log autoscroll: no easing at all.
  static const Curve linear = Curves.linear;
}

/// Spacing scale (4pt grid, generous breathing room by default).
abstract final class ProxSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Standard screen padding.
  static const EdgeInsets screen = EdgeInsets.all(lg);

  /// Max content width for phone-first layouts on desktop/web.
  static const double maxContentWidth = 560;
}

/// Corner radii. One family everywhere: cards [card], buttons [button],
/// chips/badges [chip], terminal [terminal].
abstract final class ProxRadii {
  static const double sm = 8;
  static const double md = 12;
  static const double card = 14;
  static const double button = 12;
  static const double chip = 999;
  static const double terminal = 10;

  static BorderRadius get cardRadius => BorderRadius.circular(card);
  static BorderRadius get buttonRadius => BorderRadius.circular(button);
  static BorderRadius get chipRadius => BorderRadius.circular(chip);
}

/// Attendance states. These communicate *meaning*, not just decoration:
/// waiting → active → marked is the core flow; late / error / no-signal
/// are distinct verdicts and must never share a color+motion signature.
/// See `ProxStateBadge` for the paired motion language.
enum ProxState { waiting, active, marked, late, error, neutral }

/// Intentional campus-tech palette (not Material seed defaults).
///
/// Light values are tuned for white/paper surfaces; dark values are the
/// same hues lifted for contrast on near-black. Both are looked up via
/// [ProxStateColors.of] so screens never hard-code a state hex.
abstract final class ProxStateColors {
  // Light (on #F5F6FA paper).
  static const waitingLight = Color(0xFFB45309); // amber-700
  static const activeLight = Color(0xFF4340D6); // proximity indigo
  static const markedLight = Color(0xFF15803D); // emerald-700
  static const lateLight = Color(0xFFC2410C); // orange-700
  static const errorLight = Color(0xFFDC2626); // red-600
  static const neutralLight = Color(0xFF64748B); // slate-500

  // Dark (on #0E1220 ink).
  static const waitingDark = Color(0xFFFBBF24); // amber-400
  static const activeDark = Color(0xFFA5B4FC); // indigo-200
  static const markedDark = Color(0xFF4ADE80); // green-400
  static const lateDark = Color(0xFFFB923C); // orange-400
  static const errorDark = Color(0xFFF87171); // red-400
  static const neutralDark = Color(0xFF94A3B8); // slate-400

  /// State color for the current brightness. Falls back to [neutral].
  static Color of(BuildContext context, ProxState state) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (state) {
      ProxState.waiting => dark ? waitingDark : waitingLight,
      ProxState.active => dark ? activeDark : activeLight,
      ProxState.marked => dark ? markedDark : markedLight,
      ProxState.late => dark ? lateDark : lateLight,
      ProxState.error => dark ? errorDark : errorLight,
      ProxState.neutral => dark ? neutralDark : neutralLight,
    };
  }

  /// Soft tinted fill for badges/pills (12% alpha over the state color).
  static Color tint(BuildContext context, ProxState state) =>
      of(context, state).withValues(alpha: 0.12);
}

/// Brand + surface palette. The app reads as one product because every
/// screen shares these — not per-screen seed colors.
abstract final class ProxPalette {
  /// Primary indigo — lecture-hall dusk. Deeper than Material default.
  static const primaryLight = Color(0xFF4340D6);
  static const primaryDark = Color(0xFFA5B4FC);

  /// Secondary teal — "live / on-air" accent (waiting-room pulse, BLE dot).
  static const liveLight = Color(0xFF0E9F8A);
  static const liveDark = Color(0xFF2DD4BF);

  /// Paper / ink surfaces.
  static const paperLight = Color(0xFFF5F6FA);
  static const inkDark = Color(0xFF0E1220);
  static const terminalBlack = Color(0xFF0A0A0B);
}

/// Motion helpers that respect the platform reduce-motion setting.
///
/// Reduced-motion status: honored centrally here. [effective] returns
/// [Duration.zero] when `MediaQuery.disableAnimations` is true, so every
/// component built on these tokens degrades to an instant (but still
/// correct) state change. Screens must route animation durations through
/// [effective] (or the `ProxMotion` widgets, which do it internally)
/// rather than hard-coding `Duration(...)` in build methods.
abstract final class ProxMotion {
  /// Returns [base], or zero when the OS asks for reduced motion.
  static Duration effective(BuildContext context, Duration base) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : base;

  /// Whether verdict-scale hero motion should play. Verdict badges fall
  /// back to a plain fade when reduced motion is on (meaning is carried
  /// by icon + label, never by motion alone).
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);
}
