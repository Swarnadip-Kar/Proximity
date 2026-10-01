// Off-main-thread records work (history JSON codec + matrix builds).
//
// History is one SharedPreferences JSON string that grows unboundedly
// (every round upserts the same record, semesters accumulate): decoding
// or re-encoding it on the UI isolate drops frames on low-end phones.
// The matrix is O(sessions × emails × windows) string building. All of
// it is pure data work — isolate-safe primitives in and out — so it
// runs in `compute` with a synchronous fallback (tests, restricted
// runtimes). Typed mapping (ClassRecord.fromJson) stays on the caller:
// cheap per record next to the bulk codec, and it keeps corrupt-row
// skipping exactly where it is today.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:proximity_storage/storage.dart';

/// Isolate entry: JSON-decode one history/courses blob into plain maps.
/// Drops non-map rows (same corrupt-row rule as the callers).
List<Map<String, Object?>> _decodeJsonList(String raw) {
  final out = <Map<String, Object?>>[];
  try {
    final list = jsonDecode(raw) as List;
    for (final e in list) {
      try {
        if (e is Map) out.add(Map<String, Object?>.from(e));
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

/// Isolate entry: JSON-encode an already-plain structure.
String _encodeJson(Object? value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return '[]';
  }
}

/// Isolate entry: session maps in, date-range matrix CSV string out.
String _matrixForSessions(List<Map<String, Object?>> sessionsJson) {
  try {
    final sessions = <ClassRecord>[];
    for (final e in sessionsJson) {
      try {
        sessions.add(ClassRecord.fromJson(Map<String, dynamic>.from(e)));
      } catch (_) {}
    }
    return buildDateRangeMatrix(sessions);
  } catch (_) {
    return '';
  }
}

/// Isolate entry: course-name → session maps in, course-name → matrix CSV
/// out (export-all builds every course in one isolate hop).
Map<String, String> _matricesForCourses(
    Map<String, List<Map<String, Object?>>> coursesJson) {
  final out = <String, String>{};
  coursesJson.forEach((name, sessionsJson) {
    out[name] = _matrixForSessions(sessionsJson);
  });
  return out;
}

/// Below this many sessions the matrix builds synchronously: isolate
/// spawn costs more than the work, and tiny exports stay on the
/// immediate path (including their widget tests — no settle-flake).
/// Above it, the O(sessions × emails × windows) build leaves the UI
/// thread. Tunable without a wire change.
const int kMatrixIsolateSessions = 8;

/// Below this blob size the history JSON codec stays synchronous for
/// the same spawn-tax reason. Above it (a term of history), decode and
/// re-encode leave the UI thread.
const int kHistoryIsolateBytes = 256 * 1024;

/// Below this many records history re-encode stays synchronous (same
/// spawn-tax reason; a record is tens of KB, so this is ~1 MB+).
const int kHistoryIsolateRecords = 40;

/// Decode a JSON list blob, off the main thread when large. Never
/// throws (corrupt input decodes to empty — same as the callers'
/// catch-all today).
Future<List<Map<String, Object?>>> decodeJsonListIsolate(String raw) async {
  if (raw.length <= kHistoryIsolateBytes) return _decodeJsonList(raw);
  try {
    return await compute(_decodeJsonList, raw);
  } catch (_) {
    return _decodeJsonList(raw);
  }
}

/// Encode a plain-JSON structure, off the main thread when it is a
/// large list (history blobs). Small maps/lists stay synchronous for
/// the same spawn-tax reason. Never throws.
Future<String> encodeJsonIsolate(Object? value) async {
  if (value is! List || value.length <= kHistoryIsolateRecords) {
    return _encodeJson(value);
  }
  try {
    return await compute(_encodeJson, value);
  } catch (_) {
    return _encodeJson(value);
  }
}

/// Build the date-range matrix CSV, off the main thread when large.
/// Sessions cross as their `toJson` maps (isolate-safe); corrupt rows
/// drop. Never throws (empty matrix on failure).
Future<String> buildMatrixCsvIsolate(List<ClassRecord> sessions) async {
  final json = _sessionsToJson(sessions);
  if (json.length <= kMatrixIsolateSessions) return _matrixForSessions(json);
  try {
    return await compute(_matrixForSessions, json);
  } catch (_) {
    return _matrixForSessions(json);
  }
}

/// Build every course matrix in ONE isolate hop (export-all) when large;
/// small courses stay synchronous. Never throws.
Future<Map<String, String>> buildMatrixCsvManyIsolate(
    Map<String, List<ClassRecord>> byCourse) async {
  final json = <String, List<Map<String, Object?>>>{};
  var total = 0;
  byCourse.forEach((name, sessions) {
    json[name] = _sessionsToJson(sessions);
    total += sessions.length;
  });
  if (total <= kMatrixIsolateSessions) {
    return _matricesForCourses(json);
  }
  try {
    final out = await compute(_matricesForCourses, json);
    return Map<String, String>.from(out);
  } catch (_) {
    return _matricesForCourses(json);
  }
}

List<Map<String, Object?>> _sessionsToJson(List<ClassRecord> sessions) {
  final json = <Map<String, Object?>>[];
  for (final s in sessions) {
    try {
      json.add(Map<String, Object?>.from(s.toJson()));
    } catch (_) {}
  }
  return json;
}
