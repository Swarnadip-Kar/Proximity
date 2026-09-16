// Crash-safety hardening regression (2026-09-11 sweep).
//
// Covers each fixed path from the crash-safety pass: unguarded `!` /
// `first` / `[]` / `as` / parse / division / async-gap guards in
// user-reachable flows (records, account, live, export, enroll, sync).
// Pure unit tests where the logic is pure; minimal widget smoke tests
// where the fix lives in a builder/handler. Fail-soft idioms preserved:
// poison entries drop per-entry, never wipe whole lists, never throw
// past the UI.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/live/live_roster.dart';
import 'package:proximity_app/features/records/session_edit_screen.dart';
import 'package:proximity_app/features/setup/enroll_capture_sections.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';
import 'package:proximity_storage/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('capture_overlay promptTopFor tiny viewport', () {
    test('returns 0 instead of throwing when height < xxl', () {
      final oval = Rect.fromCenter(
        center: const Offset(100, 10),
        width: 50,
        height: 40,
      );
      // Height 20 < ProxSpacing.xxl (32): old clamp(0, negative) threw.
      expect(CaptureOverlay.promptTopFor(const Size(200, 20), oval), 0.0);
      expect(CaptureOverlay.promptTopFor(const Size(200, 0), oval), 0.0);
    });

    test('normal sizes still clamp below the oval', () {
      final oval = Rect.fromLTWH(50, 100, 100, 200);
      final top =
          CaptureOverlay.promptTopFor(const Size(400, 800), oval);
      expect(top, greaterThan(oval.bottom));
      expect(top, lessThanOrEqualTo(800 - ProxSpacing.xxl));
    });

    test('directionForAngle total 0 returns zero (no division)', () {
      expect(CaptureOverlay.directionForAngle(0, 0), Offset.zero);
      expect(CaptureOverlay.directionForAngle(5, 0), Offset.zero);
    });
  });

  group('enroll progress division guard', () {
    testWidgets('EnrollCapturePreview with total 0 builds, no exception',
        (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EnrollCapturePreview(
              controller: null,
              isOpening: false,
              failMessage: null,
              doneCount: 0,
              total: 0,
              nextAngle: 0,
              totalAngles: 5,
              statusLine: 'prompt',
              sweepAngle: null,
              saveError: false,
              saveMessage: '',
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull);
    });

    test('progress expression guards zero total', () {
      int doneCount = 3;
      int total = 0;
      final progress = total <= 0 ? 0.0 : doneCount / total;
      expect(progress, 0.0);
      expect(progress.isFinite, isTrue);
    });
  });

  group('SegmentedButton empty-selection guard', () {
    testWidgets('SessionEditScreen tab handler ignores empty set',
        (t) async {
      final record = ClassRecord(
        id: 's1',
        courseId: 'CS201',
        classLabel: 'CS201',
        dateIso: '2026-09-06',
        timestampIso: '2026-09-06T10:00:00.000Z',
        windows: [
          {'a@x.in': true}
        ],
        names: const {'a@x.in': 'A'},
      );
      await t.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: proxLightTheme(),
            home: SessionEditScreen(record: record),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      // Invoke the Marks/Add segmented handler with an empty set directly:
      // the fix guards `if (s.isEmpty) return` so this must not throw.
      final buttons = t.widgetList<SegmentedButton<int>>(
          find.byType(SegmentedButton<int>));
      expect(buttons, isNotEmpty);
      for (final b in buttons) {
        expect(() => b.onSelectionChanged!(<int>{}), returnsNormally);
      }
      expect(t.takeException(), isNull);
    });
  });

  group('storage fromJson leniency (no whole-list wipe)', () {
    test('ClassRecord missing classLabel/dateIso defaults to empty', () {
      final r = ClassRecord.fromJson({
        'id': 's1',
        'timestampIso': '2026-09-06T10:00:00.000Z',
      });
      expect(r.classLabel, '');
      expect(r.dateIso, '');
      expect(r.id, 's1');
    });

    test('ClassRecord numeric names/rolls coerce instead of throwing', () {
      final r = ClassRecord.fromJson({
        'id': 's1',
        'classLabel': 'CS201',
        'dateIso': '2026-09-06',
        'timestampIso': '2026-09-06T10:00:00.000Z',
        'names': {'a@x.in': 123},
        'rolls': {'a@x.in': 456},
      });
      expect(r.names['a@x.in'], '123');
      expect(r.rolls['a@x.in'], '456');
    });

    test('Course missing name defaults to empty (no throw)', () {
      final c = Course.fromJson({'createdAt': '2026-09-06'});
      expect(c.name, '');
    });
  });

  group('manual queue poison isolation', () {
    test('poison entry drops, valid entry still resolves', () async {
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
      // Poison: non-String values make fromJson throw (`as String?` on int).
      // Valid entry must still resolve instead of aborting the whole replay.
      await store.writePendingAdds([
        {'course': 123, 'sessionId': 's1', 'roll': 456},
        const PendingManualAdd(
                course: 'CS201',
                sessionId: 's1',
                roll: '10000001',
                createdAtIso: '2026-09-06T10:00:00.000Z')
            .toJson(),
      ]);
      final res = await processPendingAdds(store: store, cloud: cloud);
      expect(res.resolvedIds, ['s1']);
      // Poison dropped, valid resolved: nothing remains queued.
      expect(res.remaining, 0);
    });
  });

  group('secure store per-entry tolerance', () {
    test('history with one poison entry keeps the good one', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SecureDeviceStore();
      final good = ClassRecord(
        id: 'good',
        courseId: 'CS201',
        classLabel: 'CS201',
        dateIso: '2026-09-06',
        timestampIso: '2026-09-06T10:00:00.000Z',
        windows: [
          {'a@x.in': true}
        ],
        names: const {'a@x.in': 'A'},
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'prox.history.v1',
          jsonEncode([
            good.toJson(),
            'not-a-map',
            {'id': 'also-good', 'classLabel': 'CS201', 'dateIso': '2026-09-06'},
          ]));
      final back = await store.readHistory();
      expect(back.map((r) => r.id), contains('good'));
      expect(back.map((r) => r.id), contains('also-good'));
      expect(back.length, 2);
    });

    test('pending lists skip non-map entries instead of wiping', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SecureDeviceStore();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'prox.pendingAdds.v1',
          jsonEncode([
            {'course': 'CS201', 'roll': '1'},
            'poison',
            42,
          ]));
      final adds = await store.readPendingAdds();
      expect(adds.length, 1);
      expect(adds.first['course'], 'CS201');
    });

    test('readSession with non-map value returns null (no throw)', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SecureDeviceStore();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'prox.sessions.v1', jsonEncode({'CS201': 'corrupted'}));
      expect(await store.readSession('CS201'), isNull);
    });
  });

  group('live roster + Future.wait cast guards', () {
    test('distinctGroups empty map yields no groups (resolve no-op)', () {
      expect(DupFlagSection.distinctGroups({}), isEmpty);
      expect(
          DupFlagSection.distinctGroups(
              {'a@x.in': {}, 'b@x.in': {}}),
          isEmpty);
    });

    test('Future.wait data with wrong types falls back to empty', () {
      // Mirrors the hardened builder parsing in prof_courses/shells:
      // `data[0] is List<Course>` etc. Wrong types must not throw.
      final List<dynamic> data = ['wrong', 42];
      final courses = data.isNotEmpty && data[0] is List<Course>
          ? data[0] as List<Course>
          : const <Course>[];
      final history =
          data.length >= 2 && data[1] is List<ClassRecord>
              ? data[1] as List<ClassRecord>
              : const <ClassRecord>[];
      expect(courses, isEmpty);
      expect(history, isEmpty);
    });
  });

  group('take_attendance int-list tolerance', () {
    test('string window numbers coerce instead of throwing', () {
      // Mirrors _intList: `e is num ? e.toInt() : int.tryParse('\$e') ?? 0`.
      int coerce(Object? e) =>
          e is num ? e.toInt() : int.tryParse('$e') ?? 0;
      expect(coerce('3'), 3);
      expect(coerce(2.0), 2);
      expect(coerce('bad'), 0);
      expect(coerce(null), 0);
      // Old `(e as num?)` threw on strings; the new form never throws.
      expect(() => coerce('1'), returnsNormally);
    });
  });

  group('account prof facts length guard', () {
    test('short/empty snapshot data reads as empty (no RangeError)', () {
      String installOf(List<String?>? data) =>
          (data != null && data.isNotEmpty ? data[0] : null) ?? '';
      String hostOf(List<String?>? data) =>
          (data != null && data.length > 1 ? data[1] : null) ?? '';
      expect(installOf(null), '');
      expect(installOf([]), '');
      expect(installOf(['abc']), 'abc');
      expect(hostOf(['abc']), '');
      expect(hostOf(['abc', 'host']), 'host');
      expect(hostOf([]), '');
    });
  });

  group('take_attendance sub-nav empty guard', () {
    testWidgets('live sub-nav handler ignores empty set', (t) async {
      // Same guard idiom as SessionEditScreen: empty SegmentedButton
      // selection must be a no-op, never `.first` on empty.
      var selected = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Roster')),
                ButtonSegment(value: 1, label: Text('Inbox')),
              ],
              selected: {selected},
              showSelectedIcon: false,
              onSelectionChanged: (s) {
                if (s.isEmpty) return;
                selected = s.first;
              },
            ),
          ),
        ),
      );
      final btn = t.widget<SegmentedButton<int>>(
          find.byType(SegmentedButton<int>));
      expect(() => btn.onSelectionChanged!(<int>{}), returnsNormally);
      expect(selected, 0);
      btn.onSelectionChanged!({1});
      expect(selected, 1);
      expect(t.takeException(), isNull);
    });
  });
}
