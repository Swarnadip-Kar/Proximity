// Threshold + isolate-path proofs for records_isolate: small inputs stay
// synchronous (immediate, settle-safe in widget tests), large inputs run
// in compute and return identical bytes.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/records/records_isolate.dart';
import 'package:proximity_storage/storage.dart';

ClassRecord _session(String date, int seed) => ClassRecord(
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: date,
      w1: {'s$seed@x.in': true},
      names: {'s$seed@x.in': 'S$seed'},
      rolls: {'s$seed@x.in': '$seed'},
    );

void main() {
  test('small matrix stays sync and correct', () async {
    final sessions = [_session('2026-09-03', 1), _session('2026-09-04', 2)];
    expect(await buildMatrixCsvIsolate(sessions),
        buildDateRangeMatrix(sessions));
  });

  test('large matrix (>8 sessions) matches sync build', () async {
    final sessions = [
      for (var i = 0; i < 10; i++)
        _session('2026-09-${(i + 1).toString().padLeft(2, '0')}', i),
    ];
    expect(await buildMatrixCsvIsolate(sessions),
        buildDateRangeMatrix(sessions));
  });

  test('many-course build matches per-course sync builds', () async {
    final byCourse = {
      'CS201': [for (var i = 0; i < 6; i++) _session('2026-09-0${i + 1}', i)],
      'CS202': [for (var i = 0; i < 6; i++) _session('2026-10-0${i + 1}', 100 + i)],
    };
    final out = await buildMatrixCsvManyIsolate(byCourse);
    expect(out['CS201'], buildDateRangeMatrix(byCourse['CS201']!));
    expect(out['CS202'], buildDateRangeMatrix(byCourse['CS202']!));
  });

  test('history decode handles small and large blobs', () async {
    final sessions = [_session('2026-09-03', 1)];
    final smallRaw =
        jsonEncode(sessions.map((e) => e.toJson()).toList());
    final small = await decodeJsonListIsolate(smallRaw);
    expect(small, hasLength(1));

    // >256 KB blob forces the isolate path.
    final big = List.generate(
        60,
        (i) => ClassRecord(
              courseId: 'CS201',
              classLabel: 'CS201 with a long padding tail ${'x' * 200}',
              dateIso: '2026-09-03',
              w1: {
                for (var s = 0; s < 40; s++)
                  'student-$s-long-address@example.com': true
              },
              names: {
                for (var s = 0; s < 40; s++)
                  'student-$s-long-address@example.com':
                      'Student Number $s With A Long Name'
              },
              rolls: {
                for (var s = 0; s < 40; s++)
                  'student-$s-long-address@example.com': '123422${s}0'
              },
            ).toJson());
    final bigRaw = jsonEncode(big);
    expect(bigRaw.length, greaterThan(256 * 1024));
    final decoded = await decodeJsonListIsolate(bigRaw);
    expect(decoded, hasLength(60));
  });

  test('history encode round-trips small and large lists', () async {
    final one = [_session('2026-09-03', 1).toJson()];
    expect(await encodeJsonIsolate(one), jsonEncode(one));
    final many = [
      for (var i = 0; i < 45; i++) _session('2026-09-03', i).toJson(),
    ];
    expect(await encodeJsonIsolate(many), jsonEncode(many));
  });
}
