// Session-edit sub-tabs (tester-directed layout change).
//
// Edit page is two sub-tabs — Marks (person rows + partial + absent quick
// lists + Save) and Add person (ManualAddForm edit-* + queue behavior,
// unchanged). State-preserving switch via IndexedStack (form input survives
// tab switches); Save stays on Marks; unsaved Add draft is preserved across
// switches (documented in the screen header — Save does NOT consume a
// typed-but-unsent Add draft; tap `Add & mark present` first). Web
// readOnly hides the Add tab exactly as the inline form was hidden.
// No data-logic changes (checkbox correction, tri-state, quick lists,
// monotonic stamps, startIso/org, save semantics all untouched).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/ble_radio.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/records/session_edit_screen.dart';
import 'package:proximity_app/widgets/manual_add.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

ProviderScope _scoped(Widget home, {InMemoryDeviceStore? store}) =>
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(FakeAuthService(SignedAccount(
            email: 'p@x.in', displayName: 'Prof', uid: 'u9'))),
        cloudSyncProvider.overrideWithValue(FakeCloudSync(online: false)),
        deviceStoreProvider.overrideWithValue(store ?? InMemoryDeviceStore()),
        faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
        deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
        hostDriverProvider.overrideWithValue(FakeHostDriver()),
        studentDriverProvider.overrideWithValue(FakeStudentDriver()),
        bleEngineProvider
            .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        cameraPermissionProvider.overrideWithValue(() async => true),
        btPowerProvider.overrideWithValue(() async => BtState.on),
      ],
      child: MaterialApp(theme: proxLightTheme(), home: home),
    );

ClassRecord _rec({
  String id = 'sess-1',
  List<Map<String, bool>>? windows,
  Map<String, String>? names,
  Map<String, String>? rolls,
}) =>
    ClassRecord(
      id: id,
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-05',
      timestampIso: '2026-09-05T10:00:00.000Z',
      startIso: '2026-09-05T10:00:00.000Z',
      windows: windows ?? [
        {'a@x.in': true},
        {'a@x.in': false},
      ],
      names: names ?? const {'a@x.in': 'A'},
      rolls: rolls ?? const {'a@x.in': '1'},
    );

void main() {
  testWidgets('two tabs render correct content; Marks default', (t) async {
    final record = _rec();
    await t.pumpWidget(_scoped(
        SessionEditScreen(record: record, courseSessions: [record])));
    await t.pumpAndSettle();
    // Sub-nav present with both labels.
    expect(find.text('Marks'), findsOneWidget);
    expect(find.text('Add person'), findsOneWidget);
    expect(find.byType(IndexedStack), findsOneWidget);
    // State-preserving mount: the Add form stays in the tree offstage.
    expect(find.byType(ManualAddForm, skipOffstage: false), findsOneWidget);
    // Default = Marks: person rows + partial + Save visible; Add form
    // offstage (default finders skip offstage). `A` is both the person
    // row and the partial-card name.
    expect(find.text('A'), findsWidgets);
    expect(find.text('Partial in this session (1)'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-roll')), findsNothing);
    expect(find.text('Add & mark present'), findsNothing);

    // Add tab: form visible, Marks content hidden.
    await t.tap(find.text('Add person'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-roll')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-email')), findsOneWidget);
    expect(find.text('Add & mark present'), findsOneWidget);
    expect(find.text('Partial in this session (1)'), findsNothing);
    expect(find.text('Save changes'), findsNothing);
    expect(find.text('A'), findsNothing);

    // Back to Marks: rows + Save return.
    await t.tap(find.text('Marks'));
    await t.pumpAndSettle();
    expect(find.text('A'), findsWidgets);
    expect(find.text('Save changes'), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-roll')), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('Add draft survives tab switches (no silent loss)', (t) async {
    final record = _rec();
    await t.pumpWidget(_scoped(
        SessionEditScreen(record: record, courseSessions: [record])));
    await t.pumpAndSettle();
    await t.tap(find.text('Add person'));
    await t.pumpAndSettle();
    await t.enterText(
        find.byKey(const ValueKey('edit-name')), 'Unsent Person');
    await t.enterText(find.byKey(const ValueKey('edit-roll')), '99');
    await t.enterText(
        find.byKey(const ValueKey('edit-email')), 'unsent@x.in');
    await t.pump();
    // Switch away and back — typed but unsent input is preserved.
    await t.tap(find.text('Marks'));
    await t.pumpAndSettle();
    await t.tap(find.text('Add person'));
    await t.pumpAndSettle();
    String field(String k) =>
        t.widget<TextField>(find.byKey(ValueKey(k))).controller!.text;
    expect(field('edit-name'), 'Unsent Person');
    expect(field('edit-roll'), '99');
    expect(field('edit-email'), 'unsent@x.in');
    expect(t.takeException(), isNull);
  });

  testWidgets('save path unchanged: Add on Add tab, Save on Marks',
      (t) async {
    final store = InMemoryDeviceStore();
    final record = _rec();
    await store.upsertHistory(record);
    await t.pumpWidget(_scoped(
        SessionEditScreen(record: record, courseSessions: [record]),
        store: store));
    await t.pumpAndSettle();
    // Add B via the Add tab (full details add at once, offline-safe).
    await t.tap(find.text('Add person'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('edit-name')), 'B');
    await t.enterText(find.byKey(const ValueKey('edit-roll')), '2');
    await t.enterText(find.byKey(const ValueKey('edit-email')), 'b@x.in');
    await t.pump();
    await t.tap(find.text('Add & mark present'));
    await t.pumpAndSettle();
    // Save lives on Marks only.
    await t.tap(find.text('Marks'));
    await t.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Save changes'), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Save changes'));
    await t.pumpAndSettle();
    final back =
        (await store.readHistory()).firstWhere((r) => r.id == 'sess-1');
    expect(back.isPresent('b@x.in'), isTrue);
    // startIso preserved, id stable (save semantics unchanged).
    expect(back.startIso, record.startIso);
    expect(back.id, 'sess-1');
    expect(t.takeException(), isNull);
  });

  testWidgets('readOnly parity: Add tab hidden like the inline form was',
      (t) async {
    final record = _rec();
    await t.pumpWidget(_scoped(SessionEditScreen(
        record: record, courseSessions: [record], readOnly: true)));
    await t.pumpAndSettle();
    // No sub-nav, no Add UI, no Save — exactly the old inline parity.
    expect(find.text('Marks'), findsNothing);
    expect(find.text('Add person'), findsNothing);
    expect(find.byType(IndexedStack), findsNothing);
    expect(find.byType(ManualAddForm), findsNothing);
    expect(find.byKey(const ValueKey('edit-roll')), findsNothing);
    expect(find.byKey(const ValueKey('edit-name')), findsNothing);
    expect(find.byKey(const ValueKey('edit-email')), findsNothing);
    expect(find.text('Add & mark present'), findsNothing);
    expect(find.text('Save changes'), findsNothing);
    // Marks content still reads (rows + partial, view-only). `A` appears
    // both as the person row and in the partial card.
    expect(find.text('A'), findsWidgets);
    expect(find.text('Partial in this session (1)'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('absent quick list stays on Marks, not on Add', (t) async {
    final s1 = ClassRecord(
      id: 's1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-04',
      timestampIso: '2026-09-04T10:00:00.000Z',
      windows: [
        {'gone@example.com': true}
      ],
      names: const {'gone@example.com': 'Gone Student'},
      rolls: const {'gone@example.com': '10000009'},
    );
    final s2 = _rec(id: 's2');
    await t.pumpWidget(
        _scoped(SessionEditScreen(record: s2, courseSessions: [s1, s2])));
    await t.pumpAndSettle();
    expect(find.text('Absent (1)'), findsOneWidget);
    await t.tap(find.text('Add person'));
    await t.pumpAndSettle();
    expect(find.text('Absent (1)'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
