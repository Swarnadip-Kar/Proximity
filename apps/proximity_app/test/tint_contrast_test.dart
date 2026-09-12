// Task 3 (D3) — on-tint foreground contrast pins.
//
// Light `statusLate`/`statusReview` fail AA small-text on their tints, so
// text + meaningful icons route through the darkened `onTintLate`/
// `onTintReview` tokens while backgrounds stay on the spec-frozen hexes.
// This file pins: fixed hexes, ≥4.5:1 text contrast on the tints (both
// themes), ≥3:1 icon contrast, dark pixel-identity, theme-animation wiring
// (copyWith/lerp/==), and widget routing (badge/avatar/drift banner).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/mark/proving_view.dart';
import 'package:proximity_app/widgets/student_card.dart';
import 'package:proximity_app/widgets/verdict_badge.dart';

double _lin(int v) {
  final c = v / 255.0;
  return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4) as double;
}

double _luminance(Color c) =>
    0.2126 * _lin((c.r * 255.0).round()) +
    0.7152 * _lin((c.g * 255.0).round()) +
    0.0722 * _lin((c.b * 255.0).round());

double _ratio(Color a, Color b) {
  final l1 = _luminance(a);
  final l2 = _luminance(b);
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

/// Opaque composite of [fg] at [alpha] over opaque [bg].
Color _over(Color fg, double alpha, Color bg) => Color.fromARGB(
      0xFF,
      (fg.r * 255.0 * alpha + bg.r * 255.0 * (1 - alpha)).round(),
      (fg.g * 255.0 * alpha + bg.g * 255.0 * (1 - alpha)).round(),
      (fg.b * 255.0 * alpha + bg.b * 255.0 * (1 - alpha)).round(),
    );

Widget _app(Widget child, {required bool dark}) => MaterialApp(
      theme: dark ? proxDarkTheme() : proxLightTheme(),
      darkTheme: proxDarkTheme(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(body: child),
    );

/// Probe names covering all avatar slots (identity palette is verdict-free
/// by construction — no name can land on a verdict hue).
List<String> _avatarProbeNames() =>
    [for (var i = 0; i < 10; i++) 'avatar-probe-$i'];

void main() {
  const light = ProximityColors.light();
  const dark = ProximityColors.dark();

  group('on-tint token hexes (fixed)', () {
    test('spec backgrounds stay byte-identical', () {
      expect(light.statusLate, const Color(0xFFB4870F));
      expect(light.statusReview, const Color(0xFFC4661A));
      expect(dark.statusLate, const Color(0xFFE0B23A));
      expect(dark.statusReview, const Color(0xFFE0833A));
    });

    test('light on-tints are the fixed darkened hexes', () {
      expect(light.onTintLate, const Color(0xFF7A5A00));
      expect(light.onTintReview, const Color(0xFF8A3D00));
    });

    test('dark on-tints equal the dark status hexes (pixel-identical)', () {
      expect(dark.onTintLate, dark.statusLate);
      expect(dark.onTintReview, dark.statusReview);
    });
  });

  group('text contrast ≥4.5:1 on the tints', () {
    test('light late pair', () {
      // Badge fill: statusLate @12% over the light raised surface (white).
      final tint = _over(light.statusLate, 0.12, light.surfaceRaised);
      expect(_ratio(light.onTintLate, tint), greaterThanOrEqualTo(4.5));
      // Avatar fill variant (@15%) carries initials text too.
      final avatarTint = _over(light.statusLate, 0.15, light.surfaceRaised);
      expect(_ratio(light.onTintLate, avatarTint), greaterThanOrEqualTo(4.5));
    });

    test('light review pair', () {
      final tint = _over(light.statusReview, 0.12, light.surfaceRaised);
      expect(_ratio(light.onTintReview, tint), greaterThanOrEqualTo(4.5));
      final avatarTint = _over(light.statusReview, 0.15, light.surfaceRaised);
      expect(_ratio(light.onTintReview, avatarTint), greaterThanOrEqualTo(4.5));
    });

    test('dark pairs (pixel-identical foregrounds still pass)', () {
      final lateTint = _over(dark.statusLate, 0.12, dark.surfaceRaised);
      expect(_ratio(dark.onTintLate, lateTint), greaterThanOrEqualTo(4.5));
      final reviewTint = _over(dark.statusReview, 0.12, dark.surfaceRaised);
      expect(_ratio(dark.onTintReview, reviewTint), greaterThanOrEqualTo(4.5));
    });
  });

  group('icon contrast ≥3:1', () {
    test('light on-tints as bare icons on light surfaces', () {
      expect(_ratio(light.onTintLate, light.surfaceRaised),
          greaterThanOrEqualTo(3.0));
      expect(_ratio(light.onTintReview, light.surfaceRaised),
          greaterThanOrEqualTo(3.0));
      // And on their own tints (badge/drift-banner icon beds).
      expect(
          _ratio(light.onTintLate,
              _over(light.statusLate, 0.12, light.surfaceRaised)),
          greaterThanOrEqualTo(3.0));
      expect(
          _ratio(light.onTintReview,
              _over(light.statusReview, 0.12, light.surfaceRaised)),
          greaterThanOrEqualTo(3.0));
    });

    test('dark on-tints as icons', () {
      expect(_ratio(dark.onTintLate, dark.surfaceRaised),
          greaterThanOrEqualTo(3.0));
      expect(_ratio(dark.onTintReview, dark.surfaceRaised),
          greaterThanOrEqualTo(3.0));
    });
  });

  group('theme-animation wiring', () {
    test('copyWith defaults to identity and overrides each field', () {
      expect(light.copyWith(), light);
      expect(light.copyWith(onTintLate: dark.onTintLate).onTintLate,
          dark.onTintLate);
      expect(light.copyWith(onTintReview: dark.onTintReview).onTintReview,
          dark.onTintReview);
    });

    test('lerp blends both fields', () {
      final mid = dark.lerp(light, 0.5);
      expect(mid.onTintLate,
          Color.lerp(dark.onTintLate, light.onTintLate, 0.5));
      expect(mid.onTintReview,
          Color.lerp(dark.onTintReview, light.onTintReview, 0.5));
    });

    test('== distinguishes the new fields', () {
      expect(light == light.copyWith(), isTrue);
      expect(light == light.copyWith(onTintLate: dark.onTintLate), isFalse);
      expect(light == light.copyWith(onTintReview: dark.onTintReview), isFalse);
    });
  });

  group('widget routing', () {
    testWidgets('VerdictBadge late/review/pending text+icon use on-tint',
        (tester) async {
      for (final status in [
        ProxStatus.late,
        ProxStatus.review,
        ProxStatus.pending,
      ]) {
        await tester.pumpWidget(_app(VerdictBadge(status: status), dark: false));
        await tester.pump();
        final expected = status == ProxStatus.late
            ? light.onTintLate
            : light.onTintReview;
        final text = tester.widget<Text>(find.text(
            VerdictBadge.labelFor(status)));
        expect(text.style?.color, expected);
        final icon = tester.widget<Icon>(find.byType(Icon).first);
        expect(icon.color, expected);
      }
    });

    testWidgets('VerdictBadge dark late/review stay pixel-identical',
        (tester) async {
      await tester.pumpWidget(
          _app(const VerdictBadge(status: ProxStatus.late), dark: true));
      await tester.pump();
      expect(tester.widget<Text>(find.text('Late')).style?.color,
          dark.statusLate);
      expect(tester.widget<Icon>(find.byType(Icon).first).color,
          dark.statusLate);

      await tester.pumpWidget(
          _app(const VerdictBadge(status: ProxStatus.review), dark: true));
      await tester.pump();
      expect(tester.widget<Text>(find.text('Needs review')).style?.color,
          dark.statusReview);
    });

    testWidgets('VerdictBadge backgrounds keep the spec status color',
        (tester) async {
      await tester.pumpWidget(
          _app(const VerdictBadge(status: ProxStatus.late), dark: false));
      await tester.pump();
      final container =
          tester.widget<Container>(find.byType(Container).first);
      final bg = (container.decoration! as BoxDecoration).color!;
      expect(
          bg,
          light.statusLate.withValues(alpha: 0.12),
          reason: 'badge fill must stay on the frozen status hex');
    });

    test('avatars avoid verdict hues; foreground equals base', () {
      // Identity palette split: avatars never use Marked/Late/Review/Error,
      // so the on-tint remap path for avatars is dead — foreground is base
      // on both themes. On-tints remain pinned for badges/banners elsewhere.
      final verdictLight = {
        light.statusMarked,
        light.statusLate,
        light.statusReview,
        light.statusError,
      };
      final verdictDark = {
        dark.statusMarked,
        dark.statusLate,
        dark.statusReview,
        dark.statusError,
      };
      for (final name in _avatarProbeNames()) {
        final aLight = studentAvatarColor(light, name);
        final aDark = studentAvatarColor(dark, name);
        expect(verdictLight, isNot(contains(aLight)));
        expect(verdictDark, isNot(contains(aDark)));
        expect(studentAvatarForeground(light, name), aLight);
        expect(studentAvatarForeground(dark, name), aDark);
      }
    });

    testWidgets('drift banner icon uses onTintLate', (tester) async {
      await tester.pumpWidget(_app(
          const ProvingView(
            status: 'Signal heard — proving…',
            driftBanner: 'Clock drift ~7s vs professor.',
          ),
          dark: false));
      await tester.pump();
      final icon = tester.widget<Icon>(find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Icons.schedule_outlined));
      expect(icon.color, light.onTintLate);
    });
  });
}
