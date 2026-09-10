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

import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

// Raw-color enforcement (no custom lint exists in this repo — do not invent
// lint infra; enforce by review with this grep, run from apps/proximity_app):
//   grep -rn "Colors\." lib/screens lib/features --include="*.dart"
//   grep -rn "Color(0x" lib/screens lib/features lib/widgets --include="*.dart"
// Allowlist: `Colors.transparent` (absence of color, not a theme color) and
// anything inside lib/design/ itself (this file IS the token definition
// site). Every other hit must move onto ProximityColors/ProxStateColors/
// ProxPalette/ProxLogColors, or be flagged in INTEGRATION_LOG.md.

/// Duration scale. Named by intent, not by screen:
/// - [micro]: press ripples, icon toggles (120ms)
/// - [small]: fades, list-item entrances (200ms)
/// - [medium]: counters, AnimatedSwitcher flips, sheet slides (350ms)
/// - [large]: hero/verdict entrances, enrollment confirmations (600ms)
/// Specialty cadences below reuse the same vocabulary so every timer in
/// the app is greppable here instead of a bare `Duration(...)` in a
/// widget. Network/behavior timeouts (scan waits, HTTPS bounds, cooldowns)
/// are NOT here — those are timing guarantees, not motion.
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

  /// Verdict pop-in (✓ Marked spring). Consumed by [ProxVerdictBadge].
  static const verdictPop = Duration(milliseconds: 450);

  /// Error shake (one damped oscillation). Consumed by [ProxVerdictBadge]
  /// and the enroll notice.
  static const shake = Duration(milliseconds: 500);

  /// No-signal breathing period (calm loop, timer-driven so tests settle).
  /// Consumed by [ProxVerdictBadge].
  static const breath = Duration(milliseconds: 1200);

  /// Presence-dot pulse period (timer-driven toggle + implicit fade, so
  /// widget tests still settle). Consumed by [ProxDot] and the pulsing
  /// [ProxStateBadge].
  static const dotPulse = Duration(milliseconds: 800);

  /// System-log flush cadence: bursty radio entries coalesce to ≤5
  /// setStates/s. Consumed by the log views.
  static const logFlush = Duration(milliseconds: 200);

  /// Directory-search debounce (one round trip per pause, stale
  /// generations dropped). Consumed by the manual-add form.
  static const searchDebounce = Duration(milliseconds: 400);

  // --- Redesign §3.2/§3.3/§6 motion vocabulary (presentation only). ---
  // Added by the Foundation section; existing values above are untouched.
  // Network/behavior timeouts stay out of tokens (see class doc).

  /// Bottom-bar tab switch cross-fade (+ 4dp icon settle, §3.1).
  static const tabCrossFade = Duration(milliseconds: 120);

  /// Forward push / shared-axis horizontal slide (§3.2).
  static const push = Duration(milliseconds: 220);

  /// Bottom-sheet spring + scrim fade-in (§3.2, §6.4).
  static const sheet = Duration(milliseconds: 200);

  /// Setup-flow internal step slide — lighter than a push (§3.3).
  static const step = Duration(milliseconds: 150);

  /// `Marked` gradient wash + glow fade, non-blocking, skippable (§6.3).
  /// Shared with [ProximityColors] `glowMarked` (one event, same timing).
  static const verdictWash = Duration(milliseconds: 400);

  /// Waiting-ring morph into the camera viewfinder frame (§6.2).
  static const ringMorph = Duration(milliseconds: 300);

  /// Reduce-motion collapse target: all transitions become opacity-only
  /// cross-fades at this duration (§3.2, §9).
  static const reducedFade = Duration(milliseconds: 100);
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

  // --- Redesign §2.3 spec grid (Foundation addition). ---
  // Legacy values above are FROZEN until each rebuild section migrates its
  // screens (changing them now would silently restyle every current screen,
  // which is out of Foundation scope). New code uses the `Spec` values
  // below; see INTEGRATION_LOG.md D4.

  /// Spec grid unit: all new spacing composes from multiples of 8.
  static const double grid = 8;

  /// Spec screen horizontal margin (§2.3).
  static const double screenMargin = 20;

  /// Spec screen margins as insets (horizontal 20, vertical 0 — vertical
  /// rhythm comes from slivers/list gaps, not page padding).
  static const EdgeInsets screenMarginInsets =
      EdgeInsets.symmetric(horizontal: screenMargin);

  /// Spec card internal padding (§2.3).
  static const double cardPadding = 16;

  /// Minimum tap target edge (§2.3, §9): 48x48 regardless of visual size.
  static const double minTap = 48;

  /// Minimum tap target as a [Size] for hit-region constraints.
  static const Size minTapSize = Size(minTap, minTap);
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

  // --- Redesign §2.3 spec radii (Foundation addition, frozen-legacy rule
  // as in [ProxSpacing]: `card` stays 14 until section migrations; new code
  // uses [cardSpec]. See INTEGRATION_LOG.md D4). ---

  /// Spec card radius (§2.3): 16. Canonical for all new cards/tiles.
  static const double cardSpec = 16;

  /// Spec bottom-sheet radius (§2.3): 24, top corners only.
  static const double sheet = 24;

  /// Spec pill radius (§2.3): 999. Same value as [chip]; named for the
  /// spec vocabulary so downstream sections read spec names.
  static const double pill = 999;

  static BorderRadius get cardSpecRadius => BorderRadius.circular(cardSpec);

  static BorderRadius get sheetTopRadius =>
      const BorderRadius.vertical(top: Radius.circular(sheet));
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

/// System-log tag registry. One ring buffer ([BleLog]), one vocabulary:
///
/// - BLE / MESH / LAN / SEC / NET: the original radio tags, emitted by the
///   BLE engine, radio shim, and host/student drivers.
/// - NAV: navigation events (route pushes/pops via [ProxRouteObserver],
///   bundle moves, sign-in/out, mode continues).
/// - SYNC: cloud sync + offline-queue ops (merges, pushes/pulls, pending
///   manual-add resolution, directory-search failures).
/// - FACE: face-pipeline decision points (which slots a rescan targets,
///   what the controller dropped, gate outcomes).
/// - STATE: provider/state recompute reasons (mode transitions, role-cache
///   hits/misses, claim-gate verdicts) + errors with reproducing context.
/// - TRANSPORT: HTTPS/transport lifecycle + contract events at the
///   transport-module boundary (serve up/down, prove-pipeline milestones).
/// - CRYPTO: sign/verify decision points at the crypto-module boundary
///   (proof posted, ACK verify ok/BAD — never keys or preimages).
/// - SESSION: session/round state transitions at the session-module
///   boundary (round recorded, tally restored, manual decisions).
///   SYNC already covers cloud merges/pushes/pulls + the offline queue.
///
/// Tags are plain strings (the [BleLog] API takes any tag); these
/// constants keep every emitter and both log views spelling them the
/// same way. See [ProxLogColors] for the paired terminal colors and
/// ARCHITECTURE.md "Logging discipline" for what gets logged.
abstract final class ProxLogTags {
  static const nav = 'NAV';
  static const sync = 'SYNC';
  static const face = 'FACE';
  static const state = 'STATE';
  static const ble = 'BLE';
  static const mesh = 'MESH';
  static const lan = 'LAN';
  static const sec = 'SEC';
  static const net = 'NET';
  static const transport = 'TRANSPORT';
  static const crypto = 'CRYPTO';
  static const session = 'SESSION';
  static const clock = 'CLOCK';

  /// Every tag the log views offer as a filter chip, in display order.
  static const all = <String>[
    nav,
    sync,
    face,
    state,
    ble,
    mesh,
    lan,
    sec,
    net,
    transport,
    crypto,
    session,
    clock
  ];
}

/// Terminal colors, one per log tag. Brightness-independent (the terminal
/// is always black), so this is a pure tag→color map — the single source
/// for the full-screen debug log. Attendance
/// meaning still comes from [ProxStateColors]; these colors only tell
/// subsystems apart in the log stream.
abstract final class ProxLogColors {
  static Color of(String tag) => switch (tag) {
        ProxLogTags.nav => const Color(0xFFC084FC),
        ProxLogTags.sync => const Color(0xFF2DD4BF),
        ProxLogTags.face => const Color(0xFFFB923C),
        ProxLogTags.state => const Color(0xFF94A3B8),
        ProxLogTags.ble => const Color(0xFF4ADE80),
        ProxLogTags.mesh => const Color(0xFF60A5FA),
        ProxLogTags.lan => const Color(0xFFF472B6),
        ProxLogTags.sec => const Color(0xFFFBBF24),
        ProxLogTags.net => const Color(0xFF22D3EE),
        ProxLogTags.transport => const Color(0xFF818CF8),
        ProxLogTags.crypto => const Color(0xFFE879F9),
        ProxLogTags.session => const Color(0xFFA3E635),
        ProxLogTags.clock => const Color(0xFFFDE68A),
        _ => const Color(0xFFE5E7EB),
      };
}

// ---------------------------------------------------------------------------
// Foundation rebuild (redesign §2/§2.5/§9): semantic + effect token API.
// Everything below is ADDITIVE: legacy classes above are frozen (see
// INTEGRATION_LOG.md D3–D5) so current screens render byte-identical until
// their rebuild section migrates them onto this API.
// How a screen reads tokens:
//   final c = ProximityColors.of(context); // ThemeExtension, dark/light pair
//   color: c.statusMarked,
//   decoration: BoxDecoration(gradient: c.gradientBrand),
//   boxShadow: [c.glowLive.toShadow(), c.elevationRaised],
// ---------------------------------------------------------------------------

/// Responsive layout rules, redesign §10 (narrow / wide breakpoints).
///
/// Single source for the width contract every screen shares:
/// - narrow (< [narrowBreakpoint], 360dp): bottom bar goes icon-only
///   (labels off, tooltips carry the words), card padding drops
///   [cardPadding] → [cardPaddingNarrow], `StudentCard` round trails wrap.
/// - wide (≥ [wideBreakpoint], 600dp): list screens gain a max content
///   width ([ProxSpacing.maxContentWidth]) and center via `ConstrainedBox`
///   instead of stretching edge-to-edge — no bespoke landscape path
///   (only the camera preview screen may lay out orientation-specifically).
abstract final class ProxLayout {
  /// Narrow-width breakpoint in logical dp (§10).
  static const double narrowBreakpoint = 360;

  /// Wide/tablet breakpoint in logical dp (§10).
  static const double wideBreakpoint = 600;

  /// True below the narrow breakpoint (icon-only bar, tight card padding).
  static bool isNarrow(BuildContext context) =>
      MediaQuery.sizeOf(context).width < narrowBreakpoint;

  /// True at/above the wide breakpoint (max-width-center lists).
  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= wideBreakpoint;

  /// Spec card internal padding (§2.3): 16, dropping 16→12 below the
  /// narrow breakpoint (§10).
  static double cardPadding(BuildContext context) =>
      isNarrow(context) ? ProxSpacing.md : ProxSpacing.cardPadding;
}

/// Typography scale, redesign §2.2: single family, 3 weights only
/// (Regular/Medium/Semibold), fixed size/line-height pairs:
/// display 28/34, title 20/26, body 15/22, label 13/16, caption 11/14.
///
/// Canonical family is [family] (`Inter`, already bundled in pubspec with
/// exactly the 400/500/600 cuts this scale needs).
/// DEVIATION D3 (see INTEGRATION_LOG.md): the live `ThemeData.textTheme`
/// still pairs Space Grotesk display + Inter body with Bold 700 cuts.
/// `ProxType` declares the spec scale for all NEW components; the legacy
/// textTheme is untouched by Foundation (flipping it now would restyle
/// every screen) and consolidates during the Shared-components section.
///
/// Monospace appears ONLY for the debug terminal + short code/ID strings
/// (faceId prefix, install-ID tail, IP address) via [monoBody]/[monoCaption]
/// — never for prose, labels, or verdicts.
abstract final class ProxType {
  static const String family = 'Inter';

  static const FontWeight regular = FontWeight.w400;
  static const FontWeight medium = FontWeight.w500;
  static const FontWeight semibold = FontWeight.w600;

  static const double displaySize = 28;
  static const double titleSize = 20;
  static const double bodySize = 15;
  static const double labelSize = 13;
  static const double captionSize = 11;

  static TextStyle display({Color? color}) => TextStyle(
        fontFamily: family,
        fontSize: displaySize,
        height: 34 / displaySize,
        fontWeight: semibold,
        color: color,
      );

  static TextStyle title({Color? color}) => TextStyle(
        fontFamily: family,
        fontSize: titleSize,
        height: 26 / titleSize,
        fontWeight: semibold,
        color: color,
      );

  static TextStyle body({Color? color}) => TextStyle(
        fontFamily: family,
        fontSize: bodySize,
        height: 22 / bodySize,
        fontWeight: regular,
        color: color,
      );

  static TextStyle label({Color? color}) => TextStyle(
        fontFamily: family,
        fontSize: labelSize,
        height: 16 / labelSize,
        fontWeight: medium,
        color: color,
      );

  static TextStyle caption({Color? color}) => TextStyle(
        fontFamily: family,
        fontSize: captionSize,
        height: 14 / captionSize,
        fontWeight: regular,
        color: color,
      );

  /// Monospace at body size — debug terminal + short code/ID strings only.
  static TextStyle monoBody({Color? color}) => TextStyle(
        fontFamily: 'monospace',
        fontSize: bodySize,
        height: 22 / bodySize,
        color: color,
      );

  /// Monospace at caption size — IDs, IPs, hashes in tight rows.
  static TextStyle monoCaption({Color? color}) => TextStyle(
        fontFamily: 'monospace',
        fontSize: captionSize,
        height: 14 / captionSize,
        color: color,
      );
}

/// Glow effect spec, redesign §2.5 (`effect.glow.*`).
///
/// A glow is a colored blur at a fixed opacity (no offset): callers render
/// it with [toShadow] behind the pulsing presence ring / radar sweep
/// (`glowLive`) or the `Marked` wash (`glowMarked`). Under reduce-motion
/// the pulse/fade collapses to this same shadow rendered statically —
/// never removed (an inert ring would read as "disconnected").
@immutable
class ProxGlow {
  final Color color;
  final double blurSigma;
  final double opacity;

  const ProxGlow({
    required this.color,
    required this.blurSigma,
    required this.opacity,
  });

  Color get glowColor => color.withValues(alpha: opacity);

  BoxShadow toShadow({Offset offset = Offset.zero}) => BoxShadow(
        color: glowColor,
        blurRadius: blurSigma,
        offset: offset,
      );

  ProxGlow copyWith({Color? color, double? blurSigma, double? opacity}) =>
      ProxGlow(
        color: color ?? this.color,
        blurSigma: blurSigma ?? this.blurSigma,
        opacity: opacity ?? this.opacity,
      );

  static ProxGlow lerp(ProxGlow a, ProxGlow b, double t) => ProxGlow(
        color: Color.lerp(a.color, b.color, t) ?? a.color,
        blurSigma: lerpDouble(a.blurSigma, b.blurSigma, t) ?? a.blurSigma,
        opacity: lerpDouble(a.opacity, b.opacity, t) ?? a.opacity,
      );

  @override
  bool operator ==(Object other) =>
      other is ProxGlow &&
      other.color == color &&
      other.blurSigma == blurSigma &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(color, blurSigma, opacity);
}

/// Semantic + effect colors, redesign §2.1 + §2.5.
///
/// The single `ThemeExtension<ProximityColors>` both themes register on
/// `MaterialApp.theme/.darkTheme`. Dark/light ship at parity: every field
/// below has a per-brightness value in [.dark]/[.light]; no screen reads
/// raw `Colors.*` or hand-authors a `LinearGradient(...)` inline — a
/// hand-authored gradient/glow/shadow outside this extension is the same
/// severity violation as a raw hex color (redesign §2.5).
///
/// Contrast rule (§9), checked per gradient token against its DARKEST stop
/// (measured WCAG ratios, white text unless noted):
/// - `gradientBrand` dark, darkest stop `#5B8CFF` (white 3.16:1 — large
///   text / UI chrome only, never body copy). The Account-header wash
///   (§2.5) therefore renders SUBTLE — low opacity over `surfaceBase` —
///   so `contentPrimary` on the effective surface still passes; never lay
///   body-size text on the full-opacity gradient in dark mode.
/// - `gradientBrand` light, darkest stop `#3A63E0` (white 5.20:1 — passes
///   for body text).
/// - `gradientMarked` dark, darkest stop `#33C77A` (white 2.19:1 FAIL —
///   badge content on this wash uses dark ink `#14161A`, 8.27:1, never
///   white; the wash itself is transient 400ms reinforcement, §6.3).
/// - `gradientMarked` light, darkest stop `#1E9A5C` (white 3.60:1 —
///   large/bold badge text only; same transient-reinforcement rule).
/// - `gradientScrim`: text NEVER sits on the scrim — sheet content sits on
///   `surfaceRaised` + `elevationSheet`; the scrim only darkens the
///   backdrop (both themes use a near-black scrim for this reason).
/// No gradient/glow is ever the only signal for a state: color-plus-shape
/// (§2.4) carries the meaning; effects reinforce it.
@immutable
class ProximityColors extends ThemeExtension<ProximityColors> {
  // --- §2.1 semantic tokens ---
  final Color surfaceBase;
  final Color surfaceRaised;
  final Color surfaceOverlay;
  final Color contentPrimary;
  final Color contentSecondary;
  final Color contentTertiary;
  final Color accentBrand;
  final Color statusMarked;
  final Color statusLate;
  final Color statusReview;
  final Color statusError;
  final Color divider;

  // --- §2.5 gradient / glow / elevation tokens ---
  final LinearGradient gradientBrand;
  final LinearGradient gradientMarked;
  final LinearGradient gradientScrim;
  final ProxGlow glowLive;
  final ProxGlow glowMarked;
  final BoxShadow elevationRaised;
  final BoxShadow elevationSheet;

  // Gradient geometry (§2.5 angles, CSS convention: 0° = to top,
  // clockwise; begin/end are the unit diagonal for that angle).
  // 135° → begin top-left, end bottom-right.
  static const _brandBegin = Alignment(-0.7071, -0.7071);
  static const _brandEnd = Alignment(0.7071, 0.7071);
  // 120° → begin upper-left, end lower-right (flatter than 135°).
  static const _markedBegin = Alignment(-0.8660, -0.5);
  static const _markedEnd = Alignment(0.8660, 0.5);

  const ProximityColors({
    required this.surfaceBase,
    required this.surfaceRaised,
    required this.surfaceOverlay,
    required this.contentPrimary,
    required this.contentSecondary,
    required this.contentTertiary,
    required this.accentBrand,
    required this.statusMarked,
    required this.statusLate,
    required this.statusReview,
    required this.statusError,
    required this.divider,
    required this.gradientBrand,
    required this.gradientMarked,
    required this.gradientScrim,
    required this.glowLive,
    required this.glowMarked,
    required this.elevationRaised,
    required this.elevationSheet,
  });

  /// Dark (default) instance — spec §2.1/§2.5 dark column.
  const ProximityColors.dark()
      : surfaceBase = const Color(0xFF0B0D10),
        surfaceRaised = const Color(0xFF15181D),
        surfaceOverlay = const Color(0xFF1D2128),
        contentPrimary = const Color(0xFFF2F3F5),
        contentSecondary = const Color(0xFF9AA0AA),
        contentTertiary = const Color(0xFF5C626C),
        accentBrand = const Color(0xFF5B8CFF),
        statusMarked = const Color(0xFF33C77A),
        statusLate = const Color(0xFFE0B23A),
        statusReview = const Color(0xFFE0833A),
        statusError = const Color(0xFFE85D5D),
        divider = const Color(0x9922262D), // #22262D @ 60%
        gradientBrand = const LinearGradient(
          begin: _brandBegin,
          end: _brandEnd,
          colors: [Color(0xFF5B8CFF), Color(0xFF8F6BFF)],
        ),
        gradientMarked = const LinearGradient(
          begin: _markedBegin,
          end: _markedEnd,
          colors: [Color(0xFF33C77A), Color(0xFF2FE0A0)],
        ),
        // Scrim stays near-black on BOTH themes (§2.5 light column reuses
        // the ink ramp so backdrops dim identically for legibility).
        gradientScrim = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x000B0D10), Color(0xB80B0D10)], // 0% → 72%
        ),
        glowLive = const ProxGlow(
          color: Color(0xFF5B8CFF),
          blurSigma: 24,
          opacity: 0.24,
        ),
        glowMarked = const ProxGlow(
          color: Color(0xFF33C77A),
          blurSigma: 32,
          opacity: 0.30,
        ),
        elevationRaised = const BoxShadow(
          offset: Offset(0, 1),
          blurRadius: 2,
          color: Color(0x66000000), // black 40%
        ),
        elevationSheet = const BoxShadow(
          offset: Offset(0, -2),
          blurRadius: 12,
          color: Color(0x80000000), // black 50%
        );

  /// Light instance — spec §2.1/§2.5 light column, same fields, parity.
  const ProximityColors.light()
      : surfaceBase = const Color(0xFFFAFAFA),
        surfaceRaised = const Color(0xFFFFFFFF),
        surfaceOverlay = const Color(0xFFF0F1F3),
        contentPrimary = const Color(0xFF14161A),
        contentSecondary = const Color(0xFF5B6270),
        contentTertiary = const Color(0xFF9AA0AA),
        accentBrand = const Color(0xFF3A63E0),
        statusMarked = const Color(0xFF1E9A5C),
        statusLate = const Color(0xFFB4870F),
        statusReview = const Color(0xFFC4661A),
        statusError = const Color(0xFFC43E3E),
        divider = const Color(0x14000000), // black @ 8%
        gradientBrand = const LinearGradient(
          begin: _brandBegin,
          end: _brandEnd,
          colors: [Color(0xFF3A63E0), Color(0xFF6A4FD9)],
        ),
        gradientMarked = const LinearGradient(
          begin: _markedBegin,
          end: _markedEnd,
          colors: [Color(0xFF1E9A5C), Color(0xFF22B87E)],
        ),
        gradientScrim = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x0014161A), Color(0x8C14161A)], // 0% → 55%
        ),
        glowLive = const ProxGlow(
          color: Color(0xFF3A63E0),
          blurSigma: 16,
          opacity: 0.14,
        ),
        glowMarked = const ProxGlow(
          color: Color(0xFF1E9A5C),
          blurSigma: 20,
          opacity: 0.18,
        ),
        elevationRaised = const BoxShadow(
          offset: Offset(0, 1),
          blurRadius: 2,
          color: Color(0x14000000), // black 8%
        ),
        elevationSheet = const BoxShadow(
          offset: Offset(0, -2),
          blurRadius: 12,
          color: Color(0x1A000000), // black 10%
        );

  /// Reads the extension. Both app themes register it (see app_theme.dart);
  /// the `!` fails fast if a test/sheet builds outside the app themes.
  static ProximityColors of(BuildContext context) =>
      Theme.of(context).extension<ProximityColors>()!;

  @override
  ProximityColors copyWith({
    Color? surfaceBase,
    Color? surfaceRaised,
    Color? surfaceOverlay,
    Color? contentPrimary,
    Color? contentSecondary,
    Color? contentTertiary,
    Color? accentBrand,
    Color? statusMarked,
    Color? statusLate,
    Color? statusReview,
    Color? statusError,
    Color? divider,
    LinearGradient? gradientBrand,
    LinearGradient? gradientMarked,
    LinearGradient? gradientScrim,
    ProxGlow? glowLive,
    ProxGlow? glowMarked,
    BoxShadow? elevationRaised,
    BoxShadow? elevationSheet,
  }) =>
      ProximityColors(
        surfaceBase: surfaceBase ?? this.surfaceBase,
        surfaceRaised: surfaceRaised ?? this.surfaceRaised,
        surfaceOverlay: surfaceOverlay ?? this.surfaceOverlay,
        contentPrimary: contentPrimary ?? this.contentPrimary,
        contentSecondary: contentSecondary ?? this.contentSecondary,
        contentTertiary: contentTertiary ?? this.contentTertiary,
        accentBrand: accentBrand ?? this.accentBrand,
        statusMarked: statusMarked ?? this.statusMarked,
        statusLate: statusLate ?? this.statusLate,
        statusReview: statusReview ?? this.statusReview,
        statusError: statusError ?? this.statusError,
        divider: divider ?? this.divider,
        gradientBrand: gradientBrand ?? this.gradientBrand,
        gradientMarked: gradientMarked ?? this.gradientMarked,
        gradientScrim: gradientScrim ?? this.gradientScrim,
        glowLive: glowLive ?? this.glowLive,
        glowMarked: glowMarked ?? this.glowMarked,
        elevationRaised: elevationRaised ?? this.elevationRaised,
        elevationSheet: elevationSheet ?? this.elevationSheet,
      );

  static LinearGradient _lerpGradient(
          LinearGradient a, LinearGradient b, double t) =>
      LinearGradient.lerp(a, b, t) ?? (t < 0.5 ? a : b);

  @override
  ProximityColors lerp(
      covariant ThemeExtension<ProximityColors>? other, double t) {
    if (other is! ProximityColors) return this;
    return ProximityColors(
      surfaceBase: Color.lerp(surfaceBase, other.surfaceBase, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceOverlay: Color.lerp(surfaceOverlay, other.surfaceOverlay, t)!,
      contentPrimary: Color.lerp(contentPrimary, other.contentPrimary, t)!,
      contentSecondary:
          Color.lerp(contentSecondary, other.contentSecondary, t)!,
      contentTertiary: Color.lerp(contentTertiary, other.contentTertiary, t)!,
      accentBrand: Color.lerp(accentBrand, other.accentBrand, t)!,
      statusMarked: Color.lerp(statusMarked, other.statusMarked, t)!,
      statusLate: Color.lerp(statusLate, other.statusLate, t)!,
      statusReview: Color.lerp(statusReview, other.statusReview, t)!,
      statusError: Color.lerp(statusError, other.statusError, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      gradientBrand: _lerpGradient(gradientBrand, other.gradientBrand, t),
      gradientMarked: _lerpGradient(gradientMarked, other.gradientMarked, t),
      gradientScrim: _lerpGradient(gradientScrim, other.gradientScrim, t),
      glowLive: ProxGlow.lerp(glowLive, other.glowLive, t),
      glowMarked: ProxGlow.lerp(glowMarked, other.glowMarked, t),
      elevationRaised:
          BoxShadow.lerp(elevationRaised, other.elevationRaised, t)!,
      elevationSheet: BoxShadow.lerp(elevationSheet, other.elevationSheet, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProximityColors &&
      other.surfaceBase == surfaceBase &&
      other.surfaceRaised == surfaceRaised &&
      other.surfaceOverlay == surfaceOverlay &&
      other.contentPrimary == contentPrimary &&
      other.contentSecondary == contentSecondary &&
      other.contentTertiary == contentTertiary &&
      other.accentBrand == accentBrand &&
      other.statusMarked == statusMarked &&
      other.statusLate == statusLate &&
      other.statusReview == statusReview &&
      other.statusError == statusError &&
      other.divider == divider &&
      other.gradientBrand == gradientBrand &&
      other.gradientMarked == gradientMarked &&
      other.gradientScrim == gradientScrim &&
      other.glowLive == glowLive &&
      other.glowMarked == glowMarked &&
      other.elevationRaised == elevationRaised &&
      other.elevationSheet == elevationSheet;

  @override
  int get hashCode => Object.hash(
        surfaceBase,
        surfaceRaised,
        surfaceOverlay,
        contentPrimary,
        contentSecondary,
        contentTertiary,
        accentBrand,
        statusMarked,
        statusLate,
        statusReview,
        statusError,
        divider,
        gradientBrand,
        gradientMarked,
        gradientScrim,
        glowLive,
        glowMarked,
        elevationRaised,
        elevationSheet,
      );
}

/// Frozen verdict vocabulary for status display (redesign §4.2 — rendering
/// standardization only, never new states): `Marked / Late / Wrong org /
/// No signal / Needs review / Waiting / Pending`. Distinct from [ProxState]
/// (legacy flow-phase enum): [ProxStatus] is the exhaustive badge set.
enum ProxStatus {
  marked,
  late,
  wrongOrg,
  noSignal,
  review,
  waiting,
  pending,
}

/// Iconography, redesign §2.4: ONE icon set (Material outlined by default,
/// filled on active/selected — never mixed families; this repo uses zero
/// `CupertinoIcons`/custom `IconData`, verified by grep — keep it that
/// way). Status is ALWAYS color + shape + text, never color alone: callers
/// pair [statusIcon] + [statusColor] with the verdict word (the shared
/// `VerdictBadge` composes all three; this helper is the shape source).
///
/// Shape map (§4.2): Marked = check, Late = clock, Wrong org = triangle,
/// No signal = slash (wifi-off), Needs review = flag, Waiting = dot,
/// Pending = dot-pulsing (same dot icon; the caller animates the pulse
/// only while actually pending).
abstract final class ProxIcons {
  static IconData statusIcon(ProxStatus status, {bool active = false}) =>
      switch (status) {
        ProxStatus.marked =>
          active ? Icons.check_circle : Icons.check_circle_outline,
        ProxStatus.late => active ? Icons.schedule : Icons.schedule_outlined,
        ProxStatus.wrongOrg =>
          active ? Icons.warning_amber : Icons.warning_amber_outlined,
        ProxStatus.noSignal =>
          active ? Icons.wifi_off : Icons.wifi_off_outlined,
        ProxStatus.review => active ? Icons.flag : Icons.flag_outlined,
        ProxStatus.waiting ||
        ProxStatus.pending =>
          active ? Icons.circle : Icons.circle_outlined,
      };

  /// Status color from the ambient [ProximityColors] (never a raw hex).
  /// Waiting reads `contentSecondary`; Pending reads `statusReview`
  /// (dot-pulsing, §4.2) — not the same token, do not merge them.
  static Color statusColor(BuildContext context, ProxStatus status) {
    final c = ProximityColors.of(context);
    return switch (status) {
      ProxStatus.marked => c.statusMarked,
      ProxStatus.late => c.statusLate,
      ProxStatus.review || ProxStatus.pending => c.statusReview,
      ProxStatus.wrongOrg || ProxStatus.noSignal => c.statusError,
      ProxStatus.waiting => c.contentSecondary,
    };
  }
}
