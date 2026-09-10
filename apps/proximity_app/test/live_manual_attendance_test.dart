// Live-tab rebuild (2026-09-10): manual-attendance module proofs.
//
// - The M3 shim (`widgets/manual_add.dart`) re-exports the module form
//   (identical class object — existing imports keep working).
// - Inbox hold-and-tap: long-press selects, toolbar Approve/Reject routes
//   single → onApproveOne/onRejectOne and bulk → onDecide; Cancel exits.
// - Module form submit paths through the NEW import path: ID-required,
//   offline queue, exact-ID online resolve (mirrors manual_add_test,
//   which covers the same class through the shim).
// - Draft/recovery semantics live on the host untouched (see
//   recover_policy_test.dart + the take-screen draft widget tests).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/live/manual_inbox.dart';
import 'package:proximity_app/features/manual_attendance/manual_attendance.dart'
    as ma;
import 'package:proximity_app/widgets/manual_add.dart' as shim;

Future<FakeCloudSync> _seededCloud() async {
  final cloud = FakeCloudSync();
  await cloud.claimStudentDevice(
      doc: const StudentDeviceDoc(
          email: 'student1@example.com',
          uid: 'u1',
          pkHex: 'aa',
          name: 'Student One',
          roll: '10000001',
          modelVer: 'v'),
      installId: 'i1');
  return cloud;
}

void main() {
  test('M3 shim re-exports the module form (identical class)', () {
    expect(identical(shim.ManualAddForm, ma.ManualAddForm), isTrue);
  });

  testWidgets('inbox hold-and-tap: single approve routes to onApproveOne',
      (t) async {
    final approved = <String>[];
    await t.pumpWidget(MaterialApp(
      // App theme: module widgets read the ProximityColors extension.
      theme: proxLightTheme(),
      home: Scaffold(
        body: ManualInboxSection(
          pending: const [
            ManualRow(email: 'a@x.in', name: 'A One', roll: '11'),
            ManualRow(email: 'b@x.in', name: 'B Two', roll: '12'),
          ],
          onApproveOne: (e) async => approved.add(e),
          onRejectOne: (_) async {},
          onDecide: (_, __) async {},
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('Manual requests (2)'), findsOneWidget);
    expect(find.text('Approve 1'), findsNothing);
    await t.longPress(find.text('A One'));
    await t.pumpAndSettle();
    expect(find.text('Approve 1'), findsOneWidget);
    await t.tap(find.text('Approve 1'));
    await t.pumpAndSettle();
    expect(approved, ['a@x.in']);
    expect(find.text('Approve 1'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('inbox hold-and-tap: bulk reject routes to onDecide',
      (t) async {
    var decided = (emails: <String>[], approve: true);
    await t.pumpWidget(MaterialApp(
      // App theme: module widgets read the ProximityColors extension.
      theme: proxLightTheme(),
      home: Scaffold(
        body: ManualInboxSection(
          pending: const [
            ManualRow(email: 'a@x.in', name: 'A One', roll: '11'),
            ManualRow(email: 'b@x.in', name: 'B Two', roll: '12'),
          ],
          onApproveOne: (_) async {},
          onRejectOne: (_) async {},
          onDecide: (emails, approve) async {
            decided = (emails: emails, approve: approve);
          },
        ),
      ),
    ));
    await t.pumpAndSettle();
    await t.longPress(find.text('A One'));
    await t.pumpAndSettle();
    await t.tap(find.text('Select all'));
    await t.pumpAndSettle();
    expect(find.text('Reject 2'), findsOneWidget);
    await t.tap(find.text('Reject 2'));
    await t.pumpAndSettle();
    expect(decided.approve, isFalse);
    expect(decided.emails.toSet(), {'a@x.in', 'b@x.in'});
    expect(find.text('Reject 2'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('inbox hold-and-tap: Cancel exits selection mode',
      (t) async {
    await t.pumpWidget(MaterialApp(
      // App theme: module widgets read the ProximityColors extension.
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
    await t.longPress(find.text('A One'));
    await t.pumpAndSettle();
    expect(find.text('Approve 1'), findsOneWidget);
    await t.tap(find.byTooltip('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('Approve 1'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('module form: ID is compulsory', (t) async {
    await t.pumpWidget(ProviderScope(
      overrides: [
        cloudSyncProvider.overrideWithValue(FakeCloudSync()),
        deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
      ],
      child: MaterialApp(
        // App theme: module widgets read the ProximityColors extension.
        theme: proxLightTheme(),
        home: Scaffold(
          body: ma.ManualAddForm(
            fieldPrefix: 'm',
            course: 'CS201',
            sessionId: 's1',
            onAdd: ({required String name,
                required String roll,
                required String email}) async {},
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    await t.tap(find.text('Add & mark present'));
    await t.pumpAndSettle();
    expect(find.text('ID Number is required.'), findsOneWidget);
  });

  testWidgets('module form: ID-only queues while offline', (t) async {
    final store = InMemoryDeviceStore();
    String? added;
    await t.pumpWidget(ProviderScope(
      overrides: [
        cloudSyncProvider
            .overrideWithValue(FakeCloudSync(online: false)),
        deviceStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        // App theme: module widgets read the ProximityColors extension.
        theme: proxLightTheme(),
        home: Scaffold(
          body: ma.ManualAddForm(
            fieldPrefix: 'm',
            course: 'CS201',
            sessionId: 's1',
            onAdd: ({required String name,
                required String roll,
                required String email}) async {
              added = '$name|$roll|$email';
            },
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('m-roll')), '10000001');
    await t.tap(find.text('Add & mark present'));
    await t.pumpAndSettle();
    expect(added, isNull);
    expect(find.textContaining('queued'), findsOneWidget);
    expect((await store.readPendingAdds()).first['roll'], '10000001');
  });

  testWidgets('module form: ID-only resolves online', (t) async {
    final cloud = await _seededCloud();
    final store = InMemoryDeviceStore();
    String? added;
    await t.pumpWidget(ProviderScope(
      overrides: [
        cloudSyncProvider.overrideWithValue(cloud),
        deviceStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        // App theme: module widgets read the ProximityColors extension.
        theme: proxLightTheme(),
        home: Scaffold(
          body: ma.ManualAddForm(
            fieldPrefix: 'm',
            course: 'CS201',
            sessionId: 's1',
            onAdd: ({required String name,
                required String roll,
                required String email}) async {
              added = '$name|$roll|$email';
            },
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('m-roll')), '10000001');
    await t.tap(find.text('Add & mark present'));
    await t.pumpAndSettle();
    expect(added, 'Student One|10000001|student1@example.com');
    expect(await store.readPendingAdds(), isEmpty);
  });
}
