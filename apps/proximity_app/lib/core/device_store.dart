// On-device persistence: secure enrollment (key seed, identity, template)
// + class-history list. No face photos — template is an embedding vector;
// the key seed never leaves secure hardware-backed storage.
//
// [SecureDeviceStore] (prod) splits across flutter_secure_storage
// (enrollment secrets) and shared_preferences (history JSON).
// [InMemoryDeviceStore] drives tests and sim demos.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:proximity_storage/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StoredEnrollment {
  final String email;
  final String name;
  final String roll;
  final String seedHex; // Ed25519 seed, 32B hex
  final String pkHex;
  final String templateCsv; // embedding doubles
  final DateTime enrolledAt;
  const StoredEnrollment({
    required this.email,
    required this.name,
    required this.roll,
    required this.seedHex,
    required this.pkHex,
    required this.templateCsv,
    required this.enrolledAt,
  });

  List<double> get template =>
      templateCsv.split(',').map(double.parse).toList();

  static String csvOf(List<double> t) => t.join(',');

  Map<String, dynamic> toJson() => {
        'email': email,
        'name': name,
        'roll': roll,
        'seedHex': seedHex,
        'pkHex': pkHex,
        'templateCsv': templateCsv,
        'enrolledAt': enrolledAt.toIso8601String(),
      };

  factory StoredEnrollment.fromJson(Map<String, dynamic> j) =>
      StoredEnrollment(
        email: j['email'] as String,
        name: j['name'] as String,
        roll: j['roll'] as String? ?? '',
        seedHex: j['seedHex'] as String,
        pkHex: j['pkHex'] as String,
        templateCsv: j['templateCsv'] as String,
        enrolledAt: DateTime.parse(j['enrolledAt'] as String),
      );
}

abstract class DeviceStore {
  Future<StoredEnrollment?> readEnrollment();
  Future<void> writeEnrollment(StoredEnrollment e);
  Future<void> clearEnrollment();
  Future<List<ClassRecord>> readHistory();
  Future<void> appendHistory(ClassRecord record);

  /// Named class catalog enlisted by the professor (e.g. CS201-Room301).
  Future<List<String>> readCatalog();
  Future<void> addClass(String label);

  /// Persisted profile mode ('student'/'prof'/null). Relaunch restores it.
  Future<String?> readMode();
  Future<void> writeMode(String? mode);

  /// Optional professor display name shown with hosted classes.
  Future<String> readHostName();
  Future<void> writeHostName(String name);

  /// Courses (subjects) with creation dates. Sessions group by course name.
  Future<List<Course>> readCourses();
  Future<void> addCourse(String name);

  /// Renames a course and migrates its sessions (courseId + class label
  /// when the label was the old name). No-op for blank/duplicate names.
  Future<bool> renameCourse(String oldName, String newName);
}

class SecureDeviceStore implements DeviceStore {
  static const _kEnroll = 'prox.enrollment.v1';
  static const _kHistory = 'prox.history.v1';
  static const _kCatalog = 'prox.catalog.v1';
  static const _kCourses = 'prox.courses.v1';
  static const _kMode = 'prox.mode.v1';
  static const _kHostName = 'prox.hostname.v1';
  final FlutterSecureStorage _secure;
  SecureDeviceStore({FlutterSecureStorage? secure})
      : _secure = secure ?? const FlutterSecureStorage();

  @override
  Future<StoredEnrollment?> readEnrollment() async {
    // Fail-open: unsigned simulator builds have no keychain (err -34018);
    // a missing enrollment just means "enroll".
    String? raw;
    try {
      raw = await _secure.read(key: _kEnroll);
    } catch (_) {
      return null;
    }
    if (raw == null) return null;
    try {
      return StoredEnrollment.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeEnrollment(StoredEnrollment e) =>
      _secure.write(key: _kEnroll, value: jsonEncode(e.toJson()));

  @override
  Future<void> clearEnrollment() => _secure.delete(key: _kEnroll);

  @override
  Future<List<ClassRecord>> readHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kHistory);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => ClassRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> appendHistory(ClassRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    final cur = await readHistory();
    cur.add(record);
    await prefs.setString(
        _kHistory, jsonEncode(cur.map((e) => e.toJson()).toList()));
  }

  @override
  Future<List<String>> readCatalog() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kCatalog) ?? const [];
  }

  @override
  Future<void> addClass(String label) async {
    final clean = label.trim();
    if (clean.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final cur = await readCatalog();
    if (!cur.contains(clean)) {
      await prefs.setStringList(_kCatalog, [...cur, clean]);
    }
  }

  @override
  Future<List<Course>> readCourses() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kCourses);
    if (raw == null) {
      // Migrate legacy name catalog.
      return [
        for (final n in await readCatalog())
          Course(name: n, createdAt: '')
      ];
    }
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Course.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> addCourse(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final cur = await readCourses();
    if (cur.any((c) => c.name == clean)) return;
    cur.add(Course(name: clean, createdAt: _todayIso()));
    await prefs.setString(
        _kCourses, jsonEncode(cur.map((e) => e.toJson()).toList()));
    await addClass(clean);
  }

  @override
  Future<bool> renameCourse(String oldName, String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty || clean == oldName) return false;
    final prefs = await SharedPreferences.getInstance();
    final courses = await readCourses();
    if (courses.any((c) => c.name == clean)) return false;
    final idx = courses.indexWhere((c) => c.name == oldName);
    if (idx < 0) return false;
    courses[idx] = Course(name: clean, createdAt: courses[idx].createdAt);
    await prefs.setString(
        _kCourses, jsonEncode(courses.map((e) => e.toJson()).toList()));
    final history = await readHistory();
    var touched = false;
    final migrated = [
      for (final r in history)
        if (r.courseId == oldName ||
            (r.courseId.isEmpty && r.classLabel == oldName))
          () {
            touched = true;
            return ClassRecord(
              courseId: clean,
              classLabel: r.classLabel == oldName ? clean : r.classLabel,
              dateIso: r.dateIso,
              w1: r.w1,
              w2: r.w2,
              names: r.names,
              rolls: r.rolls,
            );
          }()
        else
          r
    ];
    if (touched) {
      await prefs.setString(_kHistory,
          jsonEncode(migrated.map((e) => e.toJson()).toList()));
    }
    final catalog = await readCatalog();
    final ci = catalog.indexOf(oldName);
    if (ci >= 0) {
      final next = List.of(catalog);
      next[ci] = clean;
      await prefs.setStringList(_kCatalog, next);
    }
    return true;
  }

  @override
  Future<String?> readMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kMode);
  }

  @override
  Future<void> writeMode(String? mode) async {
    final prefs = await SharedPreferences.getInstance();
    if (mode == null) {
      await prefs.remove(_kMode);
    } else {
      await prefs.setString(_kMode, mode);
    }
  }

  @override
  Future<String> readHostName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kHostName) ?? '';
  }

  @override
  Future<void> writeHostName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHostName, name.trim());
  }
}

String _todayIso() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}

class InMemoryDeviceStore implements DeviceStore {
  StoredEnrollment? enrollment;
  final List<ClassRecord> history = [];
  final List<String> catalog = [];
  String? mode;
  String hostName = '';

  @override
  Future<StoredEnrollment?> readEnrollment() async => enrollment;

  @override
  Future<void> writeEnrollment(StoredEnrollment e) async => enrollment = e;

  @override
  Future<void> clearEnrollment() async => enrollment = null;

  @override
  Future<List<ClassRecord>> readHistory() async => List.of(history);

  @override
  Future<void> appendHistory(ClassRecord record) async =>
      history.add(record);

  @override
  Future<List<String>> readCatalog() async => List.of(catalog);

  @override
  Future<void> addClass(String label) async {
    final clean = label.trim();
    if (clean.isNotEmpty && !catalog.contains(clean)) catalog.add(clean);
  }

  @override
  Future<List<Course>> readCourses() async =>
      [for (final n in catalog) Course(name: n, createdAt: '')];

  @override
  Future<void> addCourse(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    await addClass(clean);
  }

  @override
  Future<bool> renameCourse(String oldName, String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty || clean == oldName) return false;
    final idx = catalog.indexOf(oldName);
    if (idx < 0) return false;
    if (catalog.contains(clean)) return false;
    catalog[idx] = clean;
    for (var i = 0; i < history.length; i++) {
      final r = history[i];
      if (r.courseId == oldName ||
          (r.courseId.isEmpty && r.classLabel == oldName)) {
        history[i] = ClassRecord(
          courseId: clean,
          classLabel: r.classLabel == oldName ? clean : r.classLabel,
          dateIso: r.dateIso,
          w1: Map.of(r.w1),
          w2: Map.of(r.w2),
          names: Map.of(r.names),
          rolls: Map.of(r.rolls),
        );
      }
    }
    return true;
  }

  @override
  Future<String?> readMode() async => mode;

  @override
  Future<void> writeMode(String? m) async => mode = m;

  @override
  Future<String> readHostName() async => hostName;

  @override
  Future<void> writeHostName(String name) async => hostName = name.trim();
}

final deviceStoreProvider = Provider<DeviceStore>((ref) {
  throw UnimplementedError('Override in main / tests');
});
