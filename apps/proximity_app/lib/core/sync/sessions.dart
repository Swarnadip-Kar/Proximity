// Session mapping + merge (pure, tested without Firebase).
// Split out of core/cloud_sync.dart (M6 sync refactor) — bodies verbatim.
library;

import 'package:proximity_storage/storage.dart';

import 'org.dart';

/// Tombstone: a deleted session id that must stay deleted across merges.
/// Wins over any upsert with timestampIso <= [deletedAtIso]; a record
/// re-created (or edited) AFTER the delete carries a newer timestamp and
/// resurrects. Pure — tested without Firebase.
class SessionTombstone {
  final String id;
  final String deletedAtIso; // UTC ISO, monotonic vs record timestampIso
  final String org; // owner org at delete, '' = legacy
  final String course; // course name at delete (badge/debug only)
  const SessionTombstone(
      {required this.id, required this.deletedAtIso, this.org = '', this.course = ''});

  Map<String, dynamic> toJson() => {
        'id': id,
        'deletedAtIso': deletedAtIso,
        'org': org,
        'course': course,
      };

  factory SessionTombstone.fromJson(Map<String, dynamic> j) =>
      SessionTombstone(
        id: j['id'] as String? ?? '',
        deletedAtIso: j['deletedAtIso'] as String? ?? '',
        org: j['org'] as String? ?? '',
        course: j['course'] as String? ?? '',
      );
}

/// Additive union of two records with the SAME id (Track 4
/// union-merge-before-push): window maps OR together (a mark is never
/// unmarked by merge), names/rolls union (newer non-empty wins per email),
/// timestampIso = max (monotonic, so idempotent set(merge:true) pushes never
/// go backwards), startIso = earliest non-empty (stable FIFO ordering).
/// Header fields come from the newer record, falling back to the older when
/// empty. Pure — tested without Firebase.
ClassRecord unionMergeRecords(ClassRecord a, ClassRecord b) {
  assert(a.id == b.id, 'unionMergeRecords needs one session id');
  final newer = a.timestampIso.compareTo(b.timestampIso) >= 0 ? a : b;
  final older = identical(newer, a) ? b : a;
  final n = newer.windows.length > older.windows.length
      ? newer.windows.length
      : older.windows.length;
  final windows = <Map<String, bool>>[
    for (var i = 0; i < n; i++)
      {
        ...? (i < older.windows.length ? older.windows[i] : null),
        ...? (i < newer.windows.length ? newer.windows[i] : null),
        for (final k in {
          ...? (i < older.windows.length ? older.windows[i].keys : null),
          ...? (i < newer.windows.length ? newer.windows[i].keys : null),
        })
          k: (i < older.windows.length && (older.windows[i][k] ?? false)) ||
              (i < newer.windows.length && (newer.windows[i][k] ?? false)),
      }
  ];
  Map<String, String> unionStr(
      Map<String, String> o, Map<String, String> nn) {
    final out = Map<String, String>.from(o);
    for (final e in nn.entries) {
      if (e.value.isNotEmpty) out[e.key] = e.value;
    }
    return out;
  }

  String earliest(String x, String y) {
    if (x.isEmpty) return y;
    if (y.isEmpty) return x;
    return x.compareTo(y) <= 0 ? x : y;
  }

  String pick(String n, String o) => n.isNotEmpty ? n : o;
  return ClassRecord(
    id: a.id,
    courseId: pick(newer.courseId, older.courseId),
    classLabel: pick(newer.classLabel, older.classLabel),
    dateIso: pick(newer.dateIso, older.dateIso),
    timestampIso: newer.timestampIso,
    startIso: earliest(a.startIso, b.startIso),
    windows: windows,
    names: unionStr(older.names, newer.names),
    rolls: unionStr(older.rolls, newer.rolls),
    org: pick(newer.org, older.org),
  );
}

/// Drops records a tombstone wins over (deletedAtIso >= timestampIso).
/// Pure — tested without Firebase.
List<ClassRecord> applyTombstones(
    List<ClassRecord> records, List<SessionTombstone> tombstones) {
  if (tombstones.isEmpty) return List.of(records);
  final byId = {for (final t in tombstones) t.id: t};
  return [
    for (final r in records)
      if (!(byId.containsKey(r.id) &&
          byId[r.id]!.deletedAtIso.compareTo(r.timestampIso) >= 0))
        r,
  ];
}

/// Merge with union semantics + tombstones (Track 4 SyncEngine path):
/// same-id records union (marks additive, never lost to LWW), deletes win
/// over older upserts. (The old pure-LWW mergeHistories was deleted in the
/// Track 4 audit: zero production callers, and its newer-wins test
/// asserted the exact data-loss — a newer `false` wiping a local `true`
/// mark — that union-merge-before-push was built to replace.)
/// the engine converges through this. Pure — tested without Firebase.
List<ClassRecord> mergeHistoriesUnion(
    List<ClassRecord> local, List<ClassRecord> cloud,
    {List<SessionTombstone> tombstones = const []}) {
  final byId = <String, ClassRecord>{};
  void add(ClassRecord r) {
    final prev = byId[r.id];
    byId[r.id] = prev == null ? r : unionMergeRecords(prev, r);
  }

  for (final r in cloud) {
    add(r);
  }
  for (final r in local) {
    add(r);
  }
  final out = applyTombstones(byId.values.toList(), tombstones)
    ..sort((a, b) => b.timestampIso.compareTo(a.timestampIso));
  return out;
}

/// One durable outbox entry: a full session snapshot keyed by record id +
/// per-entry retry state. Pure — tested without Firebase.
class PendingSession {
  final String id; // == record.id (doc id for idempotent pushes)
  final ClassRecord record; // full snapshot (union-merged before push)
  final String org; // owner org at enqueue (see orgOf), '' = legacy
  final int attempts; // consecutive push failures
  final String nextRetryAtIso; // '' = due now
  final String updatedAtIso; // last enqueue time
  const PendingSession(
      {required this.id,
      required this.record,
      this.org = '',
      this.attempts = 0,
      this.nextRetryAtIso = '',
      this.updatedAtIso = ''});

  bool due(DateTime nowUtc) {
    if (nextRetryAtIso.isEmpty) return true;
    try {
      return !DateTime.parse(nextRetryAtIso).toUtc().isAfter(nowUtc);
    } catch (_) {
      return true;
    }
  }

  String get course =>
      record.courseId.isNotEmpty ? record.courseId : record.classLabel;

  /// Per-course FIFO: course, then startIso, then timestampIso.
  static int order(PendingSession a, PendingSession b) {
    final c = a.course.compareTo(b.course);
    if (c != 0) return c;
    final s = a.record.startIso.compareTo(b.record.startIso);
    if (s != 0) return s;
    return a.record.timestampIso.compareTo(b.record.timestampIso);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'record': record.toJson(),
        'org': org,
        'attempts': attempts,
        'nextRetryAtIso': nextRetryAtIso,
        'updatedAtIso': updatedAtIso,
      };

  factory PendingSession.fromJson(Map<String, dynamic> j) => PendingSession(
        id: j['id'] as String? ?? '',
        record: ClassRecord.fromJson(
            Map<String, dynamic>.from(j['record'] as Map? ?? {})),
        org: j['org'] as String? ?? '',
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        nextRetryAtIso: j['nextRetryAtIso'] as String? ?? '',
        updatedAtIso: j['updatedAtIso'] as String? ?? '',
      );
}

Map<String, dynamic> sessionToDoc(
    {required String profUid,
    required String profEmail,
    required String profName,
    required ClassRecord record,
    String? profOrg}) {
  final emails = record.allEmails.map((e) => e.toLowerCase()).toList()..sort();
  // Session org = prof org at creation, immutable on update: a stamped
  // record keeps its org; an unstamped (legacy) record takes the prof org.
  final fallback = (profOrg != null && profOrg.isNotEmpty)
      ? profOrg
      : orgOf(profEmail);
  final org = record.org.isNotEmpty ? record.org : fallback;
  return {
    'courseId': record.courseId,
    'courseName': record.courseId.isNotEmpty ? record.courseId : record.classLabel,
    'classLabel': record.classLabel,
    'profUid': profUid,
    'profEmail': profEmail.toLowerCase(),
    'profName': profName,
    'org': org,
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
    org: d['org'] as String? ?? '',
  );
}
