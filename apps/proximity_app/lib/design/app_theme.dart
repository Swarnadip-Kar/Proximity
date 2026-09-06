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
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: ProxRadii.cardRadius,
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      color: scheme.surfaceContainerLowest,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: ProxRadii.buttonRadius,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: ProxSpacing.lg,
          vertical: ProxSpacing.md,
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: ProxRadii.buttonRadius,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: ProxSpacing.lg,
          vertical: ProxSpacing.md,
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: ProxRadii.buttonRadius,
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ProxRadii.md),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ProxRadii.md),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: ProxSpacing.md,
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
      color: scheme.outlineVariant.withValues(alpha: 0.5),
      thickness: 1,
    ),
    iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 20),
  );
}
