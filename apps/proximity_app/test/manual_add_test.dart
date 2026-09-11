import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/manual_attendance/manual_attendance.dart';
import 'package:proximity_storage/storage.dart';

Future<FakeCloudSync> seededCloud() async {
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
  test('PendingManualAdd json round-trip', () {
    const p = PendingManualAdd(
        course: 'CS201',
        sessionId: 's1',
        roll: '10000001',
        createdAtIso: '2026-09-06T10:00:00.000Z');
    final back = PendingManualAdd.fromJson(p.toJson());
    expect(back.course, 'CS201');
    expect(back.sessionId, 's1');
    expect(back.roll, '10000001');
  });

  test('processPendingAdds resolves queued IDs into history', () async {
    final cloud = await seededCloud();
    final store = InMemoryDeviceStore();
    await store.upsertHistory(ClassRecord(
      id: 's1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-06',
      timestampIso: '2026-09-06T10:00:00.000Z',
      windows: [
        {'other@example.com': true}
      ],
      names: const {'other@example.com': 'Other'},
    ));
    await store.writePendingAdds([
      const PendingManualAdd(
              course: 'CS201',
              sessionId: 's1',
              roll: '10000001',
              createdAtIso: '2026-09-06T10:00:00.000Z')
          .toJson(),
    ]);
    final res = await processPendingAdds(store: store, cloud: cloud);
    expect(res.resolvedIds, ['s1']);
    expect(res.remaining, 0);
    final back =
        (await store.readHistory()).firstWhere((r) => r.id == 's1');
    expect(back.isPresent('student1@example.com'), isTrue);
    expect(back.names['student1@example.com'], 'Student One');
    expect(await store.readPendingAdds(), isEmpty);
  });

  test('processPendingAdds keeps unknown rolls and works offline', () async {
    final cloud = await seededCloud();
    final store = InMemoryDeviceStore();
    await store.upsertHistory(ClassRecord(
      id: 's1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-06',
      timestampIso: '2026-09-06T10:00:00.000Z',
      windows: [
        {'other@example.com': true}
      ],
    ));
    Map<String, dynamic> item(String roll) => PendingManualAdd(
            course: 'CS201',
            sessionId: 's1',
            roll: roll,
            createdAtIso: '2026-09-06T10:00:00.000Z')
        .toJson();
    await store.writePendingAdds([item('99999999')]);
    expect((await processPendingAdds(store: store, cloud: cloud)).remaining, 1);
    // Offline: nothing resolves, nothing drops.
    await store.writePendingAdds([item('10000001')]);
    cloud.online = false;
    expect((await processPendingAdds(store: store, cloud: cloud)).remaining, 1);
    cloud.online = true;
    // Live draft open for the course: waits instead of racing the tally.
    await store.writeSession('CS201', {'windowNo': 1});
    expect((await processPendingAdds(store: store, cloud: cloud)).remaining, 1);
    await store.clearSession('CS201');
    expect((await processPendingAdds(store: store, cloud: cloud)).resolvedIds, ['s1']);
  });

  testWidgets('ManualAddForm queues ID-only adds while offline', (t) async {
    final store = InMemoryDeviceStore();
    String? added;
    await t.pumpWidget(ProviderScope(
      overrides: [
        cloudSyncProvider
            .overrideWithValue(FakeCloudSync(online: false)),
        deviceStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        // App theme: the module form reads the ProximityColors extension
        // (Live rebuild; same harness as the shared-components tests).
        theme: proxLightTheme(),
        home: Scaffold(
          body: ManualAddForm(
            fieldPrefix: 't',
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
    await t.enterText(find.byKey(const ValueKey('t-roll')), '10000001');
    await t.tap(find.text('Add & mark present'));
    await t.pumpAndSettle();
    expect(added, isNull);
    expect(find.textContaining('queued'), findsOneWidget);
    final queued = await store.readPendingAdds();
    expect(queued, hasLength(1));
    expect(queued.first['roll'], '10000001');
  });

  testWidgets('ManualAddForm resolves ID online without tapping a card',
      (t) async {
    final cloud = await seededCloud();
    final store = InMemoryDeviceStore();
    String? added;
    await t.pumpWidget(ProviderScope(
      overrides: [
        cloudSyncProvider.overrideWithValue(cloud),
        deviceStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        // App theme: the module form reads the ProximityColors extension
        // (Live rebuild; same harness as the shared-components tests).
        theme: proxLightTheme(),
        home: Scaffold(
          body: ManualAddForm(
            fieldPrefix: 't',
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
    // No card tapped: ID alone resolves through the directory.
    await t.enterText(find.byKey(const ValueKey('t-roll')), '10000001');
    await t.tap(find.text('Add & mark present'));
    await t.pumpAndSettle();
    expect(added, 'Student One|10000001|student1@example.com');
    expect(await store.readPendingAdds(), isEmpty);
  });

  testWidgets('ManualAddForm recovers after a failed add', (t) async {    final store = InMemoryDeviceStore();
    var calls = 0;
    String? added;
    await t.pumpWidget(ProviderScope(
      overrides: [
        cloudSyncProvider.overrideWithValue(FakeCloudSync()),
        deviceStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        // App theme: the module form reads the ProximityColors extension
        // (Live rebuild; same harness as the shared-components tests).
        theme: proxLightTheme(),
        home: Scaffold(
          body: ManualAddForm(
            fieldPrefix: 't',
            course: 'CS201',
            sessionId: 's1',
            onAdd: ({required String name,
                required String roll,
                required String email}) async {
              calls++;
              if (calls == 1) throw StateError('driver down');
              added = '$name|$roll|$email';
            },
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('t-roll')), '10000001');
    await t.enterText(find.byKey(const ValueKey('t-name')), 'Student One');
    await t.enterText(
        find.byKey(const ValueKey('t-email')), 'student1@example.com');
    await t.tap(find.text('Add & mark present'));
    await t.pumpAndSettle();
    expect(find.text('driver down'), findsOneWidget);
    // The form is idle again: retrying works.
    await t.tap(find.text('Add & mark present'));
    await t.pumpAndSettle();
    expect(added, 'Student One|10000001|student1@example.com');
  });

  testWidgets('ManualAddForm shows Already marked present, never re-adds',
      (t) async {
    final cloud = await seededCloud();
    final store = InMemoryDeviceStore();
    var added = 0;
    await t.pumpWidget(ProviderScope(
      overrides: [
        cloudSyncProvider.overrideWithValue(cloud),
        deviceStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        // App theme: the module form reads the ProximityColors extension
        // (Live rebuild; same harness as the shared-components tests).
        theme: proxLightTheme(),
        home: Scaffold(
          body: ManualAddForm(
            fieldPrefix: 't',
            course: 'CS201',
            sessionId: 's1',
            onAdd: ({required String name,
                required String roll,
                required String email}) async {
              added++;
            },
            isPresent: (email) => email == 'student1@example.com',
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    // Card tap on a present student notes instead of filling/adding.
    await t.enterText(find.byKey(const ValueKey('t-roll')), '10000001');
    await t.pump(const Duration(milliseconds: 500));
    await t.pumpAndSettle();
    expect(find.text('Student One'), findsOneWidget);
    await t.tap(find.text('Student One'));
    await t.pumpAndSettle();
    expect(find.text('Already marked present.'), findsOneWidget);
    expect(added, 0);
    // Typed submit for the same student notes instead of adding.
    await t.enterText(find.byKey(const ValueKey('t-name')), 'Student One');
    await t.enterText(
        find.byKey(const ValueKey('t-email')), 'student1@example.com');
    await t.tap(find.text('Add & mark present'));
    await t.pumpAndSettle();
    expect(find.text('Already marked present.'), findsOneWidget);
    expect(added, 0);
  });

  testWidgets('ManualAddForm surfaces directory search failures', (t) async {
    await t.pumpWidget(ProviderScope(
      overrides: [
        cloudSyncProvider.overrideWithValue(_ThrowingCloud()),
        deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
      ],
      child: MaterialApp(
        // App theme: the module form reads the ProximityColors extension
        // (Live rebuild; same harness as the shared-components tests).
        theme: proxLightTheme(),
        home: Scaffold(
          body: ManualAddForm(
            fieldPrefix: 't',
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
    await t.enterText(find.byKey(const ValueKey('t-roll')), '10000001');
    await t.pump(const Duration(milliseconds: 500));
    await t.pumpAndSettle();
    // Denied queries used to vanish silently (no cards, no message).
    expect(find.textContaining('Directory search failed'), findsOneWidget);
  });

  testWidgets('ManualAddForm holds the name query until 2 chars', (t) async {
    final cloud = _RecordingCloud();
    await cloud.claimStudentDevice(
        doc: const StudentDeviceDoc(
            email: 'student1@example.com',
            uid: 'u1',
            pkHex: 'aa',
            name: 'Student One',
            roll: '10000001',
            modelVer: 'v'),
        installId: 'i1');
    await t.pumpWidget(ProviderScope(
      overrides: [
        cloudSyncProvider.overrideWithValue(cloud),
        deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
      ],
      child: MaterialApp(
        // App theme: the module form reads the ProximityColors extension
        // (Live rebuild; same harness as the shared-components tests).
        theme: proxLightTheme(),
        home: Scaffold(
          body: ManualAddForm(
            fieldPrefix: 't',
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
    // One name char: the query still runs (ID/email paths stay live) but
    // the unselective 1-char name prefix is withheld.
    await t.enterText(find.byKey(const ValueKey('t-name')), 'S');
    await t.pump(const Duration(milliseconds: 500)); // past the 400ms debounce
    await t.pumpAndSettle();
    expect(cloud.calls, 1);
    expect(cloud.lastNamePrefix, '');
    // Second char: the name prefix goes out.
    await t.enterText(find.byKey(const ValueKey('t-name')), 'St');
    await t.pump(const Duration(milliseconds: 500));
    await t.pumpAndSettle();
    expect(cloud.calls, 2);
    expect(cloud.lastNamePrefix, 'St');
  });
}

/// FakeCloudSync whose directory search is denied (stale/missing rules
/// deploy, professor role missing): the form must SAY so, never go silent.
class _ThrowingCloud extends FakeCloudSync {
  @override
  Future<List<StudentDirectoryEntry>> searchStudents(
      {String emailPrefix = '',
      String rollPrefix = '',
      String namePrefix = '',
      int limit = 10,
      String org = ''}) async {
    throw StateError(
        'Cloud directory search refused by security rules (permission-denied) — deploy them.');
  }
}

/// FakeCloudSync that records the name prefix each directory search sends.
class _RecordingCloud extends FakeCloudSync {
  int calls = 0;
  String lastNamePrefix = '<unset>';
  @override
  Future<List<StudentDirectoryEntry>> searchStudents(
      {String emailPrefix = '',
      String rollPrefix = '',
      String namePrefix = '',
      int limit = 10,
      String org = ''}) async {
    calls++;
    lastNamePrefix = namePrefix;
    return super.searchStudents(
        emailPrefix: emailPrefix,
        rollPrefix: rollPrefix,
        namePrefix: namePrefix,
        limit: limit,
        org: org);
  }
}
