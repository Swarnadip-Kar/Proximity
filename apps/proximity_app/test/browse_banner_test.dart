// Browse discovery-honesty widget test (Track 4 §2): enterprise-AP shape
// (UDP dead, BLE hints listing) says so aloud + helpful join instructions
// live behind the Details expander (collapsed by default).
// Split from offline_live_test: testWidgets installs the mock-HTTP binding,
// which would break that file's real-loopback live tests.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/mark/browse_classes.dart';

// Rebuilt browse reads the `ProximityColors` extension.
Widget _themed(Widget body) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: body),
    );

Widget _browse({bool broadcastBlocked = false}) => _themed(
      BrowseClassesView(
        avatarName: 'S',
        ipInitial: '',
        onIpChanged: (_) {},
        onJoin: () {},
        joinError: '',
        live: const [],
        onTapLive: (_) {},
        onRefresh: () async {},
        broadcastBlocked: broadcastBlocked,
      ),
    );

void main() {
  testWidgets('broadcast-blocked banner + ladder status on browse',
      (t) async {
    await t.pumpWidget(_browse(broadcastBlocked: true));
    expect(find.textContaining('blocks discovery broadcasts'), findsOneWidget);
    // Helpful instructions behind Details (§4.7 — AnimatedCrossFade keeps
    // the collapsed child in the tree, so expand to read it).
    await t.tap(find.text('Details'));
    await t.pumpAndSettle();
    expect(find.textContaining('same network as your professor'),
        findsOneWidget);
  });

  testWidgets('no banner when beacons flow', (t) async {
    await t.pumpWidget(_browse());
    await t.pumpAndSettle();
    expect(find.textContaining('blocks discovery broadcasts'), findsNothing);
    await t.tap(find.text('Details'));
    await t.pumpAndSettle();
    expect(find.textContaining('same network as your professor'),
        findsOneWidget);
  });
}
