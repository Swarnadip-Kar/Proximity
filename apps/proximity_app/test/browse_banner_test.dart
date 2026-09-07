// Browse discovery-honesty widget test (Track 4 §2): enterprise-AP shape
// (UDP dead, BLE hints listing) says so aloud + the ladder is one line.
// Split from offline_live_test: testWidgets installs the mock-HTTP binding,
// which would break that file's real-loopback live tests.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/mark/browse_classes.dart';

void main() {
  testWidgets('broadcast-blocked banner + ladder status on browse',
      (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BrowseClassesView(
          linked: null,
          identityLine: 'S',
          ipFieldKey: UniqueKey(),
          ipInitial: '',
          onIpChanged: (_) {},
          onJoin: () {},
          joinError: '',
          live: const [],
          onTapLive: (_) {},
          onEnroll: () {},
          onViewRecords: () {},
          onRefresh: () async {},
          broadcastBlocked: true,
        ),
      ),
    ));
    expect(find.textContaining('blocks discovery broadcasts'), findsOneWidget);
    expect(find.textContaining('Path:'), findsOneWidget);
  });

  testWidgets('no banner when beacons flow', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BrowseClassesView(
          linked: null,
          identityLine: 'S',
          ipFieldKey: UniqueKey(),
          ipInitial: '',
          onIpChanged: (_) {},
          onJoin: () {},
          joinError: '',
          live: const [],
          onTapLive: (_) {},
          onEnroll: () {},
          onViewRecords: () {},
          onRefresh: () async {},
        ),
      ),
    ));
    expect(find.textContaining('blocks discovery broadcasts'), findsNothing);
    expect(find.textContaining('Path:'), findsOneWidget);
  });
}
