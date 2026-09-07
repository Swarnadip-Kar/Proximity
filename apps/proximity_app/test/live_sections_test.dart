// Track 5 split: live/* sections are focused screens (one purpose each)
// reading the same host driver; cold deep-links show guidance, never a
// crash. Mark phases stay one continuation (documented in SCREEN_MAP).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/features/live/live_sections.dart';
import 'package:proximity_app/routes.dart';

void main() {
  test('section routes resolve to focused screens', () {
    expect(ProxRoutes.liveRoster('CS201'), 'live/CS201/roster');
    expect(ProxRoutes.liveInbox('CS201'), 'live/CS201/inbox');
    expect(ProxRoutes.liveAdd('CS201'), 'live/CS201/add');
    expect(ProxRoutes.liveSetup('CS201'), 'live/CS201/setup');
    expect(ProxRoutes.liveRecover('CS201'), 'live/CS201/recover');
  });

  testWidgets('roster section shows waiting + present without host crash',
      (t) async {
    await t.pumpWidget(ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
        hostDriverProvider.overrideWithValue(FakeHostDriver()),
      ],
      child: const MaterialApp(
          home: LiveRosterScreen(course: 'CS201')),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('Roster'), findsWidgets);
    expect(find.textContaining('Waiting area'), findsOneWidget);
  });

  testWidgets('inbox/add/setup render their purpose', (t) async {
    for (final w in [
      const LiveInboxScreen(course: 'CS201'),
      const LiveAddScreen(course: 'CS201'),
      const LiveSetupScreen(course: 'CS201'),
    ]) {
      await t.pumpWidget(ProviderScope(
        overrides: [
          deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
          hostDriverProvider.overrideWithValue(FakeHostDriver()),
        ],
        child: MaterialApp(home: w),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }
    expect(find.textContaining('Setup'), findsWidgets);
  });
}
