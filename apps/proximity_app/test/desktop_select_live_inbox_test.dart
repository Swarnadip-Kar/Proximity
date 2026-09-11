// Desktop Select + live inbox (tester-verified defects, 2026-09-10).
//
// FIX 1 — inbox is tap-to-select (same contract as the review/export
// picker): plain taps toggle with no hold and no Select/Done toggle —
// inbox rows have no navigation target to conflict with; right-click
// (secondary tap) also selects on desktop. Sessions multi-delete keeps
// its hold-and-tap + Select/Done toggle (taps there open the detail).
// Checkbox-free everywhere, same controller, same toolbar.
//
// FIX 2 — inbox live updates: ManualInboxSection self-refreshes on the
// existing 2s cadence (local driver reads only); arrivals appear without
// navigation; decided rows still clear via the existing decide + prune
// paths.
//
// Platform-override hygiene: `debugDefaultTargetPlatformOverride` must be
// cleared inline (try/finally) before the test body completes — the
// flutter_test binding verifies foundation vars before `tearDown`
// callbacks run, so a tearDown-only reset fails every test.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/live/manual_inbox.dart';
import 'package:proximity_app/features/records/course_overview_screen.dart';
import 'package:proximity_storage/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' as helpers;

Widget _inbox({
  required List<ManualRow> pending,
  Future<void> Function(String email)? onApproveOne,
  Future<void> Function(String email)? onRejectOne,
  Future<void> Function(List<String> emails, bool approve)? onDecide,
}) =>
    MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(
        body: ManualInboxSection(
          pending: pending,
          onApproveOne: onApproveOne ?? (_) async {},
          onRejectOne: onRejectOne ?? (_) async {},
          onDecide: onDecide ?? (_, __) async {},
        ),
      ),
    );

const _rows = [
  ManualRow(email: 'a@x.in', name: 'A One', roll: '11'),
  ManualRow(email: 'b@x.in', name: 'B Two', roll: '12'),
];

/// Runs [body] under a platform override, clearing it inline before the
/// test completes (see file header).
Future<void> _asPlatform(
    TargetPlatform platform, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// Records ProviderScope shim removed (A4): the desktop-sessions pump
/// below uses the canonical widget_test.testScope (store + explicit
/// MaterialApp home). The inbox self-refresh inline ProviderScope stays:
/// it pins a host-only minimal-override shape, not the shared defaults.

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('desktop inbox: tap toggles, Cancel exits, no mode toggle',
      (t) async {
    await _asPlatform(TargetPlatform.macOS, () async {
      SharedPreferences.setMockInitialValues({});
      await t.pumpWidget(_inbox(pending: _rows));
      await t.pumpAndSettle();
      // No mode toggle on the inbox (tap-to-select needs no arming);
      // same hint caption as the review/export picker.
      expect(find.text('Select'), findsNothing);
      expect(find.text('Done'), findsNothing);
      expect(find.text('Tap to select'), findsOneWidget);
      expect(find.text('Approve 1'), findsNothing);
      // Plain left-click toggles straight away.
      await t.tap(find.text('A One'));
      await t.pumpAndSettle();
      expect(find.text('Approve 1'), findsOneWidget);
      expect(find.text('Select all'), findsOneWidget);
      await t.tap(find.text('B Two'));
      await t.pumpAndSettle();
      expect(find.text('Approve 2'), findsOneWidget);
      // Cancel exits entirely.
      await t.tap(find.byTooltip('Cancel'));
      await t.pumpAndSettle();
      expect(find.text('Approve 1'), findsNothing);
      // Checkbox-free throughout.
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('desktop inbox: right-click enters selection with that row',
      (t) async {
    await _asPlatform(TargetPlatform.macOS, () async {
      await t.pumpWidget(_inbox(pending: _rows));
      await t.pumpAndSettle();
      await t.tap(find.text('A One'), buttons: kSecondaryMouseButton);
      await t.pumpAndSettle();
      expect(find.text('Approve 1'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('mobile inbox: no toggle, secondary no-op, tap selects',
      (t) async {
    await _asPlatform(TargetPlatform.android, () async {
      SharedPreferences.setMockInitialValues({});
      await t.pumpWidget(_inbox(pending: _rows));
      await t.pumpAndSettle();
      // No mode toggle on touch devices; same hint caption as desktop.
      expect(find.text('Select'), findsNothing);
      expect(find.text('Done'), findsNothing);
      expect(find.text('Tap to select'), findsOneWidget);
      // Secondary tap is unwired on mobile: selects nothing, acts nothing.
      await t.tap(find.text('A One'), buttons: kSecondaryMouseButton);
      await t.pump();
      expect(find.text('Approve 1'), findsNothing);
      // Tap entry, taps toggle, Cancel exits.
      await t.tap(find.text('A One'));
      await t.pumpAndSettle();
      expect(find.text('Approve 1'), findsOneWidget);
      await t.tap(find.text('B Two'));
      await t.pumpAndSettle();
      expect(find.text('Approve 2'), findsOneWidget);
      await t.tap(find.byTooltip('Cancel'));
      await t.pumpAndSettle();
      expect(find.text('Approve 1'), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('desktop sessions: Select arms, click toggles, Done exits',
      (t) async {
    await _asPlatform(TargetPlatform.macOS, () async {
      final s = InMemoryDeviceStore();
      await s.addCourse('CS201');
      await s.appendHistory(ClassRecord(
        courseId: 'CS201',
        classLabel: 'CS201',
        dateIso: '2026-09-03',
        w1: const {'a@x.in': true},
        w2: const {'a@x.in': false},
        names: const {'a@x.in': 'A'},
        rolls: const {'a@x.in': '1'},
      ));
      await t.pumpWidget(helpers.testScope(
          store: s,
          home: MaterialApp(
              theme: proxLightTheme(),
              home: const CourseOverviewScreen(courseName: 'CS201'))));
      await t.pumpAndSettle();
      expect(find.text('Select'), findsOneWidget);
      expect(find.text('Delete 1'), findsNothing);
      await t.tap(find.text('Select'));
      await t.pumpAndSettle();
      expect(find.text('Done'), findsOneWidget);
      // Plain left-click toggles the session row while armed (no detail
      // navigation — the tap selects instead).
      await t.tap(find.textContaining('Thu, 03-09-2026'));
      await t.pumpAndSettle();
      expect(find.text('Delete 1'), findsOneWidget);
      expect(find.text('Select all'), findsOneWidget);
      await t.tap(find.text('Done'));
      await t.pumpAndSettle();
      expect(find.text('Select'), findsOneWidget);
      expect(find.text('Delete 1'), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('inbox self-refresh: arrival appears, decided row clears',
      (t) async {
    await _asPlatform(TargetPlatform.macOS, () async {
      final host = FakeHostDriver();
      await host.startHosting(classLabel: 'CS201');
      host.seedManual(const [
        ManualRow(email: 'a@x.in', name: 'A One', roll: '11'),
      ]);
      await t.pumpWidget(ProviderScope(
        overrides: [hostDriverProvider.overrideWithValue(host)],
        child: MaterialApp(
          theme: proxLightTheme(),
          home: Scaffold(
            body: ManualInboxSection(
              pending: host.manualPending,
              onApproveOne: (e) => host.decideManual(e, true),
              onRejectOne: (e) => host.decideManual(e, false),
              onDecide: (emails, approve) async {
                for (final e in emails) {
                  await host.decideManual(e, approve);
                }
              },
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Manual requests (1)'), findsOneWidget);
      expect(find.text('B Two'), findsNothing);
      // Arrival injected mid-mount: no navigation, no parent rebuild —
      // the section's 2s self-refresh picks it up from local driver state.
      host.seedManual(const [
        ManualRow(email: 'a@x.in', name: 'A One', roll: '11'),
        ManualRow(email: 'b@x.in', name: 'B Two', roll: '12'),
      ]);
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      expect(find.text('Manual requests (2)'), findsOneWidget);
      expect(find.text('B Two'), findsOneWidget);
      // Existing decide path still clears the row: approve the arrival,
      // selection drops via the prune path and the row leaves on refresh.
      await t.longPress(find.text('B Two'));
      await t.pumpAndSettle();
      expect(find.text('Approve 1'), findsOneWidget);
      await t.tap(find.text('Approve 1'));
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      expect(find.text('Approve 1'), findsNothing);
      expect(find.text('Manual requests (1)'), findsOneWidget);
      expect(find.text('B Two'), findsNothing);
      expect(find.text('A One'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
