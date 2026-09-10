// Proximity app theme — visual identity in one place.
//
// Font pairing (google_fonts, pure Dart — safe on every build target):
//   display → "Space Grotesk" (headings, hero numbers, verdict titles)
//   body    → "Inter" (everything else: labels, captions, lists)
// Shape: 14dp cards, 12dp buttons, pill chips. Elevation is deliberately
// flat (border + 0-1dp) so live screens with BLE + camera stay cheap to
// composite — no blur/shadow parties on the scan path.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// Light theme for the Proximity app.
ThemeData proxLightTheme() {
  const seed = ProxPalette.primaryLight;
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.light,
    primary: seed,
    secondary: ProxPalette.liveLight,
    surface: ProxPalette.paperLight,
  );
  return _build(scheme, Brightness.light);
}

/// Dark theme for the Proximity app.
ThemeData proxDarkTheme() {
  const seed = ProxPalette.primaryDark;
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.dark,
    primary: seed,
    secondary: ProxPalette.liveDark,
    surface: ProxPalette.inkDark,
  );
  return _build(scheme, Brightness.dark);
}

ThemeData _build(ColorScheme scheme, Brightness brightness) {
  // Offline-first: fonts are bundled (pubspec `fonts:`) and runtime
  // fetching is OFF — the live flow must never wait on fonts.gstatic.com.
  // google_fonts then resolves the pubspec families above, same API.
  GoogleFonts.config.allowRuntimeFetching = false;
  // Font pairing on a SCHEME-DERIVED base: GoogleFonts.textTheme() with no
  // argument falls back to the *light* text theme, baking near-black text
  // into every style — which renders invisible on dark surfaces (caught on
  // Android dark mode). Deriving from the scheme keeps font families while
  // preserving brightness-correct colors.
  final base =
      ThemeData(colorScheme: scheme, brightness: brightness, useMaterial3: true)
          .textTheme;
  final display = GoogleFonts.spaceGroteskTextTheme(base);
  final body = GoogleFonts.interTextTheme(base);
  final text = body.copyWith(
    displayLarge: display.displayLarge?.copyWith(fontWeight: FontWeight.w700),
    displayMedium: display.displayMedium?.copyWith(fontWeight: FontWeight.w700),
    displaySmall: display.displaySmall?.copyWith(fontWeight: FontWeight.w700),
    headlineLarge: display.headlineLarge?.copyWith(fontWeight: FontWeight.w700),
    headlineMedium:
        display.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
    headlineSmall: display.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
    titleLarge: display.titleLarge?.copyWith(fontWeight: FontWeight.w600),
    titleMedium: display.titleMedium?.copyWith(fontWeight: FontWeight.w600),
  );

  return ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    useMaterial3: true,
    // Foundation rebuild (redesign §2.1/§2.5): semantic + gradient/glow/
    // elevation tokens, dark/light at parity. New components read
    // `ProximityColors.of(context)`; legacy scheme/scaffold/card defaults
    // below are FROZEN until each rebuild section migrates (see
    extensions: <ThemeExtension<dynamic>>[
      brightness == Brightness.dark
          ? const ProximityColors.dark()
          : const ProximityColors.light(),
    ],
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: ProxRadii.cardSpecRadius,
        side: BorderSide(
          // Dark: subtle inner-glow feel via lighter border on darker fill.
          // Light: hairline at reduced opacity for a clean, airy feel.
          color: brightness == Brightness.dark
              ? const Color(0x14FFFFFF) // white 8% — inner glow
              : scheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      // Dark-mode rule (Material + Apple HIG alignment): cards sit ABOVE
      // the background. M3's surfaceContainerLowest is the darkest stop —
      // correct on light (near-white card on paper) but inverted on dark,
      // where cards must be lighter than the page to read as elevated.
      color: brightness == Brightness.dark
          ? scheme.surfaceContainerLow
          : scheme.surfaceContainerLowest,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: ProxRadii.buttonRadius,
        ),
        // §9: every interactive target is ≥48×48dp. The theme carries the
        // floor so dialog actions, sheet buttons, and rows all comply
        // without per-site minimumSize copies (MARK-D5 keeps buttons
        // Material theme-driven — this is that theme).
        minimumSize: const Size(64, ProxSpacing.minTap),
        padding: const EdgeInsets.symmetric(
          horizontal: ProxSpacing.xl,
          vertical: ProxSpacing.md,
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: ProxRadii.buttonRadius,
        ),
        // §9 48dp floor (see filledButtonTheme above).
        minimumSize: const Size(64, ProxSpacing.minTap),
        padding: const EdgeInsets.symmetric(
          horizontal: ProxSpacing.xl,
          vertical: ProxSpacing.md,
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: ProxRadii.buttonRadius,
        ),
        // §9 48dp floor (see filledButtonTheme above). Material's own
        // default is shorter — without this, dialog/sheet text actions
        // would be the one sub-48 target class left in the app.
        minimumSize: const Size(64, ProxSpacing.minTap),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        // §9 48dp floor, explicit: framework IconButtons already target
        // 48×48; this pins the guarantee against future default drift.
        minimumSize: const Size(ProxSpacing.minTap, ProxSpacing.minTap),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: brightness == Brightness.dark
          ? const Color(0xFF15181D)
          : const Color(0xFFF5F6FA),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ProxRadii.card),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ProxRadii.card),
        borderSide: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ProxRadii.card),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: ProxSpacing.lg,
        vertical: ProxSpacing.md,
      ),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      labelStyle: text.labelLarge,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      linearTrackColor: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(ProxRadii.chip),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.35),
      thickness: 0.5,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ProxRadii.card),
      ),
      elevation: 0,
      backgroundColor: brightness == Brightness.dark
          ? const Color(0xFF1D2128)
          : const Color(0xFF14161A),
      contentTextStyle: text.bodyMedium?.copyWith(
        color: const Color(0xFFF2F3F5),
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ProxRadii.sheet),
      ),
      elevation: 0,
      backgroundColor: brightness == Brightness.dark
          ? const Color(0xFF15181D)
          : const Color(0xFFFFFFFF),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(ProxRadii.sheet),
        ),
      ),
      elevation: 0,
      backgroundColor: brightness == Brightness.dark
          ? const Color(0xFF15181D)
          : const Color(0xFFFFFFFF),
      dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.3),
      showDragHandle: true,
    ),
    iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 20),
  );
}

/// Tabular figures for live numeric readouts (elapsed clocks, present
/// counters). Monospaced digits stop the layout jittering every tick —
/// the same reason transit and sports apps set tnum on their timers.
TextStyle? proxTabular(BuildContext context, TextStyle? style) =>
    (style ?? Theme.of(context).textTheme.bodyMedium)?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
