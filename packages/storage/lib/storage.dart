// Storage: SQLite tally (prof) + secure storage (keys/templates). (§8)
//
// P0 uses an in-memory tally with the exact CSV/export semantics; drift/SQLite
// file backing lands in P1 without changing callers.
// Attendance is keyed by Gmail account (no institute IDs).
//
// Windows model (updated): a lecture session starts with ONE window. The
// professor may take again to add window 2, 3, ... Present = intersection of
// ALL windows (present in every window taken). Single-window sessions behave
// exactly like the old W1-only case. W1/W2 columns are removed from UI/CSV;
// exports are Name,ID Number,Email,Status (Present/Absent).
library proximity_storage;

class AttendanceRecord {
  final String email;
  final String name;
  String roll;

  /// Student's volunteered Gmail photo URL ('' = absent → initials).
  /// Session RAM only, never persisted to records; latest non-empty wins,
  /// empty never clobbers (same rule as name/roll).
  String photoUrl;
  final Set<int> wins = {}; // window numbers (1-based) marked present
  bool faceFlag = false;
  bool late = false;
  AttendanceRecord(
      {required this.email,
      required this.name,
      this.roll = '',
      this.photoUrl = ''});

  bool presentIn(int windowNo) => wins.contains(windowNo);

  /// Present in ALL of [allWindows]. Empty window list -> false.
  bool confirmedIn(List<int> allWindows) {
    if (allWindows.isEmpty) return false;
    for (final w in allWindows) {
      if (!wins.contains(w)) return false;
    }
    return true;
  }

  String status({bool lenientOneOfTwo = false, List<int>? allWindows}) {
    final winsList = allWindows ?? wins.toList();
    if (winsList.isEmpty) return 'Absent';
    final pass = lenientOneOfTwo
        ? wins.isNotEmpty
        : confirmedIn(winsList);
    if (pass) return 'Present';
    if (wins.isNotEmpty) return 'Partial';
    return 'Absent';
  }
}

/// Professor tally: live counts + present/face-flag/late lists + search.
/// Supports N windows; Present = intersection of all windows taken.
class TallyStore {
  final Map<String, AttendanceRecord> _rows = {}; // email -> record
  // Every window the professor OPENED, even ones nobody (or only late
  // provers) marked. Without this, windowNos is the union of marked wins,
  // so empty and late-only rounds vanish from history/exports — a 5-round
  // visit renders as 2 windows.
  final Set<int> _openedWindows = {};

  /// Records that round [windowNo] opened (idempotent). Called by the
  /// server on openWindow; restored drafts re-seed it via restore().
  void noteWindow(int windowNo) {
    if (windowNo > 0) _openedWindows.add(windowNo);
  }

  /// Drops round [windowNo]: un-opens it and strips it from every row's
  /// wins. Rows stay (names/rolls/photos are visit data, not round
  /// data), so waiting/manual people survive with empty wins; presence
  /// recomputes from the remaining windows. No-op for unknown rounds.
  void discardWindow(int windowNo) {
    _openedWindows.remove(windowNo);
    for (final r in _rows.values) {
      r.wins.remove(windowNo);
    }
  }

  void ensure(String email, String name,
      [String roll = '', String photoUrl = '']) {
    final key = email.toLowerCase();
    final existing = _rows[key];
    if (existing == null) {
      _rows[key] = AttendanceRecord(
          email: key, name: name, roll: roll, photoUrl: photoUrl);
      return;
    }
    // Manual entries may correct the display name / ID number: keep the
    // latest non-empty values (marks, flags and wins are preserved).
    if (name.isNotEmpty && name != existing.name) {
      _rows[key] = AttendanceRecord(
          email: key,
          name: name,
          roll: roll.isNotEmpty ? roll : existing.roll,
          photoUrl:
              photoUrl.isNotEmpty ? photoUrl : existing.photoUrl)
        ..wins.addAll(existing.wins)
        ..faceFlag = existing.faceFlag
        ..late = existing.late;
    } else {
      if (roll.isNotEmpty) {
        existing.roll = roll;
      }
      // Volunteered photo converges like the name: latest non-empty wins,
      // empty never clobbers a known photo.
      if (photoUrl.isNotEmpty) {
        existing.photoUrl = photoUrl;
      }
    }
  }

  void mark(String email, String name, int windowNo,
      {bool faceFlag = false,
      bool late = false,
      String roll = '',
      String photoUrl = ''}) {
    ensure(email, name, roll, photoUrl);
    final r = _rows[email.toLowerCase()]!;
    r.wins.add(windowNo);
    if (faceFlag) r.faceFlag = true;
    if (late) r.late = true;
  }

  /// Already marked present in [windowNo] (duplicate-POST idempotency).
  bool isMarked(String email, int windowNo) =>
      _rows[email.toLowerCase()]?.presentIn(windowNo) ?? false;

  /// Sorted distinct window numbers taken so far: every OPENED round
  /// plus every marked one. Empty maps still persist (the round happened,
  /// nobody marked), so the count matches the professor's rounds.
  List<int> get windowNos {
    final s = <int>{..._openedWindows};
    for (final r in _rows.values) {
      s.addAll(r.wins);
    }
    final out = s.toList()..sort();
    return out;
  }

  int get windowCount => windowNos.length;

  /// Present in ANY window (legacy). New UI prefers [confirmed].
  int get presentCountAny => _rows.values.where((r) => r.wins.isNotEmpty).length;

  /// Present in ALL windows (intersection). Single window == any.
  int get presentCount => _confirmedRows.length;
  int get confirmedCount => _confirmedRows.length;

  List<AttendanceRecord> get _confirmedRows {
    final wins = windowNos;
    if (wins.isEmpty) return const [];
    return _rows.values.where((r) => r.confirmedIn(wins)).toList();
  }

  List<AttendanceRecord> get present => _confirmedRows;
  List<AttendanceRecord> get confirmed => _confirmedRows;
  List<AttendanceRecord> get presentAny =>
      _rows.values.where((r) => r.wins.isNotEmpty).toList();
  List<AttendanceRecord> get lateList =>
      _rows.values.where((r) => r.late).toList();

  /// Local same-face dup flag (professor-phone, session-scoped): sets the
  /// roster-visible `DUPLICATE_FLAGGED` state WITHOUT touching presence —
  /// flagged entries are never auto-absent. The professor resolves via
  /// [clearFaceFlag] (1-tap override); the tally itself is in-memory P0.
  void setFaceFlag(String email) {
    final r = _rows[email.toLowerCase()];
    if (r != null) r.faceFlag = true;
  }

  void clearFaceFlag(String email) {
    final r = _rows[email.toLowerCase()];
    if (r != null) r.faceFlag = false;
  }

  /// Emails currently flagged, sorted (deterministic for records/exports).
  List<String> get flaggedEmails {
    final out = [
      for (final e in _rows.entries)
        if (e.value.faceFlag) e.key,
    ];
    out.sort();
    return out;
  }

  List<AttendanceRecord> search(String query) {
    final q = query.toLowerCase();
    return _rows.values
        .where((r) =>
            r.email.contains(q) ||
            r.name.toLowerCase().contains(q) ||
            r.roll.toLowerCase().contains(q))
        .toList();
  }

  Map<String, bool> windowMap(int windowNo) => {
        for (final e in _rows.entries) e.key: e.value.wins.contains(windowNo),
      };

  List<Map<String, bool>> get windowsAsMaps =>
      [for (final n in windowNos) windowMap(n)];

  Map<String, String> nameMap() =>
      {for (final e in _rows.entries) e.key: e.value.name};

  Map<String, String> rollMap() =>
      {for (final e in _rows.entries) e.key: e.value.roll};

  /// Simple CSV without W1/W2: Name,ID Number,Email,Status.
  /// Present = intersection of all windows (or any when lenient).
  String exportCsv(
          {required String classLabel,
          required String dateIso,
          bool lenientOneOfTwo = false}) =>
      buildSimpleCsv(
        names: nameMap(),
        rolls: rollMap(),
        windows: windowsAsMaps,
        lenientOneOfTwo: lenientOneOfTwo,
      );

  int get size => _rows.length;

  /// Professor eject: drops one email's record (marks, flags, wins).
  /// Opened windows are kept (the rounds happened). Returns true when a
  /// record existed. Session-local: the next history upsert/snapshot
  /// simply no longer contains them; re-marking re-adds.
  bool remove(String email) {
    final key = email.trim().toLowerCase();
    if (key.isEmpty) return false;
    return _rows.remove(key) != null;
  }

  void clear() {
    _rows.clear();
    _openedWindows.clear();
  }

  /// Rebuilds the tally from persisted draft data (autosave resume).
  /// [windows] is the ordered list of window maps; [windowNos] gives the
  /// window number for each entry (defaults to 1..n when omitted).
  /// Sparse numbering (e.g. [1,2,5]) is preserved as-is — never
  /// renumbered, so distinct rounds can never merge.
  void restore({
    required List<Map<String, bool>> windows,
    required Map<String, String> names,
    Map<String, String> rolls = const {},
    List<int>? windowNos,
  }) {
    clear();
    final nos = (windowNos != null && windowNos.length == windows.length)
        ? windowNos
        : [for (var i = 0; i < windows.length; i++) i + 1];
    for (final no in nos) {
      noteWindow(no);
    }
    for (var i = 0; i < windows.length; i++) {
      final no = nos[i];
      for (final e in windows[i].entries) {
        if (e.value) {
          mark(e.key, names[e.key] ?? e.key, no, roll: rolls[e.key] ?? '');
        } else {
          ensure(e.key, names[e.key] ?? e.key, rolls[e.key] ?? '');
        }
      }
    }
    for (final e in names.entries) {
      ensure(e.key, e.value, rolls[e.key] ?? '');
    }
  }

  ClassRecord toClassRecord(
          {required String courseId,
          required String classLabel,
          required String dateIso,
          String? timestampIso,
          String? startIso,
          String? id,
          String org = ''}) =>
      ClassRecord(
        id: id ?? '',
        courseId: courseId,
        classLabel: classLabel,
        dateIso: dateIso,
        timestampIso: timestampIso ?? '',
        startIso: startIso ?? '',
        windows: windowsAsMaps.isEmpty ? [const <String, bool>{}] : windowsAsMaps,
        names: nameMap(),
        rolls: rollMap(),
        org: org,
        faceFlags: flaggedEmails,
      );
}

/// RFC4180 cell + formula-injection guard (audit LOW fix): fields
/// containing `,` `"` CR LF are double-quoted (inner `"` doubled);
/// fields starting with `=` `+` `-` `@` are `'`-prefixed so spreadsheet
/// apps never evaluate stranger-controlled names/rolls/emails as
/// formulas (quoting alone does NOT stop formula eval). Status/P/A
/// cells are enum-safe and bypass this.
String csvCell(String field) {
  var cell = field;
  if (cell.startsWith(RegExp(r'[=+\-@]'))) cell = "'$cell";
  if (cell.contains(RegExp(r'[",\r\n]'))) {
    cell = '"${cell.replaceAll('"', '""')}"';
  }
  return cell;
}

/// Simple per-session CSV: Name,ID Number,Email,Status.
/// [windows] is the ordered list of window maps (email -> present).
String buildSimpleCsv({
  required Map<String, String> names,
  Map<String, String> rolls = const {},
  required List<Map<String, bool>> windows,
  bool lenientOneOfTwo = false,
}) {
  final emails = <String>{
    for (final w in windows) ...w.keys,
    ...names.keys,
  }.toList()
    ..sort();
  // Trim trailing fully-empty windows (no keys) so a fresh single-window
  // session with [w1, {}] still counts w1 alone.
  var wins = windows;
  while (wins.length > 1 && wins.last.isEmpty) {
    wins = wins.sublist(0, wins.length - 1);
  }
  final sb = StringBuffer('Name,ID Number,Email,Status\n');
  for (final email in emails) {
    var presentCount = 0;
    for (final w in wins) {
      if (w[email] == true) presentCount++;
    }
    final pass = wins.isEmpty
        ? false
        : (lenientOneOfTwo ? presentCount > 0 : presentCount == wins.length && wins.isNotEmpty);
    // Empty session (no windows with data): everyone Absent.
    final status = (wins.isEmpty || (wins.length == 1 && wins.first.isEmpty))
        ? 'Absent'
        : (pass ? 'Present' : 'Absent');
    sb.writeln(
        '${csvCell(names[email] ?? '')},${csvCell(rolls[email] ?? '')},${csvCell(email)},$status');
  }
  return sb.toString();
}

List<Map<String, bool>> normalizeWindows(
    List<Map<String, bool>>? windows, Map<String, bool>? w1, Map<String, bool>? w2) {
  if (windows != null) {
    final out = [for (final w in windows) Map<String, bool>.from(w)];
    while (out.length > 1 && out.last.isEmpty) {
      out.removeLast();
    }
    return out.isEmpty ? [const <String, bool>{}] : out;
  }
  final a = Map<String, bool>.from(w1 ?? const {});
  final b = Map<String, bool>.from(w2 ?? const {});
  if (b.isEmpty) return [a];
  return [a, b];
}

String _genId(String courseId, String classLabel, String dateIso) =>
    '$courseId|$classLabel|$dateIso|${DateTime.now().toUtc().microsecondsSinceEpoch}';

/// One saved class session (professor device history). Exportable.
/// Belongs to a [Course] via [courseId] (the course name; records saved
/// before courses existed carry '' and group under their class label).
///
/// Sessions carry an [id] (stable for deletion), a full [timestampIso] (so
/// same-date sessions disambiguate with time), a [startIso] class-start
/// time (stable across re-pushes of the same visit; falls back to
/// [timestampIso] for old records), and ordered [windows].
/// Old JSON with w1/w2 migrates to windows=[w1,(w2 if non-empty)].
class ClassRecord {
  final String id;
  final String courseId;
  final String classLabel;
  final String dateIso; // yyyy-MM-dd
  final String timestampIso; // full ISO datetime
  final String startIso; // full ISO datetime the class visit started
  final List<Map<String, bool>> windows; // ordered window maps
  final Map<String, String> names; // email -> name
  final Map<String, String> rolls; // email -> ID number
  final String org; // Google-account domain of the prof org, '' = legacy
  /// Session duplicate-face flags (emails marked DUPLICATE_FLAGGED on the
  /// professor phone during the live session). Statuses only — no vectors,
  /// no biometrics, ever (see protocol face_print.dart).
  final List<String> faceFlags;
  ClassRecord({
    String id = '',
    this.courseId = '',
    required this.classLabel,
    required this.dateIso,
    String timestampIso = '',
    String startIso = '',
    Map<String, bool>? w1,
    Map<String, bool>? w2,
    List<Map<String, bool>>? windows,
    Map<String, String>? names,
    Map<String, String>? rolls,
    this.org = '',
    List<String>? faceFlags,
  })  : id = id.isEmpty ? _genId(courseId, classLabel, dateIso) : id,
        timestampIso = timestampIso.isEmpty
            ? '${dateIso}T00:00:00.000Z'
            : timestampIso,
        startIso = startIso.isEmpty
            ? (timestampIso.isEmpty
                ? '${dateIso}T00:00:00.000Z'
                : timestampIso)
            : startIso,
        windows = normalizeWindows(windows, w1, w2),
        names = Map<String, String>.from(names ?? const {}),
        rolls = Map<String, String>.from(rolls ?? const {}),
        faceFlags = [...?faceFlags]..sort();

  /// Legacy accessors (first two windows).
  Map<String, bool> get w1 => windows.isNotEmpty ? windows.first : const {};
  Map<String, bool> get w2 => windows.length > 1 ? windows[1] : const {};

  int get w1Count => w1.values.where((v) => v).length;
  int get w2Count => w2.values.where((v) => v).length;
  int get windowCount => windows.length;

  /// Emails present in ALL windows (intersection). Single window == that window.
  Set<String> get confirmedEmails {
    var wins = windows;
    while (wins.length > 1 && wins.last.isEmpty) {
      wins = wins.sublist(0, wins.length - 1);
    }
    if (wins.isEmpty) return {};
    if (wins.length == 1 && wins.first.isEmpty) return {};
    Set<String>? out;
    for (final w in wins) {
      final present = {for (final e in w.entries) if (e.value) e.key};
      out = out == null ? present : out.intersection(present);
    }
    return out ?? {};
  }

  /// All emails ever seen in this session (union of windows + names).
  Set<String> get allEmails => {
        for (final w in windows) ...w.keys,
        ...names.keys,
      };

  bool isPresent(String email) => confirmedEmails.contains(email.toLowerCase());

  int get presentCount => confirmedEmails.length;

  String toCsv({bool lenientOneOfTwo = false}) => buildSimpleCsv(
        names: names,
        rolls: rolls,
        windows: windows,
        lenientOneOfTwo: lenientOneOfTwo,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'courseId': courseId,
        'classLabel': classLabel,
        'dateIso': dateIso,
        'timestampIso': timestampIso,
        'startIso': startIso,
        'windows': [for (final w in windows) w],
        // Compat for old readers:
        'w1': w1,
        'w2': w2,
        'names': names,
        'rolls': rolls,
        'org': org,
        'faceFlags': faceFlags,
      };

  factory ClassRecord.fromJson(Map<String, dynamic> j) {
    List<Map<String, bool>>? wins;
    if (j['windows'] is List) {
      try {
        wins = [
          for (final e in (j['windows'] as List))
            Map<String, bool>.from((e as Map).map(
                (k, v) => MapEntry(k as String, (v as bool?) ?? false)))
        ];
      } catch (_) {
        wins = null;
      }
    }
    return ClassRecord(
      id: j['id'] as String? ?? '',
      courseId: j['courseId'] as String? ?? '',
      classLabel: j['classLabel'] as String? ?? '',
      dateIso: j['dateIso'] as String? ?? '',
      timestampIso: j['timestampIso'] as String? ?? '',
      startIso: j['startIso'] as String? ?? '',
      w1: wins == null
          ? (j['w1'] == null
              ? null
              : Map<String, bool>.from((j['w1'] as Map).map(
                  (k, v) => MapEntry(k as String, (v as bool?) ?? false))))
          : null,
      w2: wins == null
          ? (j['w2'] == null
              ? null
              : Map<String, bool>.from((j['w2'] as Map).map(
                  (k, v) => MapEntry(k as String, (v as bool?) ?? false))))
          : null,
      windows: wins,
      names: j['names'] is Map
          ? {
              for (final e in (j['names'] as Map).entries)
                '${e.key}': '${e.value ?? ''}',
            }
          : const {},
      rolls: j['rolls'] is Map
          ? {
              for (final e in (j['rolls'] as Map).entries)
                '${e.key}': '${e.value ?? ''}',
            }
          : const {},
      org: j['org'] as String? ?? '',
      faceFlags: [
        for (final e in (j['faceFlags'] as List? ?? const [])) '$e',
      ],
    );
  }
}

/// A professor's course (subject). Sessions ([ClassRecord]s with matching
/// [courseId]) group under it, most recent first.
class Course {
  final String name;
  final String createdAt; // ISO date
  const Course({required this.name, required this.createdAt});

  Map<String, dynamic> toJson() => {'name': name, 'createdAt': createdAt};

  factory Course.fromJson(Map<String, dynamic> j) =>
      Course(name: j['name'] as String? ?? '', createdAt: j['createdAt'] as String? ?? '');
}

/// Date-range matrix export for a course (req 6).
/// Rows keyed by email (primary key), sorted. Columns are the sessions in
/// [sessions] sorted by timestamp. Cell P = present (intersection of that
/// session's windows), A otherwise. Header dates are yyyy-MM-dd; when two
/// sessions share a date, time HH:mm is appended to disambiguate.
String buildDateRangeMatrix(List<ClassRecord> sessions) {
  final sorted = List.of(sessions)
    ..sort((a, b) => a.timestampIso.compareTo(b.timestampIso));
  if (sorted.isEmpty) return '';
  final dateCounts = <String, int>{};
  for (final s in sorted) {
    dateCounts[s.dateIso] = (dateCounts[s.dateIso] ?? 0) + 1;
  }
  String colLabel(ClassRecord s) {
    if ((dateCounts[s.dateIso] ?? 0) > 1) {
      var hm = '';
      try {
        final dt = DateTime.parse(s.timestampIso).toLocal();
        hm =
            ' ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      } catch (_) {}
      return '${s.dateIso}$hm';
    }
    return s.dateIso;
  }

  final emails = <String>{};
  final names = <String, String>{};
  final rolls = <String, String>{};
  for (final s in sorted) {
    emails.addAll(s.allEmails);
    names.addAll(s.names);
    rolls.addAll(s.rolls);
  }
  final ordered = emails.toList()..sort();
  final sb = StringBuffer('Name,ID Number,Email,');
  sb.writeln([for (final s in sorted) colLabel(s)].join(','));
  for (final e in ordered) {
    final cells = [
      for (final s in sorted) s.isPresent(e) ? 'P' : 'A',
    ];
    sb.writeln(
        '${csvCell(names[e] ?? '')},${csvCell(rolls[e] ?? '')},${csvCell(e)},${cells.join(',')}');
  }
  return sb.toString();
}

/// Sessions in [sessions] whose dateIso lies in [start,end] inclusive.
/// Dates are yyyy-MM-dd strings (lexicographic compare is chronological).
List<ClassRecord> sessionsInRange(
    List<ClassRecord> sessions, String startIso, String endIso) {
  final out = sessions
      .where((s) => s.dateIso.compareTo(startIso) >= 0 && s.dateIso.compareTo(endIso) <= 0)
      .toList()
    ..sort((a, b) => a.timestampIso.compareTo(b.timestampIso));
  return out;
}

/// Deletion warning stats (req 8): X = unique students present even once
/// (true in ANY window of ANY selected session), Y = selected sessions.
({int students, int sessions}) deletionStats(List<ClassRecord> selected) {
  final union = <String>{};
  for (final s in selected) {
    for (final w in s.windows) {
      for (final e in w.entries) {
        if (e.value) union.add(e.key);
      }
    }
  }
  return (students: union.length, sessions: selected.length);
}
