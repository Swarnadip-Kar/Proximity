// Tally persistence semantics: opened rounds persist (even empty),
// sparse numbering never merges, names correct, late flags stick.
import 'package:proximity_storage/storage.dart';
import 'package:test/test.dart';

void main() {
  group('TallyStore windows', () {
    test('noted-but-empty rounds persist in windowNos and maps', () {
      final t = TallyStore();
      t.noteWindow(1);
      t.noteWindow(2);
      t.noteWindow(3);
      t.mark('a@x.in', 'A', 1);
      // Round 2 empty, round 3 empty: still counted.
      expect(t.windowNos, [1, 2, 3]);
      expect(t.windowsAsMaps.length, 3);
      expect(t.windowsAsMaps[1], containsPair('a@x.in', false));
      final rec = t.toClassRecord(
          courseId: 'CS201', classLabel: 'CS201', dateIso: '2026-09-06');
      expect(rec.windows.length, 3);
    });

    test('live intersection ignores unopened rounds, counts closed-empty ones',
        () {
      final t = TallyStore();
      t.mark('a@x.in', 'A', 1);
      // Round 2 opened but nobody marked yet (live round): union of
      // opened+marked keeps it visible…
      t.noteWindow(2);
      expect(t.windowNos, [1, 2]);
      // …and the all-windows intersection honestly drops to 0 until
      // someone marks round 2 (present = every round taken).
      expect(t.presentCount, 0);
      t.mark('a@x.in', 'A', 2);
      expect(t.presentCount, 1);
    });

    test('discardWindow drops the round, keeps people, recomputes', () {
      final t = TallyStore();
      t.noteWindow(1);
      t.noteWindow(2);
      t.mark('a@x.in', 'A', 1);
      t.mark('a@x.in', 'A', 2);
      t.mark('b@x.in', 'B', 1);
      t.ensure('w@x.in', 'W');
      t.discardWindow(2);
      expect(t.windowNos, [1]);
      // a and b both confirmed via round 1 now; w (waiting/manual,
      // never marked) survives with empty wins.
      expect(t.presentCount, 2);
      expect(t.nameMap(), contains('w@x.in'));
      expect(t.presentAny.map((r) => r.email), containsAll(['a@x.in', 'b@x.in']));
      // Unknown rounds are a no-op.
      t.discardWindow(9);
      expect(t.windowNos, [1]);
    });

    test('restore preserves sparse window numbers (never renumbers)', () {
      final t = TallyStore();
      t.restore(
        windows: [
          {'a@x.in': true},
          {'a@x.in': true},
          {'a@x.in': false},
        ],
        names: {'a@x.in': 'A'},
        windowNos: [1, 2, 5],
      );
      expect(t.windowNos, [1, 2, 5]);
      expect(t.windowsAsMaps.length, 3);
    });

    test('ensure updates corrected display names, keeps marks', () {
      final t = TallyStore();
      t.mark('a@x.in', 'Student One', 1);
      t.ensure('a@x.in', 'Student One', '12342210');
      expect(t.nameMap()['a@x.in'], 'Student One');
      expect(t.rollMap()['a@x.in'], '12342210');
      expect(t.windowNos, [1]);
      expect(t.presentCount, 1);
    });

    test('late marks persist with the late flag', () {
      final t = TallyStore();
      t.mark('a@x.in', 'A', 1, late: true);
      expect(t.windowNos, [1]);
      expect(t.lateList.map((r) => r.email), contains('a@x.in'));
      expect(t.presentCount, 1);
    });

    test('clear resets opened windows too', () {
      final t = TallyStore();
      t.noteWindow(1);
      t.mark('a@x.in', 'A', 1);
      t.clear();
      expect(t.windowNos, isEmpty);
      expect(t.size, 0);
    });
  });

  group('ClassRecord startIso', () {
    test('explicit start time survives json round-trip', () {
      final r = ClassRecord(
        id: 's1',
        courseId: 'CS201',
        classLabel: 'CS201',
        dateIso: '2026-09-06',
        timestampIso: '2026-09-06T10:00:00.000Z',
        startIso: '2026-09-06T09:00:00.000Z',
        windows: const [
          {'a@x.in': true}
        ],
      );
      final back = ClassRecord.fromJson(r.toJson());
      expect(back.startIso, '2026-09-06T09:00:00.000Z');
      expect(back.timestampIso, '2026-09-06T10:00:00.000Z');
    });

    test('missing startIso falls back to snapshot time (old records)', () {
      final r = ClassRecord(
        classLabel: 'CS201',
        dateIso: '2026-09-06',
        timestampIso: '2026-09-06T10:00:00.000Z',
        windows: const [
          {'a@x.in': true}
        ],
      );
      expect(r.startIso, '2026-09-06T10:00:00.000Z');
      final legacy = ClassRecord.fromJson({
        'id': 's1',
        'courseId': 'CS201',
        'classLabel': 'CS201',
        'dateIso': '2026-09-06',
        'timestampIso': '2026-09-06T10:00:00.000Z',
        'windows': [
          {'a@x.in': true}
        ],
      });
      expect(legacy.startIso, '2026-09-06T10:00:00.000Z');
    });

    test('toClassRecord passes the visit start through', () {
      final t = TallyStore();
      t.mark('a@x.in', 'A', 1);
      final rec = t.toClassRecord(
        courseId: 'CS201',
        classLabel: 'CS201',
        dateIso: '2026-09-06',
        timestampIso: '2026-09-06T10:00:00.000Z',
        startIso: '2026-09-06T09:00:00.000Z',
      );
      expect(rec.startIso, '2026-09-06T09:00:00.000Z');
    });
  });

  group('duplicate-face flags (session-scoped, presence-neutral)', () {
    test('set/clear roundtrip; presence untouched; sorted emails', () {
      final t = TallyStore();
      t.mark('b@x.in', 'B', 1);
      t.mark('a@x.in', 'A', 1);
      expect(t.flaggedEmails, isEmpty);
      t.setFaceFlag('b@x.in');
      t.setFaceFlag('A@X.IN'); // case-insensitive
      expect(t.flaggedEmails, ['a@x.in', 'b@x.in']);
      // Flagged entries stay marked (never auto-absent).
      expect(t.presentCount, 2);
      t.clearFaceFlag('a@x.in');
      expect(t.flaggedEmails, ['b@x.in']);
      // Unknown email: no-op, never throws.
      t.setFaceFlag('ghost@x.in');
      t.clearFaceFlag('ghost@x.in');
      expect(t.flaggedEmails, ['b@x.in']);
    });

    test('toClassRecord carries flags; json roundtrips; legacy omits', () {
      final t = TallyStore();
      t.mark('a@x.in', 'A', 1);
      t.mark('b@x.in', 'B', 1);
      t.setFaceFlag('b@x.in');
      final rec = t.toClassRecord(
          courseId: 'c', classLabel: 'c', dateIso: '2026-09-06');
      expect(rec.faceFlags, ['b@x.in']);
      final rt = ClassRecord.fromJson(rec.toJson());
      expect(rt.faceFlags, ['b@x.in']);
      // Legacy JSON without the key reads as unflagged.
      final m = rec.toJson()..remove('faceFlags');
      expect(ClassRecord.fromJson(m).faceFlags, isEmpty);
    });
  });
}
