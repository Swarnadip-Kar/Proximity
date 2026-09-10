// Responsive/accessibility pass tests (§9 + §10 + §10.1).
//
// Presentation-only proofs for the final cross-cutting pass:
// - §10.1 overflow rules: long-name ellipsis, 130% system type without
//   RenderFlex stripes (StudentCard, proving steps, marked verdict),
//   keyboard-safe fallback sheet (viewInsets-padded + scrollable).
// - §9: one-time hold-to-select coach-mark (persisted once per list-type
//   per install), status badges always icon+color+text, all pumped targets
//   ≥48×48, celebratory wash renders dark-ink content while visible.
// - Contrast notes: measured WCAG ratios computed from the token consts
//   for every gradient/glow surface (see INTEGRATION_LOG.md for the table).
//
// No frozen string, timing, threshold, or network contract is asserted
// beyond what the specs freeze — rendering + interaction only.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/live/live_session.dart';
import 'package:proximity_app/features/mark/proving_view.dart';
import 'package:proximity_app/features/mark/verdict_view.dart';
import 'package:proximity_app/widgets/fallback_button.dart';
import 'package:proximity_app/widgets/selection_controller.dart';
import 'package:proximity_app/widgets/selection_toolbar.dart';
import 'package:proximity_app/widgets/student_card.dart';
import 'package:proximity_app/widgets/verdict_badge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Themed host. [textScale] applies 130%-style dynamic type through the
/// app builder (the same MediaQuery every screen reads).
Widget _app(
  Widget child, {
  ThemeData? theme,
  double textScale = 1.0,
}) =>
    MaterialApp(
      theme: theme ?? proxLightTheme(),
      builder: (context, c) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: c!,
      ),
      home: Scaffold(body: child),
    );

/// Narrow phone surface for the <360dp breakpoint rules.
void _narrowSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(350, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

double _lin(int v) {
  final x = v / 255.0;
  if (x <= 0.03928) return x / 12.92;
  return math.pow((x + 0.055) / 1.055, 2.4).toDouble();
}

double _lum(Color c) =>
    0.2126 * _lin(c.r * 255 ~/ 1) +
    0.7152 * _lin(c.g * 255 ~/ 1) +
    0.0722 * _lin(c.b * 255 ~/ 1);

double _contrast(Color a, Color b) {
  final la = _lum(a);
  final lb = _lum(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Color _mix(Color fg, Color bg, double alpha) => Color.fromARGB(
      255,
      ((fg.r * alpha + bg.r * (1 - alpha)) * 255).round(),
      ((fg.g * alpha + bg.g * (1 - alpha)) * 255).round(),
      ((fg.b * alpha + bg.b * (1 - alpha)) * 255).round(),
    );

void main() {
  // --- ProxLayout breakpoints (§10) -------------------------------------

  testWidgets('ProxLayout narrow/wide thresholds match the spec widths',
      (tester) async {
    bool? narrow;
    bool? wide;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(359, 700)),
        child: Builder(builder: (context) {
          narrow = ProxLayout.isNarrow(context);
          wide = ProxLayout.isWide(context);
          return const SizedBox.shrink();
        }),
      ),
    );
    expect(narrow, isTrue);
    expect(wide, isFalse);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(600, 900)),
        child: Builder(builder: (context) {
          narrow = ProxLayout.isNarrow(context);
          wide = ProxLayout.isWide(context);
          return const SizedBox.shrink();
        }),
      ),
    );
    expect(narrow, isFalse);
    expect(wide, isTrue);
  });

  testWidgets('StudentCard padding drops 16 to 12 below 360dp', (tester) async {
    _narrowSurface(tester);
    await tester.pumpWidget(_app(const StudentCard(name: 'Ada Lovelace')));
    await tester.pumpAndSettle();
    final narrowCards = tester.widgetList<Container>(
      find.byWidgetPredicate((w) =>
          w is Container && w.padding == const EdgeInsets.all(ProxSpacing.md)),
    );
    expect(narrowCards, isNotEmpty);
  });

  // --- §10.1 overflow proofs --------------------------------------------

  testWidgets('StudentCard truncates long names at 130% without overflow',
      (tester) async {
    _narrowSurface(tester);
    const longName =
        'Alexandria Constantine Worthington-Smythe the Third Esquire Junior';
    await tester.pumpWidget(_app(
      const StudentCard(
        name: longName,
        subtitle: '99999999 · a.very.long.email.address@university.example.edu',
        status: VerdictBadge(status: ProxStatus.marked),
        roundTrail: [
          RoundTick('R1', present: true),
          RoundTick('R2', present: false),
        ],
      ),
      textScale: 1.3,
    ));
    await tester.pumpAndSettle();
    // Ellipsis is wired (not a bare Text next to the badge/avatar).
    final nameText = tester.widget<Text>(find.text(longName));
    expect(nameText.overflow, TextOverflow.ellipsis);
    expect(nameText.maxLines, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Proving steps fit a narrow screen at 130% type', (tester) async {
    _narrowSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        child: _app(
          const ProvingView(
            status: 'Signal heard — proving…',
            driftBanner: 'Clock drift ~7s vs professor — marks may read late.',
          ),
          textScale: 1.3,
        ),
      ),
    );
    // No pumpAndSettle: the proving 1s tick timer never settles by design.
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Confirmed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Marked verdict with trail survives 130% type', (tester) async {
    await tester.pumpWidget(_app(
      MarkVerdictView(
        kind: MarkVerdict.marked,
        detail: '',
        roundMarks: const ['R1 · KQ7 · 10:04:12'],
        onRetryFace: () {},
        onManualInstead: () {},
        onBack: () {},
      ),
      textScale: 1.3,
    ));
    await tester.pumpAndSettle();
    expect(find.text('✓ Marked'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Fallback sheet is keyboard-safe (viewInsets + scroll)',
      (tester) async {
    // Logical-pixel inset (the fake view reports physical pixels, so pin
    // DPR to 1:1 for an exact assertion).
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });
    await tester.pumpWidget(_app(
      Builder(builder: (context) {
        return Center(
          child: FallbackButton(
            label: 'Enter IP manually',
            sheetTitle: 'Enter IP manually',
            sheetBuilder: (_) => const TextField(
              decoration: InputDecoration(labelText: 'Professor IP'),
            ),
          ),
        );
      }),
    ));
    await tester.tap(find.text('Enter IP manually'));
    await tester.pumpAndSettle();
    // The sheet wraps content in a scroll view (never a fixed-height clip)
    // and pads the keyboard inset at the bottom.
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(find.byType(TextField), findsOneWidget);
    final insetPads = tester.widgetList<Padding>(
      find.byWidgetPredicate((w) =>
          w is Padding &&
          w.padding is EdgeInsets &&
          (w.padding as EdgeInsets).bottom == 400),
    );
    expect(insetPads, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  // --- §9: coach-mark (IMPLEMENT — once per list-type per install) ------

  test('coach-mark prefs keys are versioned per list-type', () {
    expect(SelectionCoachMarks.prefsKey(SelectionCoachMarks.inbox),
        'prox.coachMark.inbox.v1');
    expect(SelectionCoachMarks.prefsKey(SelectionCoachMarks.sessions),
        'prox.coachMark.sessions.v1');
    expect(
      SelectionCoachMarks.prefsKey(SelectionCoachMarks.inbox),
      isNot(SelectionCoachMarks.prefsKey(SelectionCoachMarks.sessions)),
    );
  });

  testWidgets('coach-mark shows once, dismiss persists, per list-type',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    Future<void> pumpMark({required String type}) async {
      await tester.pumpWidget(_app(SelectionCoachMark(
        listType: type,
        selecting: false,
      )));
      await tester.pumpAndSettle();
    }

    // First launch: the hint shows (icon + the verbatim words).
    await pumpMark(type: SelectionCoachMarks.inbox);
    expect(find.text('Hold to select'), findsOneWidget);
    expect(find.byIcon(Icons.touch_app_outlined), findsOneWidget);

    // Dismiss persists the flag.
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('Hold to select'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(SelectionCoachMarks.prefsKey(SelectionCoachMarks.inbox)),
      isTrue,
    );

    // Next launch (new instance, same install): stays hidden.
    await pumpMark(type: SelectionCoachMarks.inbox);
    expect(find.text('Hold to select'), findsNothing);

    // Other list-types are independent (per-list-type, not global).
    await pumpMark(type: SelectionCoachMarks.sessions);
    expect(find.text('Hold to select'), findsOneWidget);
  });

  testWidgets('coach-mark hides while the list is selecting', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app(const SelectionCoachMark(
      listType: SelectionCoachMarks.inbox,
      selecting: true,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Hold to select'), findsNothing);
  });

  // --- §9: status always icon+color+text ---------------------------------

  testWidgets('every VerdictBadge renders icon + word', (tester) async {
    for (final status in ProxStatus.values) {
      await tester.pumpWidget(_app(VerdictBadge(status: status)));
      await tester.pumpAndSettle();
      expect(find.byType(Icon), findsOneWidget, reason: 'no icon for $status');
      expect(find.text(VerdictBadge.labelFor(status)), findsOneWidget,
          reason: 'no word for $status');
    }
  });

  // --- §9: all targets ≥48×48 -------------------------------------------

  testWidgets('theme buttons and icon buttons clear 48x48', (tester) async {
    await tester.pumpWidget(_app(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(onPressed: () {}, child: const Text('Cancel')),
          FilledButton(onPressed: () {}, child: const Text('Join class')),
          OutlinedButton(onPressed: () {}, child: const Text('Go back')),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove',
            onPressed: () {},
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.widgetWithText(TextButton, 'Cancel')).height,
        greaterThanOrEqualTo(48));
    expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Join class')).height,
        greaterThanOrEqualTo(48));
    expect(
        tester.getSize(find.widgetWithText(OutlinedButton, 'Go back')).height,
        greaterThanOrEqualTo(48));
    final iconSize = tester.getSize(find.byType(IconButton));
    expect(iconSize.width, greaterThanOrEqualTo(48));
    expect(iconSize.height, greaterThanOrEqualTo(48));
  });

  testWidgets('StudentCard hold target spans the 48dp-tall card',
      (tester) async {
    var tapped = false;
    var selected = false;
    await tester.pumpWidget(_app(StudentCard(
      name: 'Student One',
      onTap: () => tapped = true,
      onSelectionChanged: (v) => selected = v,
    )));
    await tester.pumpAndSettle();
    final size = tester.getSize(find.byType(StudentCard));
    expect(size.height, greaterThanOrEqualTo(48));
    // Long-press enters selection (the larger invisible hit region is the
    // whole card — no small-handle timing trap).
    await tester.longPress(find.byType(StudentCard));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
    expect(tapped, isFalse);
  });

  // --- §9: celebratory wash contrast ------------------------------------

  testWidgets('marked wash uses dark ink while visible, releases after',
      (tester) async {
    await tester.pumpWidget(_app(
      MarkVerdictView(
        kind: MarkVerdict.marked,
        detail: '',
        roundMarks: const ['R1 · KQ7'],
        onRetryFace: () {},
        onManualInstead: () {},
        onBack: () {},
      ),
    ));
    await tester.pump();
    // Wash up: badge word renders in the documented dark ink (#14161A —
    // 8.27:1 on the wash's darkest stop), never status-green on green.
    final washed = tester.widget<Text>(find.text('✓ Marked'));
    expect(washed.style?.color, const Color(0xFF14161A));
    // Wash lifts after the 400ms beat: normal token colors return.
    await tester.pump(const Duration(milliseconds: 500));
    final released = tester.widget<Text>(find.text('✓ Marked'));
    expect(released.style?.color, const ProximityColors.light().statusMarked);
  });

  testWidgets('LIVE header keeps the token gradient at 20% over raised',
      (tester) async {
    await tester.pumpWidget(_app(LiveSessionHeader(
      live: true,
      elapsed: const Duration(minutes: 4, seconds: 12),
      present: 3,
      waiting: 5,
      windowsTaken: 1,
      windowNo: 1,
      hosting: true,
      hostLine: 'https://192.168.1.2:8443 · Code KQ7',
      onStart: () {},
      onRetake: () {},
      onTakeAnother: () {},
      onStop: () {},
      onEnd: () {},
    )));
    await tester.pumpAndSettle();
    final headers = tester.widgetList<AnimatedContainer>(
      find.byWidgetPredicate((w) {
        if (w is! AnimatedContainer) return false;
        final d = w.decoration;
        return d is BoxDecoration && d.gradient is LinearGradient;
      }),
    );
    expect(headers, isNotEmpty);
    final gradient =
        (headers.first.decoration as BoxDecoration).gradient as LinearGradient;
    final token = const ProximityColors.light().gradientBrand;
    expect(gradient.begin, token.begin);
    expect(gradient.end, token.end);
    // 20% alpha stops (measured: all header content ≥4.5:1, ring ≥3:1).
    for (final stop in gradient.colors) {
      expect(stop.a, closeTo(0.2, 0.01));
    }
  });

  // --- Contrast table, measured from the token consts --------------------
  // Documents the per-surface §9 check (darkest stop governs). Thresholds:
  // body/label text ≥4.5:1, non-text UI (rings) ≥3:1.

  test('contrast: gradient/glow surfaces against their darkest stop', () {
    const dark = ProximityColors.dark();
    const light = ProximityColors.light();
    const ink = Color(0xFF14161A);

    // Account-header brand wash (0.14 opacity over surfaceBase): primary
    // copy passes body text in both themes.
    final acctDark =
        _mix(dark.gradientBrand.colors.first, dark.surfaceBase, 0.14);
    final acctLight =
        _mix(light.gradientBrand.colors.first, light.surfaceBase, 0.14);
    expect(_contrast(dark.contentPrimary, acctDark), greaterThanOrEqualTo(4.5));
    expect(
        _contrast(light.contentPrimary, acctLight), greaterThanOrEqualTo(4.5));

    // Marked wash, dark-ink content (the implemented prescription).
    expect(_contrast(ink, const Color(0xFF33C77A)), greaterThanOrEqualTo(4.5));
    expect(_contrast(ink, const Color(0xFF1E9A5C)), greaterThanOrEqualTo(4.5));

    // LIVE header, 20%-alpha token wash over surfaceRaised: clock/label
    // ink, outlined-button labels, and the LIVE ring all pass.
    final liveDark = _mix(const Color(0xFF5B8CFF), dark.surfaceRaised, 0.2);
    final liveLight = _mix(const Color(0xFF3A63E0), light.surfaceRaised, 0.2);
    expect(_contrast(dark.contentPrimary, liveDark), greaterThanOrEqualTo(4.5));
    expect(_contrast(const Color(0xFFA5B4FC), liveDark),
        greaterThanOrEqualTo(4.5));
    expect(_contrast(const Color(0xFF5B8CFF), liveDark),
        greaterThanOrEqualTo(3.0));
    expect(
        _contrast(light.contentPrimary, liveLight), greaterThanOrEqualTo(4.5));
    expect(_contrast(const Color(0xFF4340D6), liveLight),
        greaterThanOrEqualTo(4.5));
    expect(_contrast(const Color(0xFF3A63E0), liveLight),
        greaterThanOrEqualTo(3.0));

    // Sheet content sits on opaque surfaceRaised (the scrim only dims the
    // backdrop — text never sits on it).
    expect(_contrast(dark.contentPrimary, dark.surfaceRaised),
        greaterThanOrEqualTo(4.5));
    expect(_contrast(light.contentPrimary, light.surfaceRaised),
        greaterThanOrEqualTo(4.5));
  });

  // --- §9: reduce-motion degrades to static -------------------------------

  testWidgets('selection toolbar renders statically under reduce-motion',
      (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: _app(
          SelectionToolbar(
            visible: true,
            selectedCount: 2,
            actions: const [
              SelectionToolbarAction(label: 'Approve 2'),
              SelectionToolbarAction(label: 'Reject 2'),
            ],
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.byType(AnimatedSlide), findsNothing);
    expect(find.byType(AnimatedOpacity), findsNothing);
  });
}
