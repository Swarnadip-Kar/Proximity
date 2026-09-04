// Storage: SQLite tally (prof) + secure storage (keys/templates). (§8)
//
// P0 uses an in-memory tally with the exact CSV/export semantics; drift/SQLite
// file backing lands in P1 without changing callers.
// Attendance is keyed by Gmail account (no institute IDs).
library proximity_storage;

import 'package:proximity_protocol/protocol.dart';

enum MarkResult { present, pending, faceFlag, late }

class AttendanceRecord {
  final String email;
  final String name;
  String roll;
  bool w1 = false;
  bool w2 = false;
  bool faceFlag = false;
  bool late = false;
  AttendanceRecord(
      {required this.email, required this.name, this.roll = ''});

  String status({bool lenientOneOfTwo = false}) {
    final pass = lenientOneOfTwo ? (w1 || w2) : (w1 && w2);
    if (pass) return 'Present';
    if (w1 || w2) return 'Partial';
    return 'Absent';
  }
}

/// Professor tally: live counts + present/pending/face-flag/late lists + search.
class TallyStore {
  final Map<String, AttendanceRecord> _rows = {}; // email -> record

  void ensure(String email, String name, [String roll = '']) {
    final key = email.toLowerCase();
    final r = _rows.putIfAbsent(
        key, () => AttendanceRecord(email: key, name: name, roll: roll));
    if (roll.isNotEmpty) r.roll = roll;
  }

  void mark(String email, String name, int windowNo,
      {bool faceFlag = false, bool late = false, String roll = ''}) {
    ensure(email, name, roll);
    final r = _rows[email.toLowerCase()]!;
    if (windowNo == 1) {
      r.w1 = true;
    } else {
      r.w2 = true;
    }
    if (faceFlag) r.faceFlag = true;
    if (late) r.late = true;
  }

  void flagFace(String email, String name, [String roll = '']) {
    ensure(email, name, roll);
    _rows[email.toLowerCase()]!.faceFlag = true;
  }

  int get presentCount => _rows.values.where((r) => r.w1 || r.w2).length;

  List<AttendanceRecord> get present =>
      _rows.values.where((r) => r.w1 || r.w2).toList();
  List<AttendanceRecord> get pending =>
      _rows.values.where((r) => !(r.w1 || r.w2) && !r.faceFlag).toList();
  List<AttendanceRecord> get faceFlags =>
      _rows.values.where((r) => r.faceFlag).toList();
  List<AttendanceRecord> get lateList =>
      _rows.values.where((r) => r.late).toList();

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
        for (final e in _rows.entries) e.key: windowNo == 1 ? e.value.w1 : e.value.w2,
      };

  Map<String, String> nameMap() =>
      {for (final e in _rows.entries) e.key: e.value.name};

  Map<String, String> rollMap() =>
      {for (final e in _rows.entries) e.key: e.value.roll};

  String exportCsv(
      {required String classLabel,
      required String dateIso,
      bool lenientOneOfTwo = false}) =>
      buildAttendanceCsv(
        classLabel: classLabel,
        dateIso: dateIso,
        w1: windowMap(1),
        w2: windowMap(2),
        names: nameMap(),
        rolls: rollMap(),
        lenientOneOfTwo: lenientOneOfTwo,
      );

  int get size => _rows.length;
  void clear() => _rows.clear();

  ClassRecord toClassRecord(
          {required String courseId,
          required String classLabel,
          required String dateIso}) =>
      ClassRecord(
        courseId: courseId,
        classLabel: classLabel,
        dateIso: dateIso,
        w1: windowMap(1),
        w2: windowMap(2),
        names: nameMap(),
        rolls: rollMap(),
      );
}

/// One saved class session (professor device history). Exportable.
/// Belongs to a [Course] via [courseId] (the course name; records saved
/// before courses existed carry '' and group under their class label).
class ClassRecord {
  final String courseId;
  final String classLabel;
  final String dateIso; // yyyy-MM-dd
  final Map<String, bool> w1; // email -> present
  final Map<String, bool> w2;
  final Map<String, String> names; // email -> name
  final Map<String, String> rolls; // email -> ID number
  const ClassRecord({
    this.courseId = '',
    required this.classLabel,
    required this.dateIso,
    required this.w1,
    required this.w2,
    required this.names,
    required this.rolls,
  });

  int get w1Count => w1.values.where((v) => v).length;
  int get w2Count => w2.values.where((v) => v).length;

  String toCsv({bool lenientOneOfTwo = false}) => buildAttendanceCsv(
        classLabel: classLabel,
        dateIso: dateIso,
        w1: w1,
        w2: w2,
        names: names,
        rolls: rolls,
        lenientOneOfTwo: lenientOneOfTwo,
      );

  Map<String, dynamic> toJson() => {
        'courseId': courseId,
        'classLabel': classLabel,
        'dateIso': dateIso,
        'w1': w1,
        'w2': w2,
        'names': names,
        'rolls': rolls,
      };

  factory ClassRecord.fromJson(Map<String, dynamic> j) => ClassRecord(
        courseId: j['courseId'] as String? ?? '',
        classLabel: j['classLabel'] as String,
        dateIso: j['dateIso'] as String,
        w1: Map<String, bool>.from(j['w1'] as Map),
        w2: Map<String, bool>.from(j['w2'] as Map),
        names: Map<String, String>.from(j['names'] as Map),
        rolls: Map<String, String>.from(j['rolls'] as Map? ?? {}),
      );
}

/// A professor's course (subject). Sessions ([ClassRecord]s with matching
/// [courseId]) group under it, most recent first.
class Course {
  final String name;
  final String createdAt; // ISO date
  const Course({required this.name, required this.createdAt});

  Map<String, dynamic> toJson() => {'name': name, 'createdAt': createdAt};

  factory Course.fromJson(Map<String, dynamic> j) =>
      Course(name: j['name'] as String, createdAt: j['createdAt'] as String? ?? '');
}
