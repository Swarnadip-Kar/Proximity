// Take-tab single host: live sections are the focused bodies composed by
// TakeAttendanceScreen's sub-nav (roster/inbox/add/setup — one purpose
// each, same host driver). The standalone Live*Screen shells are deleted
// (no deep-link infrastructure — every live/* path resolves to the host);
// cold-section guidance went with them. Mark phases stay one continuation
// (documented in SCREEN_MAP).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/live/direct_add.dart';
import 'package:proximity_app/features/live/live_roster.dart';
import 'package:proximity_app/features/live/live_setup.dart';
import 'package:proximity_app/features/live/manual_inbox.dart';
import 'package:proximity_app/routes.dart';

void main() {
  test('live route resolves to the Take host', () {
    expect(ProxRoutes.live('CS201'), 'live/CS201');
  });

  testWidgets('roster body shows waiting + present without host crash',
      (t) async {
    final driver = FakeHostDriver();
    await t.pumpWidget(ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
        hostDriverProvider.overrideWithValue(driver),
      ],
      // App theme: section bodies read the ProximityColors extension
      // (Live rebuild; same harness as the shared-components tests).
      child: MaterialApp(
        theme: proxLightTheme(),
        home: Scaffold(
          // Scroll like the Take host's Roster sub-tab (same composer,
          // same constraints — the body is taller than the test viewport).
          body: SingleChildScrollView(
            child: LiveRosterBody(
              waitingRows: driver.waitingRows,
              groups: driver.dupGroups,
              names: driver.tally.nameMap(),
              onResolve: (email) => driver.resolveDupFlag(email),
              tally: driver.tally,
              onRemoveStudent: (email) => driver.removeStudent(email),
            ),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('Waiting area'), findsOneWidget);
  });

  testWidgets('inbox/add/setup bodies render their purpose', (t) async {
    final driver = FakeHostDriver();

    await t.pumpWidget(MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(
        body: ManualInboxSection(
          pending: const [
            ManualRow(email: 'a@x.in', name: 'A One', roll: '11'),
          ],
          onApproveOne: (_) async {},
          onRejectOne: (_) async {},
          onDecide: (_, __) async {},
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('Manual requests'), findsOneWidget);
    expect(t.takeException(), isNull);

    await t.pumpWidget(ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
        cloudSyncProvider.overrideWithValue(FakeCloudSync(online: false)),
        hostDriverProvider.overrideWithValue(driver),
      ],
      child: MaterialApp(
        theme: proxLightTheme(),
        home: Scaffold(
          body: DirectAddSection(
            course: 'CS201',
            sessionId: '',
            onAdd: (
                {required String name,
                required String roll,
                required String email}) async {
              await driver.addManualEntry(
                  email: email, name: name, roll: roll);
            },
            isPresent: (email) => driver.tally.confirmed
                .any((r) => r.email == email.toLowerCase()),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('Direct manual entry'), findsOneWidget);
    expect(t.takeException(), isNull);

    final nameCtrl = TextEditingController(text: '');
    addTearDown(nameCtrl.dispose);
    await t.pumpWidget(MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(
        body: LiveSetupSection(
          hosting: false,
          live: false,
          nameCtrl: nameCtrl,
          onNameChanged: (_) {},
          serverLine: null,
          allIps: const [],
          currentIp: '',
          onPickIp: () {},
          serverError: null,
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('Starting host…'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
