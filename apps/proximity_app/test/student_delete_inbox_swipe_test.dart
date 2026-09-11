// Student course delete + inbox swipe-to-decide (Full-Stack/Mobile UI).
//
// - Student delete is device-only: hiding every session of the course via
//   the existing hidden-session filter (same store call as the per-session
//   hide in the detail screen). No history delete, no tombstone, no cloud
//   push — professor/cloud data untouched. Follows records_rebuild_test's
//   offline-cache harness.
// - Inbox swipes mirror RemovableRosterRow (same Dismissible defaults,
//   wash language, confirmDismiss-returns-bool contract): RIGHT approves
//   via the single-item approve path, LEFT rejects via the single-item
//   reject path, tap-to-select + toolbar keep working, and only the
//   swiped row's selection clears (others preserved per _pruneStale).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/manual_attendance/manual_inbox.dart';
import 'package:proximity_app/features/records/my_attendance_screen.dart';
import 'package:proximity_storage/storage.dart';

const _email = 'student@example.com';

ClassRecord _rec(String id, String course, String date) => ClassRecord(
      id: id,
      courseId: course,
      classLabel: course,
      dateIso: date,
      timestampIso: '${date}T10:00:00.000Z',
      windows: [
        {_email: true}
      ],
      names: const {_email: 'Student One'},
      rolls: const {_email: '10000001'},
    );

ProviderScope _wrap(
        {required InMemoryDeviceStore store,
        required FakeCloudSync cloud,
        required Widget home}) =>
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
            email: _email, displayName: 'Student One', uid: 'u1'))),
        cloudSyncProvider.overrideWithValue(cloud),
        deviceStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(theme: proxLightTheme(), home: home),
    );

/// Stateful inbox harness: callbacks record the decision AND drop the row
/// (mirrors the host driver, where decideManual removes the row from
/// manualPending — a Dismissible that returns true must leave the tree).
class _InboxHarness extends StatefulWidget {
  final List<ManualRow> rows;
  final List<String> approved;
  final List<String> rejected;
  const _InboxHarness(
      {required this.rows, required this.approved, required this.rejected});

  @override
  State<_InboxHarness> createState() => _InboxHarnessState();
}

class _InboxHarnessState extends State<_InboxHarness> {
  @override
  Widget build(BuildContext context) {
    return ManualInboxView(
      pending: List.of(widget.rows),
      onApproveOne: (email) async {
        widget.approved.add(email);
        if (mounted) {
          setState(
              () => widget.rows.removeWhere((m) => m.email == email));
        }
      },
      onRejectOne: (email) async {
        widget.rejected.add(email);
        if (mounted) {
          setState(
              () => widget.rows.removeWhere((m) => m.email == email));
        }
      },
      onDecide: (_, __) async {},
    );
  }
}

Future<void> _pumpInbox(WidgetTester t, _InboxHarness harness) async {
  await t.pumpWidget(MaterialApp(
    theme: proxLightTheme(),
    home: Scaffold(body: harness),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('student delete course (device only)', () {
    testWidgets('confirm removes the course, keeps the other, hides only',
        (t) async {
      final store = InMemoryDeviceStore();
      await store.writeStudentSessions([
        _rec('s1', 'CS201', '2026-09-04'),
        _rec('s2', 'CS201', '2026-09-05'),
        _rec('s3', 'MATH101', '2026-09-06'),
      ]);
      await t.pumpWidget(_wrap(
          store: store,
          cloud: FakeCloudSync(online: false),
          home: const MyAttendanceScreen()));
      await t.pumpAndSettle();
      expect(find.text('CS201'), findsOneWidget);
      expect(find.text('MATH101'), findsOneWidget);
      // Courses sort A–Z, so the first delete affordance is CS201's.
      await t.tap(find.byTooltip('Remove course from this device').first);
      await t.pumpAndSettle();
      expect(
          find.text('Remove CS201 from this device?'), findsOneWidget);
      await t.tap(find.text('Remove'));
      await t.pumpAndSettle();
      // Result snackbar reuses the device-only hide wording.
      expect(
          find.text(
              'Removed CS201 from this device only — class data unchanged.'),
          findsOneWidget);
      // List refreshes: CS201 gone, MATH101 untouched, no empty state.
      expect(find.text('CS201'), findsNothing);
      expect(find.text('MATH101'), findsOneWidget);
      expect(find.textContaining('No synced classes'), findsNothing);
      // Store semantics: hidden filter holds both CS201 ids, MATH101 open;
      // the synced cache is NOT rewritten and no cloud delete is queued.
      final hidden = await store.readHiddenSessions();
      expect(hidden, containsAll(['s1', 's2']));
      expect(hidden, isNot(contains('s3')));
      expect((await store.readStudentSessions()).map((r) => r.id),
          containsAll(['s1', 's2', 's3']));
      expect(await store.readTombstones(), isEmpty);
      expect(await store.readPendingSessions(), isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('cancel keeps the course', (t) async {
      final store = InMemoryDeviceStore();
      await store.writeStudentSessions([
        _rec('s1', 'CS201', '2026-09-04'),
      ]);
      await t.pumpWidget(_wrap(
          store: store,
          cloud: FakeCloudSync(online: false),
          home: const MyAttendanceScreen()));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Remove course from this device').first);
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.text('CS201'), findsOneWidget);
      expect(await store.readHiddenSessions(), isEmpty);
      expect(t.takeException(), isNull);
    });
  });

  group('inbox swipe-to-decide', () {
    testWidgets('swipe RIGHT approves via onApproveOne', (t) async {
      final harness = _InboxHarness(
        rows: const [
          ManualRow(email: 'a@x.in', name: 'A One', roll: '11'),
          ManualRow(email: 'b@x.in', name: 'B Two', roll: '12'),
        ].map((m) => m).toList(),
        approved: [],
        rejected: [],
      );
      await _pumpInbox(t, harness);
      expect(find.text('Manual requests (2)'), findsOneWidget);
      await t.fling(find.text('A One'), const Offset(400, 0), 800);
      await t.pumpAndSettle();
      expect(harness.approved, ['a@x.in']);
      expect(harness.rejected, isEmpty);
      expect(find.text('A One'), findsNothing);
      expect(find.text('B Two'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('swipe LEFT rejects via onRejectOne', (t) async {
      final harness = _InboxHarness(
        rows: const [
          ManualRow(email: 'a@x.in', name: 'A One', roll: '11'),
          ManualRow(email: 'b@x.in', name: 'B Two', roll: '12'),
        ].map((m) => m).toList(),
        approved: [],
        rejected: [],
      );
      await _pumpInbox(t, harness);
      await t.fling(find.text('B Two'), const Offset(-400, 0), 800);
      await t.pumpAndSettle();
      expect(harness.rejected, ['b@x.in']);
      expect(harness.approved, isEmpty);
      expect(find.text('B Two'), findsNothing);
      expect(find.text('A One'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('swipe preserves other rows’ selection (toolbar still works)',
        (t) async {
      final harness = _InboxHarness(
        rows: const [
          ManualRow(email: 'a@x.in', name: 'A One', roll: '11'),
          ManualRow(email: 'b@x.in', name: 'B Two', roll: '12'),
        ].map((m) => m).toList(),
        approved: [],
        rejected: [],
      );
      await _pumpInbox(t, harness);
      // Tap-to-select B first: the bulk toolbar arms.
      await t.tap(find.text('B Two'));
      await t.pumpAndSettle();
      expect(find.text('Approve 1'), findsOneWidget);
      // Swipe A away: B's selection survives, toolbar still offers it.
      await t.fling(find.text('A One'), const Offset(400, 0), 800);
      await t.pumpAndSettle();
      expect(harness.approved, ['a@x.in']);
      expect(find.text('A One'), findsNothing);
      expect(find.text('B Two'), findsOneWidget);
      expect(find.text('Approve 1'), findsOneWidget);
      // The preserved selection still routes through the single-item path.
      await t.tap(find.text('Approve 1'));
      await t.pumpAndSettle();
      expect(harness.approved, contains('b@x.in'));
      expect(find.text('Approve 1'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('swiped row’s own selection clears with it', (t) async {
      final harness = _InboxHarness(
        rows: const [
          ManualRow(email: 'a@x.in', name: 'A One', roll: '11'),
          ManualRow(email: 'b@x.in', name: 'B Two', roll: '12'),
        ].map((m) => m).toList(),
        approved: [],
        rejected: [],
      );
      await _pumpInbox(t, harness);
      await t.tap(find.text('A One'));
      await t.pumpAndSettle();
      expect(find.text('Approve 1'), findsOneWidget);
      await t.fling(find.text('A One'), const Offset(-400, 0), 800);
      await t.pumpAndSettle();
      expect(harness.rejected, ['a@x.in']);
      expect(find.text('A One'), findsNothing);
      // Its selection went with it — no stale toolbar count.
      expect(find.text('Approve 1'), findsNothing);
      expect(find.text('B Two'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
