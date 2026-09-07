import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_storage/storage.dart';

void main() {
  test('enrollment roundtrip', () async {
    final store = InMemoryDeviceStore();
    expect(await store.readEnrollment(), isNull);
    final e = StoredEnrollment(
      email: 'a@x.in',
      name: 'A',
      roll: '1',
      seedHex: 'ab' * 32,
      pkHex: 'cd' * 32,
      sealedKeyHex: 'deadbeef',
      faceId: 'face-1',
      enrolledAt: DateTime.utc(2026, 1, 1),
      verifierVer: 'face_verification/0.3.9+b45ab893',
      org: 'x.in',
      pkDHex: 'ee' * 32,
      attestationLevel: 'FULL',
      attestedAt: DateTime.utc(2026, 1, 1),
      attestedUntil: DateTime.utc(2026, 4, 1),
    );
    await store.writeEnrollment(e);
    final back = (await store.readEnrollment())!;
    expect(back.email, 'a@x.in');
    expect(back.faceId, 'face-1');
    expect(back.verifierVer, 'face_verification/0.3.9+b45ab893');
    expect(back.isFaceStale('face_verification/0.3.9+b45ab893'), isFalse);
    expect(back.isFaceStale('face_verification/0.4.0+deadbeef'), isTrue);
    expect(back.pkDHex, 'ee' * 32);
    await store.clearEnrollment();
    expect(await store.readEnrollment(), isNull);
  });

  test('legacy template enrollment migrates to stale (key kept)', () async {
    // Pre-plugin docs carried templateCsv/modelVer (deleted): they load
    // as faceId '' so the stale check forces re-face, key kept.
    final legacy = StoredEnrollment.fromJson({
      'email': 'a@x.in',
      'name': 'A',
      'roll': '1',
      'seedHex': 'ab' * 32,
      'pkHex': 'cd' * 32,
      'templateCsv': '1.0,0.0',
      'enrolledAt': '2026-01-01T00:00:00.000Z',
      'modelVer': 'edgeface-xs-g06-tflite-alignfix1',
    });
    expect(legacy.faceId, isEmpty);
    expect(
        legacy.isFaceStale('face_verification/0.3.9+b45ab893'), isTrue);
    expect(legacy.seedHex, 'ab' * 32); // key survives
    // New docs never write the legacy keys.
    expect(
        StoredEnrollment(
          email: 'a@x.in',
          name: 'A',
          roll: '1',
          seedHex: 'ab' * 32,
          pkHex: 'cd' * 32,
          faceId: 'f',
          enrolledAt: DateTime.utc(2026, 1, 1),
          verifierVer: 'v',
        ).toJson().containsKey('templateCsv'),
        isFalse);
  });

  test('history roundtrip + CSV export', () async {    final store = InMemoryDeviceStore();
    expect(await store.readHistory(), isEmpty);
    await store.appendHistory(ClassRecord(
      classLabel: 'CS201',
      dateIso: '2026-09-04',
      w1: {'a@x.in': true},
      w2: {'a@x.in': true},
      names: {'a@x.in': 'A'},
      rolls: {'a@x.in': '1'},
    ));
    final h = await store.readHistory();
    expect(h.length, 1);
    expect(h.first.w1Count, 1);
    expect(h.first.toCsv(), contains('Name,ID Number,Email,Status'));
    expect(h.first.toCsv(), contains('A,1,a@x.in,Present'));
  });

  test('upsertHistory rewrites the same record id', () async {
    final store = InMemoryDeviceStore();
    await store.upsertHistory(ClassRecord(
      id: 'live-CS201-1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-05',
      windows: [
        {'a@x.in': true}
      ],
      names: {'a@x.in': 'A'},
    ));
    // Later round, same id: update in place, never a duplicate row.
    await store.upsertHistory(ClassRecord(
      id: 'live-CS201-1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-05',
      windows: [
        {'a@x.in': true},
        {'a@x.in': true, 'b@x.in': true}
      ],
      names: {'a@x.in': 'A', 'b@x.in': 'B'},
    ));
    final h = await store.readHistory();
    expect(h, hasLength(1));
    expect(h.first.windowCount, 2);
    expect(h.first.allEmails, {'a@x.in', 'b@x.in'});
    // A different id still appends.
    await store.upsertHistory(ClassRecord(
      id: 'other',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-06',
      windows: [
        {'c@x.in': true}
      ],
      names: {'c@x.in': 'C'},
    ));
    expect(await store.readHistory(), hasLength(2));
  });

  test('single-window intersection + date-range matrix + deletion stats',
      () async {
    final s1 = ClassRecord(
      id: 's1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-03',
      timestampIso: '2026-09-03T10:00:00.000Z',
      windows: [
        {'a@x.in': true, 'b@x.in': true}
      ],
      names: {'a@x.in': 'A', 'b@x.in': 'B'},
      rolls: {'a@x.in': '1', 'b@x.in': '2'},
    );
    final s2 = ClassRecord(
      id: 's2',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-04',
      timestampIso: '2026-09-04T10:00:00.000Z',
      windows: [
        {'a@x.in': true, 'b@x.in': false}
      ],
      names: {'a@x.in': 'A', 'b@x.in': 'B'},
      rolls: {'a@x.in': '1', 'b@x.in': '2'},
    );
    expect(s1.isPresent('a@x.in'), isTrue);
    final multi = ClassRecord(
      id: 'm',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-05',
      timestampIso: '2026-09-05T10:00:00.000Z',
      windows: [
        {'a@x.in': true, 'b@x.in': true},
        {'a@x.in': true, 'b@x.in': false},
      ],
      names: {'a@x.in': 'A', 'b@x.in': 'B'},
      rolls: {'a@x.in': '1', 'b@x.in': '2'},
    );
    expect(multi.isPresent('a@x.in'), isTrue);
    expect(multi.isPresent('b@x.in'), isFalse);
    final matrix = buildDateRangeMatrix([s1, s2]);
    expect(matrix, contains('Name,ID Number,Email,2026-09-03,2026-09-04'));
    expect(matrix, contains('A,1,a@x.in,P,P'));
    expect(matrix, contains('B,2,b@x.in,P,A'));
    expect(sessionsInRange([s1, s2], '2026-09-04', '2026-09-04'), hasLength(1));
    expect(sessionsInRange([s1, s2], '2026-09-10', '2026-09-11'), isEmpty);
    final stats = deletionStats([s1, s2]);
    expect(stats.sessions, 2);
    expect(stats.students, 2);
  });

  test('delete sessions + delete course', () async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await store.appendHistory(ClassRecord(
      id: 'd1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-03',
      windows: [
        {'a@x.in': true}
      ],
      names: {'a@x.in': 'A'},
      rolls: {'a@x.in': '1'},
    ));
    await store.appendHistory(ClassRecord(
      id: 'd2',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-04',
      windows: [
        {'b@x.in': true}
      ],
      names: {'b@x.in': 'B'},
      rolls: {'b@x.in': '2'},
    ));
    expect(await store.deleteSessions(['d1']), 1);
    expect((await store.readHistory()).length, 1);
    final removed = await store.deleteCourse('CS201');
    expect(removed.$2, 1);
    expect(await store.readHistory(), isEmpty);
  });

  test('class catalog dedups + trims', () async {
    final store = InMemoryDeviceStore();
    expect(await store.readCatalog(), isEmpty);
    await store.addClass('  ');
    await store.addClass('CS201-Room301');
    await store.addClass('CS201-Room301');
    await store.addClass('CS202-Room302');
    expect(await store.readCatalog(),
        ['CS201-Room301', 'CS202-Room302']);
  });

  test('rename course migrates sessions', () async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await store.appendHistory(ClassRecord(
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-03',
      timestampIso: '2026-09-03T10:00:00.000Z',
      startIso: '2026-09-03T09:00:00.000Z',
      w1: const {},
      w2: const {},
      names: const {},
      rolls: const {},
    ));
    expect(await store.renameCourse('CS201', 'CS201-A'), isTrue);
    expect(
        (await store.readCourses()).map((c) => c.name), ['CS201-A']);
    final h = await store.readHistory();
    expect(h.single.courseId, 'CS201-A');
    expect(h.single.classLabel, 'CS201-A');
    // Class-start time survives the rename migration.
    expect(h.single.startIso, '2026-09-03T09:00:00.000Z');
    expect(await store.renameCourse('CS201-A', 'CS201-A'), isFalse);
    expect(await store.renameCourse('CS201-A', '  '), isFalse);
    expect(await store.renameCourse('Missing', 'X'), isFalse);
  });

  test('student sessions cache round-trips (offline My Attendance)', () async {
    final store = InMemoryDeviceStore();
    expect(await store.readStudentSessions(), isEmpty);
    final recs = [
      ClassRecord(
        id: 's1',
        courseId: 'CS201',
        classLabel: 'CS201',
        dateIso: '2026-09-06',
        timestampIso: '2026-09-06T10:00:00.000Z',
        startIso: '2026-09-06T09:00:00.000Z',
        windows: const [
          {'a@x.in': true}
        ],
        names: const {'a@x.in': 'A'},
        rolls: const {'a@x.in': '1'},
      ),
    ];
    await store.writeStudentSessions(recs);
    final back = await store.readStudentSessions();
    expect(back.map((r) => r.id), ['s1']);
    expect(back.single.courseId, 'CS201');
    expect(back.single.startIso, '2026-09-06T09:00:00.000Z');
    expect(back.single.isPresent('a@x.in'), isTrue);
    // Wholesale replace on every pull.
    await store.writeStudentSessions([]);
    expect(await store.readStudentSessions(), isEmpty);
  });

  test('session draft roundtrip + clear', () async {
    final store = InMemoryDeviceStore();
    expect(await store.readSession('CS201'), isNull);
    await store.writeSession('CS201', {
      'windowNo': 1,
      'dateIso': '2026-09-04',
      'savedAt': '2026-09-04T10:00:00.000Z',
      'names': {'a@x.in': 'A'},
      'rolls': {'a@x.in': '1'},
      'windows': [
        {'a@x.in': true}
      ],
      'windowNos': [1],
    });
    final back = (await store.readSession('CS201'))!;
    expect(back['windowNo'], 1);
    await store.clearSession('CS201');
    expect(await store.readSession('CS201'), isNull);
  });

  test('tally restore rebuilds marks + window numbering', () {
    final tally = TallyStore();
    tally.restore(
      windows: [
        {'a@x.in': true, 'b@x.in': true},
        {'a@x.in': true, 'b@x.in': false},
      ],
      names: {'a@x.in': 'A', 'b@x.in': 'B'},
      rolls: {'a@x.in': '1', 'b@x.in': '2'},
      windowNos: [1, 2],
    );
    expect(tally.windowNos, [1, 2]);
    expect(tally.confirmedCount, 1);
    expect(tally.presentAny.length, 2);
    tally.mark('c@x.in', 'C', 3, roll: '3');
    expect(tally.windowNos, [1, 2, 3]);
  });

  test('host name roundtrip', () async {
    final store = InMemoryDeviceStore();
    expect(await store.readHostName(), '');
    await store.writeHostName(' Prof K ');
    expect(await store.readHostName(), 'Prof K');
  });

  test('install id roundtrip (stable per store)', () async {
    final store = InMemoryDeviceStore();
    expect(await store.readInstallId(), isNull);
    await store.writeInstallId('abc123');
    expect(await store.readInstallId(), 'abc123');
  });

  test('pending manual adds roundtrip', () async {
    final store = InMemoryDeviceStore();
    expect(await store.readPendingAdds(), isEmpty);
    await store.writePendingAdds([
      {
        'course': 'CS201',
        'sessionId': 's1',
        'roll': '10000001',
        'createdAtIso': '2026-09-06T10:00:00.000Z'
      }
    ]);
    final back = await store.readPendingAdds();
    expect(back, hasLength(1));
    expect(back.single['roll'], '10000001');
    await store.writePendingAdds([]);
    expect(await store.readPendingAdds(), isEmpty);
  });
}
