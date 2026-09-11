// CSV preview dialog: every action reliably closes the popup.
//
// Regression: Close used the caller's context for its pop, so exiting
// stranded the route (null-check crash, taps ignored). All three actions
// now pop via the dialog-local context; Save/Share close FIRST so their
// feedback lands on the visible screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/widgets/csv_preview.dart';

Future<void> _open(
  WidgetTester t, {
  required Future<void> Function() onSave,
  required Future<void> Function() onShare,
}) async {
  await t.pumpWidget(MaterialApp(
    theme: proxLightTheme(),
    home: Builder(builder: (context) {
      return Scaffold(
        body: TextButton(
          onPressed: () => showCsvPreviewDialog(
            context,
            title: 'preview.csv',
            csv: 'a,b\n1,2\n',
            onSave: onSave,
            onShare: onShare,
          ),
          child: const Text('open'),
        ),
      );
    }),
  ));
  await t.pumpAndSettle();
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  expect(find.text('preview.csv'), findsOneWidget);
}

void main() {
  testWidgets('Close dismisses without exception', (t) async {
    await _open(t, onSave: () async {}, onShare: () async {});
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    expect(find.text('preview.csv'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('Save closes then runs the hook', (t) async {
    var saved = 0;
    await _open(
        t, onSave: () async => saved++, onShare: () async {});
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.text('preview.csv'), findsNothing);
    expect(saved, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('Share closes then runs the hook', (t) async {
    var shared = 0;
    await _open(
        t, onSave: () async {}, onShare: () async => shared++);
    await t.tap(find.text('Share'));
    await t.pumpAndSettle();
    expect(find.text('preview.csv'), findsNothing);
    expect(shared, 1);
    expect(t.takeException(), isNull);
  });
}
