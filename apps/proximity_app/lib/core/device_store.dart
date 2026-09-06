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
  /// Face pipeline version that produced [templateCsv] ([kFacePipelineVer]
  /// lives in core/edgeface.dart; import there to compare — this file stays
  /// dependency-free). '' = pre-version template → always stale.
  final String modelVer;
  const StoredEnrollment({
    required this.email,
    required this.name,
    required this.roll,
    required this.seedHex,
    required this.pkHex,
    required this.templateCsv,
    required this.enrolledAt,
    this.modelVer = '',
  });

  /// Fail-soft: a corrupt templateCsv (bad write, manual edit) yields an
  /// empty vector instead of throwing — callers treat it as inconclusive /
  /// stale and force recapture, never crash.
  List<double> get template {
    try {
      if (templateCsv.trim().isEmpty) return const [];
      return templateCsv.split(',').map(double.parse).toList();
    } catch (_) {
      return const [];
    }
  }

  static String csvOf(List<double> t) => t.join(',');

  Map<String, dynamic> toJson() => {
        'email': email,
        'name': name,
        'roll': roll,
        'seedHex': seedHex,
        'pkHex': pkHex,
        'templateCsv': templateCsv,
        'enrolledAt': enrolledAt.toIso8601String(),
        'modelVer': modelVer,
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
        modelVer: j['modelVer'] as String? ?? '',
      );
}

abstract class DeviceStore {
  Future<StoredEnrollment?> readEnrollment();
  Future<void> writeEnrollment(StoredEnrollment e);
  Future<void> clearEnrollment();
  Future<List<ClassRecord>> readHistory();
  Future<void> appendHistory(ClassRecord record);

  /// Inserts [record] or replaces the entry with the same id (per-round
  /// snapshot updates: later rounds rewrite the same class record instead
  /// of appending duplicates, so an un-closed session still leaves data).
  Future<void> upsertHistory(ClassRecord record);

  /// Named class catalog enlisted by the professor (e.g. CS201-Room301).
  Future<List<String>> readCatalog();
  Future<void> addClass(String label);

  /// Persisted profile mode ('student'/'prof'/null). Relaunch restores it.
  Future<String?> readMode();
  Future<void> writeMode(String? mode);

  /// Optional professor display name shown with hosted classes.
  Future<String> readHostName();
  Future<void> writeHostName(String name);

  /// Last professor host joined (host:port) for one-tap rejoin.
  Future<String?> readLastHost();
  Future<void> writeLastHost(String hostPort);

  /// Courses (subjects) with creation dates. Sessions group by course name.
  Future<List<Course>> readCourses();
  Future<void> addCourse(String name);

  /// Renames a course and migrates its sessions (courseId + class label
  /// when the label was the old name). No-op for blank/duplicate names.
  Future<bool> renameCourse(String oldName, String newName);

  /// Deletes sessions by [ids]. Returns the number removed.
  Future<int> deleteSessions(List<String> ids);

  /// Deletes a course and all its sessions. Returns (courses, sessions) removed.
  Future<(int, int)> deleteCourse(String name);

  /// Replaces the full history (used by deletion flows).
  Future<void> writeHistory(List<ClassRecord> records);

  /// Unsent attendance draft for [course] (autosaved live session that was
  /// left via back navigation or app kill; NOT yet exported to history).
  /// Shape: {windowNo, dateIso, savedAt, names, rolls, windows, windowNos}.
  /// Null when no draft exists.
  Future<Map<String, dynamic>?> readSession(String course);
  Future<void> writeSession(String course, Map<String, dynamic> draft);
  Future<void> clearSession(String course);

  /// Cached account roles for routing ({roles: 'prof,student', lastMode,
  /// email, uid, displayName} + legacy 'role' mirror). Set on register,
  /// cleared on sign-out / account switch. Local cache only — the cloud
  /// users/{uid} doc is authoritative when online.
  Future<Map<String, String>?> readRole();
  Future<void> writeRole(Map<String, String> role);
  Future<void> clearRole();

  /// Stable app-install UUID for the single-student-device binding
  /// (see device_identity.dart). Survives normal restarts; app-data clear /
  /// reinstall regenerates it (counts as a device move). App clones and
  /// work profiles hold their own installId — i.e. they count as a
  /// different device, which is exactly the anti-clone property wanted.
  Future<String?> readInstallId();
  Future<void> writeInstallId(String id);

  /// Student-hidden session ids ("delete entry from my account" removes it
  /// from THIS device's view only — professor/cloud data untouched).
  Future<Set<String>> readHiddenSessions();
  Future<void> hideSession(String id);
  Future<void> unhideSession(String id);

  /// Offline manual-add queue (professor typed an ID with no internet;
  /// each entry resolves against the student directory on the next sync —
  /// see processPendingAdds in widgets/manual_add.dart). Plain JSON maps.
  Future<List<Map<String, dynamic>>> readPendingAdds();
  Future<void> writePendingAdds(List<Map<String, dynamic>> items);

  /// Last synced student attendance (My Attendance cache): the pulled
  /// cloud sessions containing this Gmail, so records stay visible
  /// offline and course renames/attendance pushes converge here on the
  /// next pull. Replaced wholesale on every successful pull.
  Future<List<ClassRecord>> readStudentSessions();
  Future<void> writeStudentSessions(List<ClassRecord> records);
}

class SecureDeviceStore implements DeviceStore {
  static const _kEnroll = 'prox.enrollment.v1';
  static const _kHistory = 'prox.history.v1';
  static const _kCatalog = 'prox.catalog.v1';
  static const _kCourses = 'prox.courses.v1';
  static const _kMode = 'prox.mode.v1';
  static const _kHostName = 'prox.hostname.v1';
  static const _kLastHost = 'prox.lasthost.v1';
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
              id: r.id,
              courseId: clean,
              classLabel: r.classLabel == oldName ? clean : r.classLabel,
              dateIso: r.dateIso,
              timestampIso: r.timestampIso,
              startIso: r.startIso,
              windows: r.windows,
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

  @override
  Future<String?> readLastHost() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLastHost);
  }

  @override
  Future<void> writeLastHost(String hostPort) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastHost, hostPort.trim());
  }

  @override
  Future<int> deleteSessions(List<String> ids) async {
    final set = ids.toSet();
    final cur = await readHistory();
    final keep = cur.where((r) => !set.contains(r.id)).toList();
    final removed = cur.length - keep.length;
    if (removed > 0) await writeHistory(keep);
    return removed;
  }

  @override
  Future<(int, int)> deleteCourse(String name) async {
    final courses = await readCourses();
    final ci = courses.indexWhere((c) => c.name == name);
    var coursesRemoved = 0;
    if (ci >= 0) {
      courses.removeAt(ci);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kCourses, jsonEncode(courses.map((e) => e.toJson()).toList()));
      coursesRemoved = 1;
    }
    final history = await readHistory();
    final keep = history
        .where((r) =>
            !(r.courseId == name ||
                (r.courseId.isEmpty && r.classLabel == name)))
        .toList();
    final sessionsRemoved = history.length - keep.length;
    if (sessionsRemoved > 0) await writeHistory(keep);
    final prefs = await SharedPreferences.getInstance();
    final catalog = await readCatalog();
    if (catalog.contains(name)) {
      await prefs.setStringList(
          _kCatalog, catalog.where((c) => c != name).toList());
    }
    return (coursesRemoved, sessionsRemoved);
  }

  @override
  Future<void> writeHistory(List<ClassRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kHistory, jsonEncode(records.map((e) => e.toJson()).toList()));
  }

  @override
  Future<void> upsertHistory(ClassRecord record) async {
    final cur = await readHistory();
    final idx = cur.indexWhere((r) => r.id == record.id);
    if (idx < 0) {
      cur.add(record);
    } else {
      cur[idx] = record;
    }
    await writeHistory(cur);
  }

  static const _kSessions = 'prox.sessions.v1';

  Future<Map<String, dynamic>> _readSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSessions);
    if (raw == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  @override
  Future<Map<String, dynamic>?> readSession(String course) async {
    final all = await _readSessions();
    final v = all[course];
    return v == null ? null : Map<String, dynamic>.from(v as Map);
  }

  @override
  Future<void> writeSession(String course, Map<String, dynamic> draft) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await _readSessions();
    all[course] = draft;
    await prefs.setString(_kSessions, jsonEncode(all));
  }

  @override
  Future<void> clearSession(String course) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await _readSessions();
    if (all.remove(course) != null) {
      await prefs.setString(_kSessions, jsonEncode(all));
    }
  }

  static const _kRole = 'prox.role.v1';
  static const _kHidden = 'prox.hidden.v1';
  static const _kInstall = 'prox.install.v1';
  static const _kStudentSessions = 'prox.studentSessions.v1';

  @override
  Future<Map<String, String>?> readRole() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRole);
    if (raw == null) return null;
    try {
      return Map<String, String>.from(
          (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', '$v')));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeRole(Map<String, String> role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRole, jsonEncode(role));
  }

  @override
  Future<void> clearRole() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kRole);
  }

  @override
  Future<String?> readInstallId() async {
    try {
      return await _secure.read(key: _kInstall);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeInstallId(String id) =>
      _secure.write(key: _kInstall, value: id);

  @override
  Future<Set<String>> readHiddenSessions() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kHidden)?.toSet() ?? {};
  }

  @override
  Future<void> hideSession(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final cur = prefs.getStringList(_kHidden)?.toSet() ?? <String>{};
    cur.add(id);
    await prefs.setStringList(_kHidden, cur.toList());
  }

  @override
  Future<void> unhideSession(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final cur = prefs.getStringList(_kHidden)?.toSet() ?? <String>{};
    cur.remove(id);
    await prefs.setStringList(_kHidden, cur.toList());
  }

  static const _kPendingAdds = 'prox.pendingAdds.v1';

  @override
  Future<List<Map<String, dynamic>>> readPendingAdds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPendingAdds);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list) Map<String, dynamic>.from(e as Map)
      ];
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> writePendingAdds(List<Map<String, dynamic>> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPendingAdds, jsonEncode(items));
  }

  @override
  Future<List<ClassRecord>> readStudentSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kStudentSessions);
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
  Future<void> writeStudentSessions(List<ClassRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kStudentSessions,
        jsonEncode(records.map((e) => e.toJson()).toList()));
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
  String? lastHost;

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
          id: r.id,
          courseId: clean,
          classLabel: r.classLabel == oldName ? clean : r.classLabel,
          dateIso: r.dateIso,
          timestampIso: r.timestampIso,
          startIso: r.startIso,
          windows: [for (final w in r.windows) Map.of(w)],
          names: Map.of(r.names),
          rolls: Map.of(r.rolls),
        );
      }
    }
    return true;
  }

  @override
  Future<int> deleteSessions(List<String> ids) async {
    final set = ids.toSet();
    final before = history.length;
    history.removeWhere((r) => set.contains(r.id));
    return before - history.length;
  }

  @override
  Future<(int, int)> deleteCourse(String name) async {
    var coursesRemoved = 0;
    if (catalog.remove(name)) coursesRemoved = 1;
    final before = history.length;
    history.removeWhere((r) =>
        r.courseId == name || (r.courseId.isEmpty && r.classLabel == name));
    return (coursesRemoved, before - history.length);
  }

  @override
  Future<void> writeHistory(List<ClassRecord> records) async {
    history
      ..clear()
      ..addAll(records);
  }

  @override
  Future<void> upsertHistory(ClassRecord record) async {
    final idx = history.indexWhere((r) => r.id == record.id);
    if (idx < 0) {
      history.add(record);
    } else {
      history[idx] = record;
    }
  }

  final Map<String, Map<String, dynamic>> sessions = {};

  @override
  Future<Map<String, dynamic>?> readSession(String course) async =>
      sessions[course] == null ? null : Map.of(sessions[course]!);

  @override
  Future<void> writeSession(String course, Map<String, dynamic> draft) async =>
      sessions[course] = Map.of(draft);

  @override
  Future<void> clearSession(String course) async {
    sessions.remove(course);
  }

  @override
  Future<String?> readMode() async => mode;

  @override
  Future<void> writeMode(String? m) async => mode = m;

  @override
  Future<String> readHostName() async => hostName;

  @override
  Future<void> writeHostName(String name) async => hostName = name.trim();

  @override
  Future<String?> readLastHost() async => lastHost;

  @override
  Future<void> writeLastHost(String hostPort) async =>
      lastHost = hostPort.trim();

  Map<String, String>? _role;
  final Set<String> _hidden = {};
  String? _installId;

  @override
  Future<Map<String, String>?> readRole() async =>
      _role == null ? null : Map.of(_role!);

  @override
  Future<void> writeRole(Map<String, String> role) async {
    _role = Map.of(role);
  }

  @override
  Future<void> clearRole() async => _role = null;

  @override
  Future<String?> readInstallId() async => _installId;

  @override
  Future<void> writeInstallId(String id) async => _installId = id;

  @override
  Future<Set<String>> readHiddenSessions() async => Set.of(_hidden);

  @override
  Future<void> hideSession(String id) async => _hidden.add(id);

  @override
  Future<void> unhideSession(String id) async => _hidden.remove(id);

  final List<Map<String, dynamic>> _pendingAdds = [];

  @override
  Future<List<Map<String, dynamic>>> readPendingAdds() async =>
      [for (final e in _pendingAdds) Map<String, dynamic>.of(e)];

  @override
  Future<void> writePendingAdds(List<Map<String, dynamic>> items) async {
    _pendingAdds
      ..clear()
      ..addAll(items);
  }

  final List<ClassRecord> studentSessions = [];

  @override
  Future<List<ClassRecord>> readStudentSessions() async =>
      List.of(studentSessions);

  @override
  Future<void> writeStudentSessions(List<ClassRecord> records) async {
    studentSessions
      ..clear()
      ..addAll(records);
  }
}

final deviceStoreProvider = Provider<DeviceStore>((ref) {
  throw UnimplementedError('Override in main / tests');
});
