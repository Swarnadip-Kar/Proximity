// Session mapping + merge (pure, tested without Firebase).
// Split out of core/cloud_sync.dart (M6 sync refactor) — bodies verbatim.
library;

import 'package:proximity_storage/storage.dart';

/// Merge local + cloud histories by session id; newer timestampIso wins ties
/// by preferring the record with the later timestamp, union otherwise.
/// Pure — tested without Firebase.
List<ClassRecord> mergeHistories(
    List<ClassRecord> local, List<ClassRecord> cloud) {
  final byId = <String, ClassRecord>{};
  for (final r in local) {
    byId[r.id] = r;
  }
  for (final r in cloud) {
    final prev = byId[r.id];
    if (prev == null) {
      byId[r.id] = r;
    } else if (r.timestampIso.compareTo(prev.timestampIso) > 0) {
      byId[r.id] = r;
    }
  }
  final out = byId.values.toList()
    ..sort((a, b) => b.timestampIso.compareTo(a.timestampIso));
  return out;
}

Map<String, dynamic> sessionToDoc(
    {required String profUid,
    required String profEmail,
    required String profName,
    required ClassRecord record}) {
  final emails = record.allEmails.map((e) => e.toLowerCase()).toList()..sort();
  return {
    'courseId': record.courseId,
    'courseName': record.courseId.isNotEmpty ? record.courseId : record.classLabel,
    'classLabel': record.classLabel,
    'profUid': profUid,
    'profEmail': profEmail.toLowerCase(),
    'profName': profName,
    'dateIso': record.dateIso,
    'timestampIso': record.timestampIso,
    'startIso': record.startIso.isNotEmpty
        ? record.startIso
        : record.timestampIso,
    'windows': [for (final w in record.windows) Map<String, bool>.from(w)],
    'names': Map<String, String>.from(record.names),
    'rolls': Map<String, String>.from(record.rolls),
    'studentEmails': emails,
    'updatedAt': record.timestampIso,
  };
}

ClassRecord docToRecord(String id, Map<String, dynamic> d) {
  List<Map<String, bool>>? wins;
  try {
    final raw = d['windows'] as List?;
    if (raw != null) {
      wins = [
        for (final e in raw)
          Map<String, bool>.from(
              (e as Map).map((k, v) => MapEntry(k as String, (v as bool?) ?? false)))
      ];
    }
  } catch (_) {
    wins = null;
  }
  // courseName mirrors courseId on write (rename propagation); prefer the
  // canonical courseId, fall back to courseName for old docs.
  final courseId = d['courseId'] as String?;
  // names/rolls coerce via toString: a hand-written numeric value must not
  // crash the reader (was `v as String` throw propagating to UI).
  Map<String, String> strMap(Object? raw) {
    if (raw is! Map) return {};
    final out = <String, String>{};
    for (final e in raw.entries) {
      out['${e.key}'] = '${e.value ?? ''}';
    }
    return out;
  }

  return ClassRecord(
    id: id,
    courseId: (courseId != null && courseId.isNotEmpty)
        ? courseId
        : (d['courseName'] as String? ?? ''),
    classLabel: d['classLabel'] as String? ?? '',
    dateIso: d['dateIso'] as String? ?? '',
    timestampIso: d['timestampIso'] as String? ?? '',
    startIso: d['startIso'] as String? ?? '',
    windows: wins,
    names: strMap(d['names']),
    rolls: strMap(d['rolls']),
  );
}
