import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/live/live_roster.dart';

void main() {
  group('DupFlagSection (roster copy + 1-tap resolve)', () {
    testWidgets('renders neutral copy and resolves on tap', (tester) async {
      var resolved = '';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DupFlagSection(
            groups: {
              'a@x.in': {'b@x.in'},
              'b@x.in': {'a@x.in'},
            },
            names: const {'a@x.in': 'A', 'b@x.in': 'B'},
            onResolve: (email) async {
              resolved = email;
            },
          ),
        ),
      ));
      expect(find.textContaining('Duplicate face detected between'), findsOneWidget);
      expect(find.textContaining('A (a@x.in)'), findsOneWidget);
      expect(find.textContaining('B (b@x.in)'), findsOneWidget);
      // Never an accusation, never an absence threat.
      expect(find.textContaining(RegExp(r'fraud|cheat|absent')), findsNothing);
      await tester.tap(find.text('Not a duplicate'));
      await tester.pumpAndSettle();
      expect(resolved, 'a@x.in');
      // Optimistic dismiss: the card is gone even before a rebuild.
      expect(find.textContaining('Duplicate face detected between'), findsNothing);
    });

    testWidgets('triple renders once; empty renders nothing', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DupFlagSection(
            groups: {
              'a@x.in': {'b@x.in', 'c@x.in'},
              'b@x.in': {'a@x.in', 'c@x.in'},
              'c@x.in': {'a@x.in', 'b@x.in'},
            },
            names: const {},
            onResolve: (_) async {},
          ),
        ),
      ));
      expect(find.textContaining('Duplicate face detected between'), findsOneWidget);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DupFlagSection(groups: {}, names: {}, onResolve: (_) async {}),
        ),
      ));
      expect(find.textContaining('Duplicate face detected between'), findsNothing);
    });

    test('distinctGroups dedupes symmetric pairs', () {
      expect(
          DupFlagSection.distinctGroups({
            'b@x.in': {'a@x.in'},
            'a@x.in': {'b@x.in'},
            'solo@x.in': <String>{},
          }),
          [
            ['a@x.in', 'b@x.in']
          ]);
    });
  });
}
