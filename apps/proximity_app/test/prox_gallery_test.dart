// Design-system gallery gate: every shared Prox component renders on both
// themes without overflow or missing tokens. Visual regression safety net
// until golden screenshots land.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/mark/browse_banner.dart';
import 'package:proximity_app/widgets/prox_buttons.dart';
import 'package:proximity_app/widgets/prox_fields.dart';
import 'package:proximity_app/widgets/prox_states.dart';
import 'package:proximity_app/widgets/student_card.dart';
import 'package:proximity_app/widgets/verdict_badge.dart';

Widget _app(Widget child, {required bool dark}) => MaterialApp(
      theme: dark ? proxDarkTheme() : proxLightTheme(),
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    );

Widget _gallery() {
  final nameCtrl = TextEditingController(text: 'CS201');
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const ProxPrimaryButton(
        label: Text('Primary'),
        onPressed: null,
      ),
      const ProxSecondaryButton(
        label: Text('Secondary'),
        onPressed: null,
      ),
      const ProxDangerButton(
        label: Text('Danger'),
        onPressed: null,
      ),
      ProxTextField(controller: nameCtrl, labelText: 'Course name'),
      const ProxAvatar(name: 'Ada Lovelace'),
      const VerdictBadge(status: ProxStatus.marked),
      const VerdictBadge(status: ProxStatus.late),
      const VerdictBadge(status: ProxStatus.review),
      const StudentCard(name: 'Ada Lovelace', subtitle: 'ID · mail'),
      const ProxErrorNote('Inline error note'),
      const ProxErrorState(
        headline: 'Unknown route',
        message: 'This link goes nowhere.',
      ),
      BrowseBanner(
        icon: Icons.error_outline,
        text: 'Join failed — try again.',
        onDismiss: () {},
      ),
    ],
  );
}

void main() {
  for (final dark in [false, true]) {
    testWidgets(
        'gallery renders ${dark ? 'dark' : 'light'} without overflow',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(_gallery(), dark: dark));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
