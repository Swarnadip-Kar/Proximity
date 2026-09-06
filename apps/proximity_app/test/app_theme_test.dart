// Regression guard for the dark-mode invisible-text bug: GoogleFonts
// text themes built without a base default to LIGHT colors, baking
// near-black text into every style (invisible on dark surfaces).
// The app themes must derive fonts from a scheme-based base so body and
// heading text are light-on-dark in the dark theme and dark-on-light in
// the light theme.
//
// Note: these run as widget tests (not plain unit tests) so font fetching
// behaves exactly as in the rest of the suite, where ProximityApp already
// builds both themes on every pump.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';

TextStyle _styleOf(TextTheme t, String name) => switch (name) {
      'body' => t.bodyMedium!,
      'title' => t.titleMedium!,
      'headline' => t.headlineMedium!,
      'display' => t.displaySmall!,
      'label' => t.labelLarge!,
      _ => t.bodyMedium!,
    };

void main() {
  testWidgets('dark theme text reads light-on-dark', (_) async {
    final text = proxDarkTheme().textTheme;
    for (final name in ['body', 'title', 'headline', 'display', 'label']) {
      final color = _styleOf(text, name).color;
      expect(color, isNotNull, reason: '$name has no color');
      expect(
        ThemeData.estimateBrightnessForColor(color!),
        Brightness.light,
        reason: '$name ($color) is dark text on a dark theme',
      );
    }
  });

  testWidgets('light theme text reads dark-on-light', (_) async {
    final text = proxLightTheme().textTheme;
    for (final name in ['body', 'title', 'headline', 'display', 'label']) {
      final color = _styleOf(text, name).color;
      expect(color, isNotNull, reason: '$name has no color');
      expect(
        ThemeData.estimateBrightnessForColor(color!),
        Brightness.dark,
        reason: '$name ($color) is light text on a light theme',
      );
    }
  });
}
