// InMemoryDeviceStore: tests and sim demos. Split out of
// core/device_store.dart (M6 sync refactor) — all bodies verbatim EXCEPT
// the byte-identical course-membership predicates, which now call the
// shared pure helper [recordInCourse] (see record_helpers.dart).
library;

import 'package:proximity_storage/storage.dart';

import 'record_helpers.dart';
import 'store_base.dart';

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
      if (recordInCourse(r, oldName)) {
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
    history.removeWhere((r) => recordInCourse(r, name));
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
