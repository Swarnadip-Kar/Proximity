// Nav-bar item layout: vertical icon-over-label, centered, 13sp labels.
//
// Covers `_ShellBarTab` internals only (shared by student + prof shells):
// - icon on top, label below, both center-aligned (Column, not Row)
// - labels at [ProxType.labelSize] (13sp), semibold, ellipsis, maxLines 1,
//   centered
// - active gradient pill, dimmed/disabled treatment, min-tap heights intact
// - narrow (<360dp) stays icon-only (labels off)
// - no overflow at 360dp or under large text scaling (spot-check)
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/ble_radio.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/screens/setup_flow_screen.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_ble/ble.dart';

const _linked = LinkedIdentity(
    name: 'Test User', gmail: 'student@example.com', roll: 'R1');

List<Override> _studentOverrides({LinkedIdentity? linked}) {
  return [
    authServiceProvider.overrideWithValue(FakeAuthService(const SignedAccount(
        email: 'student@example.com',
        displayName: 'Test User',
        uid: 'test-uid'))),
    cloudSyncProvider.overrideWithValue(FakeCloudSync()),
    deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
    faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
    deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
    hostDriverProvider.overrideWithValue(FakeHostDriver()),
    studentDriverProvider
        .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
    bleEngineProvider.overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
    blePermissionProvider.overrideWithValue(() async => true),
    btPowerProvider.overrideWithValue(() async => BtState.on),
    if (linked != null) linkedIdentityProvider.overrideWith((ref) => linked),
    enrollmentControllerProvider.overrideWith(
      (ref) => EnrollmentController(
        auth: ref.watch(authServiceProvider),
        store: ref.watch(deviceStoreProvider),
        verifier: FakeFaceVerifier(),
        deviceKey: FakeDeviceKey(),
      ),
    ),
  ];
}

List<Override> _profOverrides(InMemoryDeviceStore store) {
  return [
    authServiceProvider.overrideWithValue(FakeAuthService(const SignedAccount(
        email: 'prof@example.com', displayName: 'Prof', uid: 'prof-uid'))),
    cloudSyncProvider.overrideWithValue(FakeCloudSync()),
    deviceStoreProvider.overrideWithValue(store),
    faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
    deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
    hostDriverProvider.overrideWithValue(FakeHostDriver()),
    studentDriverProvider
        .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
    bleEngineProvider.overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
    blePermissionProvider.overrideWithValue(() async => true),
    btPowerProvider.overrideWithValue(() async => BtState.on),
    enrollmentControllerProvider.overrideWith(
      (ref) => EnrollmentController(
        auth: ref.watch(authServiceProvider),
        store: ref.watch(deviceStoreProvider),
        verifier: FakeFaceVerifier(),
        deviceKey: FakeDeviceKey(),
      ),
    ),
  ];
}

Future<void> _pumpWithSize(
  WidgetTester t,
  Widget shell,
  List<Override> overrides,
  Size size, {
  double textScale = 1.0,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  await t.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: proxLightTheme(),
        builder: (context, c) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
          ),
          child: c!,
        ),
        home: shell,
      ),
    ),
  );
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

Finder _pillFinder() => find.descendant(
      of: find.byKey(const ValueKey('shell-bar')),
      matching: find.byWidgetPredicate((w) =>
          w is AnimatedContainer &&
          (w.decoration as BoxDecoration?)?.borderRadius ==
              BorderRadius.circular(ProxRadii.pill)),
    );

void _assertVerticalTab(WidgetTester t, String label) {
  final tabKey = find.byKey(ValueKey('shell-tab-$label'));
  expect(tabKey, findsOneWidget, reason: 'tab $label exists');
  final tabRect = t.getRect(tabKey);

  final labelFinder = find.descendant(
    of: tabKey,
    matching: find.text(label),
  );
  expect(labelFinder, findsOneWidget, reason: 'label $label visible');
  final labelRect = t.getRect(labelFinder);
  final labelWidget = t.widget<Text>(labelFinder);
  expect(labelWidget.style?.fontSize, ProxType.labelSize,
      reason: '$label label one step up to 13sp');
  expect(labelWidget.overflow, TextOverflow.ellipsis,
      reason: '$label ellipsis preserved');
  expect(labelWidget.maxLines, 1);
  expect(labelWidget.textAlign, TextAlign.center,
      reason: '$label center-aligned');

  // Label centered in its cell; icon sits above (label top well below tab
  // top: pill xs + icon lg + xs gap = 32).
  expect(labelRect.center.dx, moreOrLessEquals(tabRect.center.dx, epsilon: 2.5),
      reason: '$label centered in cell');
  expect(labelRect.top, greaterThan(tabRect.top + 28),
      reason: '$label below icon (vertical stack)');

  // Icon (Icon or account avatar) above the label, same center X.
  final iconFinder = find.descendant(
    of: tabKey,
    matching: find.byWidgetPredicate(
        (w) => w is Icon || w is CircleAvatar || w is ClipOval),
  );
  expect(iconFinder, findsWidgets, reason: '$label has icon/avatar');
  final iconRect = t.getRect(iconFinder.first);
  expect(iconRect.bottom, lessThanOrEqualTo(labelRect.top + 4.5),
      reason: '$label icon on top');
  expect(iconRect.center.dx, moreOrLessEquals(labelRect.center.dx, epsilon: 3),
      reason: '$label icon/label share center X');

  // Min-tap height intact (pill lg + xs + 16 + vxs*2 = 52).
  expect(tabRect.height, greaterThanOrEqualTo(ProxSpacing.minTap),
      reason: '$label tap height >= 48');
}

void main() {
  group('nav-bar vertical item layout', () {
    testWidgets('student tabs stack icon-over-label, centered, 13sp',
        (t) async {
      await _pumpWithSize(t, const StudentShell(),
          _studentOverrides(linked: _linked), const Size(390, 844));
      expect(t.takeException(), isNull);

      // Pill bodies are Columns now (were horizontal Rows).
      final pills = _pillFinder();
      expect(pills, findsNWidgets(3));
      for (var i = 0; i < 3; i++) {
        final pill = t.widget<AnimatedContainer>(pills.at(i));
        expect(pill.child, isA<Column>(),
            reason: 'pill $i vertical Column');
        final col = pill.child as Column;
        expect(col.mainAxisSize, MainAxisSize.min);
        expect(col.crossAxisAlignment, CrossAxisAlignment.center);
      }

      for (final label in ['Mark', 'Courses', 'Account']) {
        _assertVerticalTab(t, label);
      }

      // Active pill keeps the brand gradient; inactive pills have none.
      var gradientCount = 0;
      for (var i = 0; i < 3; i++) {
        final pill = t.widget<AnimatedContainer>(pills.at(i));
        final d = pill.decoration;
        if (d is BoxDecoration && d.gradient != null) gradientCount++;
      }
      expect(gradientCount, 1, reason: 'exactly one active pill');
      expect(t.takeException(), isNull);
    });

    testWidgets('prof tabs match student vertical layout', (t) async {
      await _pumpWithSize(t, const ProfShell(),
          _profOverrides(InMemoryDeviceStore()), const Size(390, 844));
      expect(t.takeException(), isNull);
      final pills = _pillFinder();
      expect(pills, findsNWidgets(3));
      for (var i = 0; i < 3; i++) {
        expect(t.widget<AnimatedContainer>(pills.at(i)).child, isA<Column>());
      }
      for (final label in ['Live', 'Courses', 'Account']) {
        _assertVerticalTab(t, label);
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('desktop width keeps vertical layout', (t) async {
      await _pumpWithSize(t, const StudentShell(),
          _studentOverrides(linked: _linked), const Size(800, 600));
      expect(t.takeException(), isNull);
      for (final label in ['Mark', 'Courses', 'Account']) {
        _assertVerticalTab(t, label);
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('disabled (gated) tabs stay dimmed, taps still land',
        (t) async {
      // Unenrolled: Mark/Courses dimmed via static Opacity 0.45. The
      // auto-pushed flow offstages the bar, so read through it (like the
      // tab_slide sync helper) — dimming lives under the flow.
      await _pumpWithSize(t, const StudentShell(), _studentOverrides(),
          const Size(390, 844));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(find.byType(SetupFlowScreen), findsOneWidget);
      for (final label in ['Mark', 'Courses']) {
        final opacities = t.widgetList<Opacity>(find.descendant(
          of: find.byKey(ValueKey('shell-tab-$label'), skipOffstage: false),
          matching: find.byType(Opacity, skipOffstage: false),
          skipOffstage: false,
        ));
        expect(opacities, isNotEmpty, reason: '$label has Opacity');
        expect(opacities.first.opacity, 0.45,
            reason: '$label dimmed while gated');
      }
      final accountOpacities = t.widgetList<Opacity>(find.descendant(
        of: find.byKey(const ValueKey('shell-tab-Account'), skipOffstage: false),
        matching: find.byType(Opacity, skipOffstage: false),
        skipOffstage: false,
      ));
      expect(accountOpacities.first.opacity, 1.0);
      expect(t.takeException(), isNull);
    });

    testWidgets('narrow <360dp stays icon-only, no overflow', (t) async {
      await _pumpWithSize(t, const StudentShell(),
          _studentOverrides(linked: _linked), const Size(350, 700));
      expect(t.takeException(), isNull);
      // Labels off in narrow mode (icon-only unchanged in structure).
      for (final label in ['Mark', 'Courses', 'Account']) {
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('shell-bar')),
            matching: find.text(label),
          ),
          findsNothing,
          reason: 'narrow hides $label',
        );
      }
      // Icons still render, bar still interactive, no stripes.
      expect(find.byKey(const ValueKey('shell-bar')), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.byKey(const ValueKey('shell-tab-Courses')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(t.takeException(), isNull);
    });

    testWidgets('360dp + 130% text: no overflow, labels intact', (t) async {
      await _pumpWithSize(
          t,
          const StudentShell(),
          _studentOverrides(linked: _linked),
          const Size(360, 700),
          textScale: 1.3);
      expect(t.takeException(), isNull);
      for (final label in ['Mark', 'Courses', 'Account']) {
        final finder = find.descendant(
          of: find.byKey(const ValueKey('shell-bar')),
          matching: find.text(label),
        );
        expect(finder, findsOneWidget);
        final w = t.widget<Text>(finder);
        expect(w.overflow, TextOverflow.ellipsis);
        expect(w.maxLines, 1);
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('large text (200%) spot-check: no overflow', (t) async {
      await _pumpWithSize(
          t,
          const ProfShell(),
          _profOverrides(InMemoryDeviceStore()),
          const Size(390, 844),
          textScale: 2.0);
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('shell-bar')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
