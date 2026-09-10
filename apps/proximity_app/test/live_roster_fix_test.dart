// Live roster fix (tester-reported Live-tab placement bug):
// the professor ROSTER section must show ONLY waiting + present +
// partial + dup + search. Manual-entry UI (direct-add form / add entry)
// belongs in its own add/inbox sections behind the sub-nav.
//
// - Roster path renders no ManualAddForm / direct-add / inbox UI.
// - Inbox + add sections stay reachable and functional (driver wiring
//   unchanged — decisions and adds still flow through the host driver).
// - Section splits (waiting / present / partial / search) render
//   standalone; MarkedRosterSection keeps composing them (presentational
//   split only — driver reads, filtering, strings, and timings frozen).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/live/live_roster.dart';
import 'package:proximity_app/features/live/live_sections.dart';
import 'package:proximity_app/features/manual_attendance/manual_attendance.dart'
    as ma;
import 'package:proximity_storage/storage.dart';

Widget _themed(Widget body) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: body),
    );

Future<FakeHostDriver> _seededDriver() async {
  final driver = FakeHostDriver();
  await driver.startHosting(classLabel: 'CS201');
  driver.tally.noteWindow(1);
  driver.tally.noteWindow(2);
  driver.tally.mark('a@univ.edu', 'A', 1, roll: '1');
  driver.tally.mark('a@univ.edu', 'A', 2, roll: '1');
  driver.tally.mark('b@univ.edu', 'B', 1, roll: '2');
  await driver.addManualEntry(email: 'w@univ.edu', name: 'W', roll: '3');
  driver.seedDupGroup('a@univ.edu', ['b@univ.edu']);
  driver.seedManual(const [
    ManualRow(email: 'm@univ.edu', name: 'M One', roll: '9'),
  ]);
  return driver;
}

Widget _rosterHarness(FakeHostDriver driver) => ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
        hostDriverProvider.overrideWithValue(driver),
      ],
      child: MaterialApp(
        theme: proxLightTheme(),
        home: const LiveRosterScreen(course: 'CS201'),
      ),
    );

void main() {
  testWidgets(
      'roster shows waiting + present + partial + dup + search, no manual entry',
      (t) async {
    final driver = await _seededDriver();
    await t.pumpWidget(_rosterHarness(driver));
    await t.pumpAndSettle();

    // Roster-only content is all here.
    expect(find.textContaining('Waiting area (1)'), findsOneWidget);
    expect(find.textContaining('Present — all rounds (1)'), findsOneWidget);
    expect(find.textContaining('Partial — some rounds'), findsOneWidget);
    expect(find.textContaining('duplicate face'), findsOneWidget);
    expect(find.byKey(const ValueKey('prof-search')), findsOneWidget);

    // No manual-entry composition on the roster path.
    expect(find.byType(ma.ManualAddForm), findsNothing);
    expect(find.text('Direct manual entry'), findsNothing);
    expect(find.text('Add & mark present'), findsNothing);
    expect(find.textContaining('Manual requests'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('inbox section stays reachable and approves (functional)',
      (t) async {
    final driver = await _seededDriver();
    await t.pumpWidget(ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
        cloudSyncProvider.overrideWithValue(FakeCloudSync()),
        hostDriverProvider.overrideWithValue(driver),
      ],
      child: MaterialApp(
        theme: proxLightTheme(),
        home: const LiveInboxScreen(course: 'CS201'),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.text('Manual requests (1)'), findsOneWidget);
    expect(find.text('M One'), findsOneWidget);
    await t.longPress(find.text('M One'));
    await t.pumpAndSettle();
    final approve = find.widgetWithText(TextButton, 'Approve 1');
    expect(approve, findsOneWidget);
    await t.ensureVisible(approve);
    await t.pumpAndSettle();
    await t.tap(approve);
    await t.pumpAndSettle();

    // The section still wires decisions through the host driver.
    expect(driver.manualPending, isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets('add section stays reachable with a working entry form',
      (t) async {
    final driver = await _seededDriver();
    final store = InMemoryDeviceStore();
    await t.pumpWidget(ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(store),
        cloudSyncProvider.overrideWithValue(FakeCloudSync(online: false)),
        hostDriverProvider.overrideWithValue(driver),
      ],
      child: MaterialApp(
        theme: proxLightTheme(),
        home: const LiveAddScreen(course: 'CS201'),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.byType(ma.ManualAddForm), findsOneWidget);
    expect(find.text('Add & mark present'), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-roll')), findsOneWidget);

    // Functional through the section wiring: ID-only entry queues offline.
    await t.enterText(find.byKey(const ValueKey('direct-roll')), '10000001');
    await t.tap(find.text('Add & mark present'));
    await t.pumpAndSettle();
    expect(find.textContaining('queued'), findsOneWidget);
    expect((await store.readPendingAdds()).first['roll'], '10000001');
    expect(t.takeException(), isNull);
  });

  testWidgets('split sections render standalone', (t) async {
    final tally = TallyStore();
    tally.noteWindow(1);
    tally.noteWindow(2);
    tally.mark('a@univ.edu', 'A', 1, roll: '1');
    tally.mark('a@univ.edu', 'A', 2, roll: '1');
    tally.mark('b@univ.edu', 'B', 1, roll: '2');
    final partials =
        tally.presentAny.where((r) => r.email == 'b@univ.edu').toList();

    // Present section: header + intersection rows only.
    await t.pumpWidget(_themed(PresentSection(
      present: tally.confirmedCount,
      windowsTaken: tally.windowCount,
      confirmedRows: tally.confirmed,
      windowNos: tally.windowNos,
    )));
    await t.pumpAndSettle();
    expect(find.textContaining('Present — all rounds (1)'), findsOneWidget);
    expect(find.textContaining('a@univ.edu'), findsOneWidget);
    expect(find.textContaining('b@univ.edu'), findsNothing);

    // Partial section: header + partial rows only.
    await t.pumpWidget(_themed(PartialSection(
      partialRows: partials,
      windowNos: tally.windowNos,
    )));
    await t.pumpAndSettle();
    expect(find.textContaining('Partial — some rounds (1)'), findsOneWidget);
    expect(find.textContaining('b@univ.edu'), findsOneWidget);

    // Partial section empty renders nothing.
    await t.pumpWidget(_themed(
      const PartialSection(partialRows: [], windowNos: []),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('Partial'), findsNothing);

    // Search field forwards edits to its owner.
    String? seen;
    await t.pumpWidget(_themed(RosterSearchField(
      onChanged: (v) => seen = v,
    )));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('prof-search')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('prof-search')), 'a@univ');
    expect(seen, 'a@univ');

    // MarkedRosterSection still composes search + present + partial.
    await t.pumpWidget(_themed(MarkedRosterSection(tally: tally)));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('prof-search')), findsOneWidget);
    expect(find.textContaining('Present — all rounds (1)'), findsOneWidget);
    expect(find.textContaining('Partial — some rounds (1)'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
