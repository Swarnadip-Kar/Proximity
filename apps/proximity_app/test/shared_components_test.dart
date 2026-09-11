// Shared-components section tests (presentation rebuild, §4.1–§4.8, §6.2).
//
// Covers the new `lib/widgets/` layer only: pure helpers (initials, hash,
// overlay geometry, verdict vocabulary, selection state) + widget behavior
// (hold-and-tap, badge set, chip fallback, sheet, toolbar, expander,
// two-oval overlay, log drawer + restyled terminal). No behavior, verdict
// string, timing, threshold, or network contract is asserted here beyond
// what the specs freeze — these tests pin rendering + interaction only.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/debug/debug_log_screen.dart';
import 'package:proximity_app/widgets/account_chip.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';
import 'package:proximity_app/widgets/details_expander.dart';
import 'package:proximity_app/widgets/fallback_button.dart';
import 'package:proximity_app/widgets/log_drawer.dart';
import 'package:proximity_app/widgets/selection_controller.dart';
import 'package:proximity_app/widgets/selection_toolbar.dart';
import 'package:proximity_app/widgets/student_card.dart';
import 'package:proximity_app/widgets/verdict_badge.dart';
import 'package:proximity_ble/ble.dart';

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme ?? proxLightTheme(),
      home: Scaffold(body: child),
    );

void main() {
  // --- Pure helpers ------------------------------------------------------

  test('studentInitials derives up to 2 initials, never face data', () {
    expect(studentInitials('Ada Lovelace'), 'AL');
    expect(studentInitials('plato'), 'PL');
    expect(studentInitials('  a  '), 'A');
    expect(studentInitials(''), '?');
    expect(studentInitials('Mary Jane Watson'), 'MJ');
  });

  test('studentColorIndex is deterministic and in palette range', () {
    expect(studentColorIndex('Ada Lovelace'),
        studentColorIndex('Ada Lovelace'));
    for (final name in ['A', 'Student One', 'Zoe', 'a@x.in', '']) {
      final i = studentColorIndex(name);
      expect(i, inInclusiveRange(0, 4));
    }
  });

  test('studentAvatarColor draws from Foundation tokens only', () {
    const dark = ProximityColors.dark();
    const light = ProximityColors.light();
    final palette = {
      light.accentBrand,
      light.statusMarked,
      light.statusLate,
      light.statusReview,
      light.statusError,
    };
    expect(palette, contains(studentAvatarColor(light, 'Ada Lovelace')));
    final darkPalette = {
      dark.accentBrand,
      dark.statusMarked,
      dark.statusLate,
      dark.statusReview,
      dark.statusError,
    };
    expect(
        darkPalette, contains(studentAvatarColor(dark, 'Ada Lovelace')));
  });

  test('VerdictBadge labels match the frozen verbatim vocabulary', () {
    expect(VerdictBadge.labelFor(ProxStatus.marked), 'Marked');
    expect(VerdictBadge.labelFor(ProxStatus.late), 'Late');
    expect(VerdictBadge.labelFor(ProxStatus.wrongOrg), 'Wrong org');
    expect(VerdictBadge.labelFor(ProxStatus.noSignal), 'No signal');
    expect(VerdictBadge.labelFor(ProxStatus.review), 'Needs review');
    expect(VerdictBadge.labelFor(ProxStatus.waiting), 'Waiting');
    expect(VerdictBadge.labelFor(ProxStatus.pending), 'Pending');
  });

  test('CaptureOverlay direction mapping is angle-count-agnostic', () {
    // No hardcoded 3 or 5: any total spreads around the circle.
    for (final total in [1, 2, 3, 5, 7]) {
      final dirs = [
        for (var i = 0; i < total; i++)
          CaptureOverlay.directionForAngle(i, total)
      ];
      expect(dirs, hasLength(total));
      for (final d in dirs) {
        expect(d.dx.abs(), lessThanOrEqualTo(1.0));
        expect(d.dy.abs(), lessThanOrEqualTo(1.0));
      }
    }
    expect(
      CaptureOverlay.directionForAngle(0, 1),
      Offset.zero,
    );
    expect(
      CaptureOverlay.directionForAngle(0, 0),
      Offset.zero,
    );
    // Out-of-range clamps instead of throwing.
    expect(
      CaptureOverlay.directionForAngle(99, 5),
      CaptureOverlay.directionForAngle(4, 5),
    );
  });

  test('CaptureOverlay rects stay inside the preview', () {
    const size = Size(400, 800);
    final large = CaptureOverlay.largeRectFor(size);
    expect(large.width, lessThan(size.width));
    expect(large.height, lessThan(size.height));
    for (final dir in [
      Offset.zero,
      const Offset(1, 0),
      const Offset(-1, 1),
      const Offset(0.5, -0.5),
    ]) {
      final small = CaptureOverlay.smallRectFor(size, dir);
      expect(small.width, lessThan(large.width));
      expect(small.height, lessThan(large.height));
    }
    // The small oval shifts toward the target direction.
    final left =
        CaptureOverlay.smallRectFor(size, const Offset(-1, 0));
    final right =
        CaptureOverlay.smallRectFor(size, const Offset(1, 0));
    expect(left.center.dx, lessThan(right.center.dx));
  });

  test('CaptureOverlay signal colors are distinct states', () {
    const light = ProximityColors.light();
    final neutral =
        CaptureOverlay.signalColorFor(CaptureSignal.neutral, light);
    final inconclusive =
        CaptureOverlay.signalColorFor(CaptureSignal.inconclusive, light);
    final mismatch =
        CaptureOverlay.signalColorFor(CaptureSignal.mismatch, light);
    // Override 2026-09-10: neutral is the glowing-green beacon tone.
    expect(neutral, light.statusMarked);
    expect(inconclusive, light.contentSecondary);
    expect(mismatch, light.statusError);
    expect({neutral, inconclusive, mismatch}, hasLength(3));
  });

  test('SelectionController is list-local membership state', () {
    final ctl = SelectionController();
    expect(ctl.selecting, isFalse);
    ctl.select('a@x');
    expect(ctl.selecting, isTrue);
    expect(ctl.isSelected('a@x'), isTrue);
    ctl.toggle('a@x');
    expect(ctl.selecting, isFalse);
    ctl.selectAll(['a@x', 'b@x']);
    expect(ctl.count, 2);
    ctl.deselect('a@x');
    expect(ctl.count, 1);
    ctl.clear();
    expect(ctl.selecting, isFalse);
    ctl.dispose();
  });

  // --- StudentCard -------------------------------------------------------

  testWidgets('StudentCard renders 3-line shape with badge + trail',
      (t) async {
    await t.pumpWidget(_app(StudentCard(
      name: 'Student One',
      subtitle: '10000001 · student@example.com',
      status: const VerdictBadge(status: ProxStatus.marked),
      roundTrail: const [
        RoundTick('R1', present: true),
        RoundTick('R2', present: false),
      ],
    )));
    expect(find.text('Student One'), findsOneWidget);
    expect(
        find.text('10000001 · student@example.com'), findsOneWidget);
    expect(find.text('Marked'), findsOneWidget);
    // Round trail renders as pill chips: label text + check/close icon
    // (UI overhaul: icon + color + text, never raw "R1 ✓" text).
    expect(find.text('R1'), findsOneWidget);
    expect(find.text('R2'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    // No checkbox anywhere — selection is hold-and-tap.
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('StudentCard hold-select: long-press enters, taps toggle',
      (t) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform,
            (call) async => null);
    var selected = false;
    var tapped = false;
    await t.pumpWidget(_app(StatefulBuilder(
      builder: (context, setState) => StudentCard(
        name: 'Student One',
        selectionMode: selected,
        selected: selected,
        onSelectionChanged: (v) => setState(() => selected = v),
        onTap: () => tapped = true,
      ),
    )));
    // Plain tap navigates/acts.
    await t.tap(find.text('Student One'));
    expect(tapped, isTrue);
    expect(selected, isFalse);
    // Long-press enters selection (scale + haptic + ring path).
    await t.longPress(find.text('Student One'));
    await t.pump();
    expect(selected, isTrue);
    // Taps now toggle instead of acting.
    tapped = false;
    await t.tap(find.text('Student One'));
    await t.pump();
    expect(selected, isFalse);
    expect(tapped, isFalse);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  // --- VerdictBadge ------------------------------------------------------

  testWidgets('VerdictBadge renders the exhaustive set with shapes',
      (t) async {
    for (final status in ProxStatus.values) {
      await t.pumpWidget(_app(
        VerdictBadge(status: status),
        theme: proxLightTheme(),
      ));
      await t.pump();
      expect(
        find.text(VerdictBadge.labelFor(status)),
        findsOneWidget,
        reason: '$status',
      );
      // Color + shape + text: icon present alongside the word.
      expect(find.byType(Icon), findsWidgets);
      // Disarm timers before the next pump (pending arms a pulse timer).
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('VerdictBadge flip-to-Marked plays the elastic inside',
      (t) async {
    const badgeKey = Key('flip-badge');
    await t.pumpWidget(_app(const VerdictBadge(
      key: badgeKey,
      status: ProxStatus.waiting,
    )));
    expect(find.text('Waiting'), findsOneWidget);
    await t.pumpWidget(_app(const VerdictBadge(
      key: badgeKey,
      status: ProxStatus.marked,
    )));
    await t.pumpAndSettle();
    expect(find.text('Marked'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(badgeKey),
        matching: find.byType(ScaleTransition),
      ),
      findsOneWidget,
    );
    await t.pumpWidget(const SizedBox());
  });

  // --- AccountChip -------------------------------------------------------

  testWidgets('AccountChip shows identity + Gmail badge, flat by default',
      (t) async {
    await t.pumpWidget(_app(const AccountChip(
      displayName: 'Ada Lovelace',
      email: 'ada@gmail.com',
    )));
    expect(find.text('Ada Lovelace'), findsOneWidget);
    expect(find.text('ada@gmail.com'), findsOneWidget);
    expect(find.byIcon(Icons.mail), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('AccountChip failed photo falls back to initials', (t) async {
    await t.pumpWidget(_app(const AccountChip(
      displayName: 'Ada Lovelace',
      email: 'ada@gmail.com',
      photoUrl: 'https://example.invalid/avatar.png',
      largeHeader: true,
    )));
    await t.pumpAndSettle();
    // errorBuilder → deterministic initials, never a broken-image icon.
    expect(find.text('AL'), findsOneWidget);
    expect(find.byIcon(Icons.broken_image), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  // --- FallbackButton ----------------------------------------------------

  testWidgets('FallbackButton opens a keyboard-safe sheet', (t) async {
    await t.pumpWidget(_app(FallbackButton(
      label: 'Enter IP manually',
      sheetTitle: 'Enter IP',
      sheetBuilder: (_) => const TextField(key: Key('ipfield')),
    )));
    await t.tap(find.text('Enter IP manually'));
    await t.pumpAndSettle();
    expect(find.text('Enter IP'), findsOneWidget);
    expect(find.byKey(const Key('ipfield')), findsOneWidget);
    await t.enterText(
        find.byKey(const Key('ipfield')), '192.168.43.1');
    expect(find.text('192.168.43.1'), findsOneWidget);
  });

  // --- Selection toolbar + scoping ---------------------------------------

  testWidgets('SelectionToolbar shows count + actions while visible',
      (t) async {
    var approved = 0;
    var cancelled = false;
    await t.pumpWidget(_app(SelectionToolbar(
      visible: true,
      selectedCount: 2,
      totalCount: 5,
      actions: [
        SelectionToolbarAction(
          label: 'Approve 2',
          onPressed: () => approved++,
        ),
      ],
      onSelectAll: () {},
      onCancel: () => cancelled = true,
    )));
    expect(find.text('2 of 5 selected'), findsOneWidget);
    await t.tap(find.text('Approve 2'));
    expect(approved, 1);
    await t.tap(find.byTooltip('Cancel'));
    expect(cancelled, isTrue);

    await t.pumpWidget(_app(const SelectionToolbar(
      visible: false,
      selectedCount: 0,
    )));
    expect(find.textContaining('selected'), findsNothing);
  });

  testWidgets('SelectionScope isolates one list from another', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(
        body: Column(
          children: const [
            SelectionScope(child: _ScopeProbe(id: 'a@x')),
            SelectionScope(child: _ScopeProbe(id: 'b@x')),
          ],
        ),
      ),
    ));
    await t.tap(find.byKey(const ValueKey('select-a@x')));
    await t.pump();
    expect(find.text('a@x:1'), findsOneWidget);
    expect(find.text('b@x:0'), findsOneWidget);
  });

  // --- DetailsExpander ---------------------------------------------------

  testWidgets('DetailsExpander collapses secondary copy by default',
      (t) async {
    await t.pumpWidget(_app(const DetailsExpander(
      child: Text('why it works'),
    )));
    expect(find.text('Details'), findsOneWidget);
    // AnimatedCrossFade keeps both children mounted — assert the state,
    // not findability.
    AnimatedCrossFade crossFade() =>
        t.widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade));
    expect(crossFade().crossFadeState, CrossFadeState.showFirst);
    await t.tap(find.text('Details'));
    await t.pumpAndSettle();
    expect(crossFade().crossFadeState, CrossFadeState.showSecond);
    expect(find.text('why it works'), findsOneWidget);
    await t.tap(find.text('Details'));
    await t.pumpAndSettle();
    expect(crossFade().crossFadeState, CrossFadeState.showFirst);
  });

  // --- CaptureOverlay ----------------------------------------------------

  testWidgets('CaptureOverlay renders bar + single oval + one line',
      (t) async {
    for (final total in [3, 5]) {
      await t.pumpWidget(_app(CaptureOverlay(
        progress: 2 / total,
        currentAngle: 2,
        totalAngles: total,
        statusLine: 'Hold still, retrying',
      )));
      await t.pump();
      // Exactly three overlay elements: slim progress bar, single
      // oval + beacon (one CustomPaint), one prompt line.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.text('Hold still, retrying'), findsOneWidget);
      // No per-angle labels, dots, brackets, or dialogs.
      expect(find.textContaining('R1'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('CaptureOverlay defaults to the single guide prompt', (t) async {
    await t.pumpWidget(_app(const CaptureOverlay(
      progress: 0,
      currentAngle: 0,
      totalAngles: 5,
    )));
    await t.pump();
    expect(find.text(captureGuidePrompt), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('CaptureOverlay mismatch signal holds error tone', (t) async {
    await t.pumpWidget(_app(const CaptureOverlay(
      progress: 0.5,
      currentAngle: 1,
      totalAngles: 5,
      signal: CaptureSignal.mismatch,
      statusLine: 'Wrong person — attempt burned',
    )));
    await t.pump(const Duration(milliseconds: 900));
    expect(find.text('Wrong person — attempt burned'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  // --- Log drawer + terminal ---------------------------------------------

  group('log drawer + terminal', () {
    setUp(BleLog.clear);
    tearDown(BleLog.clear);

    testWidgets('drawer peeks, filters, and expands into debug/log',
        (t) async {
      BleLog.log('BLE', 'hello-ble');
      BleLog.log('SYNC', 'hello-sync');
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showLogDrawer(context),
              child: const Text('Open log'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('Open log'));
      await t.pumpAndSettle();
      expect(find.text('System log'), findsWidgets);
      expect(find.text('Expand'), findsOneWidget);
      expect(find.textContaining('hello-ble'), findsOneWidget);
      final sheet = t.widget<DraggableScrollableSheet>(
        find.byType(DraggableScrollableSheet),
      );
      expect(sheet.initialChildSize, moreOrLessEquals(0.3));
      expect(sheet.maxChildSize, moreOrLessEquals(1.0));

      // Tag chips filter the stream view.
      await t.tap(find.text('SYNC'));
      await t.pump();
      expect(find.textContaining('hello-ble'), findsNothing);
      expect(find.textContaining('hello-sync'), findsOneWidget);

      // Expand carries the tag selection into the full-screen view.
      await t.tap(find.text('Expand'));
      await t.pumpAndSettle();
      expect(find.textContaining('1 of 2 events'), findsOneWidget);
    });

    testWidgets('debug/log honors an incoming tag filter', (t) async {
      BleLog.log('BLE', 'hello-ble');
      BleLog.log('SYNC', 'hello-sync');
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: const DebugLogScreen(initialTags: {'BLE'}),
      ));
      await t.pump();
      expect(find.textContaining('1 of 2 events'), findsOneWidget);
      expect(find.textContaining('hello-ble'), findsOneWidget);
      expect(find.textContaining('hello-sync'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  });

  // --- Dark/light parity ---------------------------------------------------

  testWidgets('shared components render on both themes', (t) async {
    Widget body() => Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            StudentCard(name: 'Student One', subtitle: '1 · a@x'),
            VerdictBadge(status: ProxStatus.pending),
            AccountChip(displayName: 'Ada', email: 'ada@gmail.com'),
          ],
        );
    await t.pumpWidget(_app(body(), theme: proxLightTheme()));
    expect(find.text('Student One'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    await t.pumpWidget(_app(body(), theme: proxDarkTheme()));
    await t.pump();
    expect(find.text('Student One'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}

class _ScopeProbe extends ConsumerWidget {
  final String id;
  const _ScopeProbe({required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctl = ref.watch(selectionControllerProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$id:${ctl.count}',
            key: ValueKey('count-$id')),
        TextButton(
          key: ValueKey('select-$id'),
          onPressed: () =>
              ref.read(selectionControllerProvider).select(id),
          child: const Text('Sel'),
        ),
      ],
    );
  }
}
