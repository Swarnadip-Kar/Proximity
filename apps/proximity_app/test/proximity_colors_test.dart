// Foundation token contract (redesign §2.1/§2.5/§9): the exact API every
// downstream rebuild section consumes. Fails if a token value drifts from
// the spec table or if either app theme stops registering the extension.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';

void main() {
  test('semantic tokens match the §2.1 table', () {
    const dark = ProximityColors.dark();
    expect(dark.surfaceBase, const Color(0xFF0B0D10));
    expect(dark.surfaceRaised, const Color(0xFF15181D));
    expect(dark.surfaceOverlay, const Color(0xFF1D2128));
    expect(dark.contentPrimary, const Color(0xFFF2F3F5));
    expect(dark.contentSecondary, const Color(0xFF9AA0AA));
    expect(dark.contentTertiary, const Color(0xFF5C626C));
    expect(dark.accentBrand, const Color(0xFF5B8CFF));
    expect(dark.statusMarked, const Color(0xFF33C77A));
    expect(dark.statusLate, const Color(0xFFE0B23A));
    expect(dark.statusReview, const Color(0xFFE0833A));
    expect(dark.statusError, const Color(0xFFE85D5D));

    const light = ProximityColors.light();
    expect(light.surfaceBase, const Color(0xFFFAFAFA));
    expect(light.surfaceRaised, const Color(0xFFFFFFFF));
    expect(light.surfaceOverlay, const Color(0xFFF0F1F3));
    expect(light.contentPrimary, const Color(0xFF14161A));
    expect(light.contentSecondary, const Color(0xFF5B6270));
    expect(light.contentTertiary, const Color(0xFF9AA0AA));
    expect(light.accentBrand, const Color(0xFF3A63E0));
    expect(light.statusMarked, const Color(0xFF1E9A5C));
    expect(light.statusLate, const Color(0xFFB4870F));
    expect(light.statusReview, const Color(0xFFC4661A));
    expect(light.statusError, const Color(0xFFC43E3E));
  });

  test('gradient/glow/elevation tokens match the §2.5 table', () {
    const dark = ProximityColors.dark();
    expect(
      dark.gradientBrand.colors,
      const [Color(0xFF5B8CFF), Color(0xFF8F6BFF)],
    );
    expect(
      dark.gradientMarked.colors,
      const [Color(0xFF33C77A), Color(0xFF2FE0A0)],
    );
    // Scrim: transparent → 72% dark (0xB8 = 184/255).
    expect(dark.gradientScrim.colors[1].a, moreOrLessEquals(0.72, epsilon: 0.01));
    expect(dark.glowLive.blurSigma, 24);
    expect(dark.glowLive.opacity, moreOrLessEquals(0.24));
    expect(dark.glowMarked.blurSigma, 32);
    expect(dark.glowMarked.opacity, moreOrLessEquals(0.30));
    expect(dark.elevationRaised.offset, const Offset(0, 1));
    expect(dark.elevationRaised.blurRadius, 2);
    expect(dark.elevationSheet.offset, const Offset(0, -2));
    expect(dark.elevationSheet.blurRadius, 12);

    const light = ProximityColors.light();
    expect(
      light.gradientBrand.colors,
      const [Color(0xFF3A63E0), Color(0xFF6A4FD9)],
    );
    expect(
      light.gradientMarked.colors,
      const [Color(0xFF1E9A5C), Color(0xFF22B87E)],
    );
    // Scrim: transparent → 55% ink (0x8C = 140/255).
    expect(light.gradientScrim.colors[1].a, moreOrLessEquals(0.55, epsilon: 0.01));
    expect(light.glowLive.blurSigma, 16);
    expect(light.glowLive.opacity, moreOrLessEquals(0.14));
    expect(light.glowMarked.blurSigma, 20);
    expect(light.glowMarked.opacity, moreOrLessEquals(0.18));
  });

  test('lerp/copyWith stay within the extension type', () {
    const dark = ProximityColors.dark();
    const light = ProximityColors.light();
    final mid = dark.lerp(light, 0.5);
    expect(mid.surfaceBase, Color.lerp(dark.surfaceBase, light.surfaceBase, 0.5));
    expect(mid.glowLive.blurSigma, moreOrLessEquals(20));
    expect(dark.copyWith(), dark);
    expect(dark.copyWith(accentBrand: light.accentBrand).accentBrand,
        light.accentBrand);
  });

  test('typography scale matches §2.2 sizes', () {
    expect(ProxType.displaySize, 28);
    expect(ProxType.titleSize, 20);
    expect(ProxType.bodySize, 15);
    expect(ProxType.labelSize, 13);
    expect(ProxType.captionSize, 11);
    // Single family, 3 weights only — no Bold 700 in new components.
    for (final s in [
      ProxType.display(),
      ProxType.title(),
      ProxType.body(),
      ProxType.label(),
      ProxType.caption(),
    ]) {
      expect(s.fontFamily, ProxType.family);
      expect(
        s.fontWeight,
        isIn([FontWeight.w400, FontWeight.w500, FontWeight.w600]),
      );
    }
  });

  test('status icons are outlined by default, filled on active', () {
    expect(ProxIcons.statusIcon(ProxStatus.marked),
        Icons.check_circle_outline);
    expect(ProxIcons.statusIcon(ProxStatus.marked, active: true),
        Icons.check_circle);
    // Color-plus-shape: every verdict maps to a distinct shape.
    final shapes = ProxStatus.values.map(ProxIcons.statusIcon).toSet();
    expect(shapes.length, ProxStatus.values.length - 1); // pending shares dot
  });

  testWidgets('both app themes register ProximityColors', (_) async {
    expect(proxLightTheme().extension<ProximityColors>(),
        const ProximityColors.light());
    expect(proxDarkTheme().extension<ProximityColors>(),
        const ProximityColors.dark());
  });

  testWidgets('ProximityColors.of resolves + status colors read tokens',
      (tester) async {
    Color? captured;
    IconData? icon;
    await tester.pumpWidget(
      MaterialApp(
        theme: proxLightTheme(),
        home: Builder(builder: (context) {
          captured = ProxIcons.statusColor(context, ProxStatus.marked);
          icon = ProxIcons.statusIcon(ProxStatus.wrongOrg);
          return const SizedBox();
        }),
      ),
    );
    expect(captured, const Color(0xFF1E9A5C));
    expect(icon, Icons.warning_amber_outlined);
  });
}
