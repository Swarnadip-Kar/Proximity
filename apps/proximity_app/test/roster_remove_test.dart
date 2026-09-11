// Professor eject from the live roster (swipe → confirm → removed).
//
// Contract: `HostDriver.removeStudent` drops one email from the waiting
// list, manual queue, live tally and dup flags (session-local; saved
// history untouched until the next upsert). The roster UI exposes it as
// swipe-to-remove with a confirm dialog — never a bare tap. Rejoin or
// re-mark re-adds.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/live/live_roster.dart';
import 'package:proximity_storage/storage.dart';

void main() {
  group('FakeHostDriver.removeStudent', () {
    test('drops waiting + tally + dup flags, true when removed', () async {
      final driver = FakeHostDriver();
      await driver.addManualEntry(
          email: 'w@univ.edu', name: 'Wanda', roll: '7');
      expect(driver.waitingRows.map((w) => w.email),
          contains('w@univ.edu'));
      expect(driver.tally.size, greaterThan(0));

      final removed = await driver.removeStudent('W@univ.edu');
      expect(removed, isTrue);
      expect(driver.waitingRows.map((w) => w.email),
          isNot(contains('w@univ.edu')));
      expect(driver.tally.size, 0);
    });

    test('false for unknown email, tolerates blank', () async {
      final driver = FakeHostDriver();
      expect(await driver.removeStudent('nobody@univ.edu'), isFalse);
      expect(await driver.removeStudent(''), isFalse);
    });

    test('re-mark re-adds after removal', () async {
      final driver = FakeHostDriver();
      await driver.addManualEntry(
          email: 'w@univ.edu', name: 'Wanda', roll: '7');
      expect(await driver.removeStudent('w@univ.edu'), isTrue);
      await driver.addManualEntry(
          email: 'w@univ.edu', name: 'Wanda', roll: '7');
      expect(driver.waitingRows.map((w) => w.email),
          contains('w@univ.edu'));
      expect(driver.tally.size, greaterThan(0));
    });
  });

  group('TallyStore.remove', () {
    test('drops the record, keeps opened windows', () {
      final tally = TallyStore();
      tally.mark('a@x.in', 'A', 1);
      tally.mark('b@x.in', 'B', 1);
      expect(tally.remove('a@x.in'), isTrue);
      expect(tally.size, 1);
      expect(tally.windowNos, contains(1));
      expect(tally.remove('a@x.in'), isFalse);
    });
  });

  group('RemovableRosterRow', () {
    Future<void> pumpHarness(
      WidgetTester t, {
      required List<WaitingRow> rows,
      required Future<bool> Function(String) onRemove,
    }) async {
      final tally = TallyStore();
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: Scaffold(
          body: _Harness(rows: rows, tally: tally, onRemove: onRemove),
        ),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('swipe → confirm → row gone', (t) async {
      final rows = [const WaitingRow(email: 'w@univ.edu', name: 'Wanda')];
      Future<bool> onRemove(String email) async {
        rows.removeWhere((w) => w.email == email);
        return true;
      }

      await pumpHarness(t, rows: rows, onRemove: onRemove);
      expect(find.text('Wanda'), findsOneWidget);

      await t.fling(find.text('Wanda'), const Offset(-400, 0), 800);
      await t.pumpAndSettle();
      expect(find.text('Remove Wanda?'), findsOneWidget);

      await t.tap(find.text('Remove'));
      await t.pumpAndSettle();
      expect(find.text('Wanda'), findsNothing);
      expect(rows, isEmpty);
    });

    testWidgets('cancel keeps the row', (t) async {
      final rows = [const WaitingRow(email: 'w@univ.edu', name: 'Wanda')];
      Future<bool> onRemove(String email) async => true;

      await pumpHarness(t, rows: rows, onRemove: onRemove);
      await t.fling(find.text('Wanda'), const Offset(-400, 0), 800);
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.text('Wanda'), findsOneWidget);
      expect(rows, hasLength(1));
    });

    testWidgets('wired sink renders dismissible row', (t) async {
      await pumpHarness(
        t,
        rows: [const WaitingRow(email: 'w@univ.edu', name: 'Wanda')],
        onRemove: (_) async => true,
      );
      // Dismissible is present when a sink is given…
      expect(find.byType(Dismissible), findsOneWidget);
    });
  });
}

class _Harness extends StatefulWidget {
  final List<WaitingRow> rows;
  final TallyStore tally;
  final Future<bool> Function(String) onRemove;
  const _Harness(
      {required this.rows, required this.tally, required this.onRemove});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  @override
  Widget build(BuildContext context) {
    return LiveRosterBody(
      waitingRows: List.of(widget.rows),
      groups: const {},
      names: const {},
      onResolve: (_) async {},
      tally: widget.tally,
      onRemoveStudent: (email) async {
        final removed = await widget.onRemove(email);
        if (mounted) setState(() {});
        return removed;
      },
    );
  }
}
