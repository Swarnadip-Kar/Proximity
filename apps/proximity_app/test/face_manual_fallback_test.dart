// Face-check manual fallback: a failed check never dead-ends.
//
// Contract: `FaceCheckView` shows a quiet "Request manual attendance"
// action only when a failure notice is on screen AND a manual sink is
// provided. Empty notice (at-rest) and missing sink render exactly as
// before (Scan only).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/mark/face_check.dart';

Future<void> _pump(
  WidgetTester t, {
  String notice = '',
  VoidCallback? onManual,
}) async {
  await t.pumpWidget(MaterialApp(
    theme: proxLightTheme(),
    home: Scaffold(
      body: FaceCheckView(
        faceNotice: notice,
        canScan: true,
        onScan: () {},
        onRequestManual: onManual,
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('no manual action at rest (empty notice)', (t) async {
    await _pump(t, onManual: () {});
    expect(find.text('Scan face'), findsOneWidget);
    expect(find.text('Request manual attendance'), findsNothing);
  });

  testWidgets('no manual action without a sink', (t) async {
    await _pump(t, notice: 'Could not read that scan — adjust light.');
    expect(find.text('Scan face'), findsOneWidget);
    expect(find.text('Request manual attendance'), findsNothing);
  });

  testWidgets('failure notice + sink shows manual action and fires',
      (t) async {
    var pressed = 0;
    await _pump(
      t,
      notice: 'Could not read that scan — adjust light and try again.',
      onManual: () => pressed++,
    );
    expect(find.text('Request manual attendance'), findsOneWidget);
    await t.tap(find.text('Request manual attendance'));
    await t.pumpAndSettle();
    expect(pressed, 1);
  });
}
