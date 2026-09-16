// SecureDeviceStore (prod): flutter_secure_storage (enrollment secrets) +
// shared_preferences (history JSON). Split out of core/device_store.dart
// course-membership predicates, which now call the shared pure helper
// [recordInCourse] (see record_helpers.dart).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:proximity_storage/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../security/revocation_cache.dart' show RevocationHashStore;
import '../../security/secure_store_options.dart';
import 'record_helpers.dart';
import 'store_base.dart';
import '../../export_location.dart' show exportDirPrefsKey;

class SecureDeviceStore implements DeviceStore {
  static const _kEnroll = 'prox.enrollment.v1';
  static const _kHistory = 'prox.history.v1';
  static const _kCatalog = 'prox.catalog.v1';
  static const _kCourses = 'prox.courses.v1';
  static const _kMode = 'prox.mode.v1';
  static const _kHostName = 'prox.hostname.v1';
  static const _kShowProfPhoto = 'prox.showprofphoto.v1.';
  static const _kCourseProfPhoto = 'prox.courseprofphoto.v1.';
  static const _kLastHost = 'prox.lasthost.v1';
  final FlutterSecureStorage _secure;
  // Hardened at-rest posture (PROXIMITY_SECURITY.md §3, F3): biometric-bound
  // AES-GCM on Android (`enforceBiometrics:true`, `strongBiometricOnly`),
  // this-device-only unsynced Keychain on iOS (`synchronizable:false`,
  // `first_unlock_this_device`, `biometryCurrentSet`). Never revert to
  // `const FlutterSecureStorage()` defaults — the default AndroidOptions
  // allow device-credential fallback and the default IOSOptions are
  // syncable/migratable. This is the ENROLLMENT doc store (prompt-gated);
  // the HW seal DEK lives in the prompt-free `FlutterSealStore` (same FSS
  // plugin, ungated options — gated instead by the 4h HW grant + face).
  // The two instances MUST keep distinct Android `storageNamespace`s
  // ('prox_enroll' here via SecureStoreOptions.aOpts vs 'prox_seal' there):
  // different key ciphers sharing one namespace flip algorithm markers and
  // trigger migrate/reset wipes of each other's data.
  // Backup exclusion lives in AndroidManifest (`allowBackup=false`,
  // `fullBackupContent=false`) + res/xml/data_extraction_rules.xml.
  SecureDeviceStore({FlutterSecureStorage? secure})
      : _secure = secure ??
            const FlutterSecureStorage(
              aOptions: SecureStoreOptions.aOpts,
              iOptions: SecureStoreOptions.iOpts,
            );

  /// Test-only view of the wired storage (lets tests assert the hardened
  /// options are actually passed, not just that the constants exist).
  @visibleForTesting
  FlutterSecureStorage get debugSecureStorageForTest => _secure;

  /// Single SharedPreferences acquisition point (was 34 inline copies).
  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  // Process-local cache for the two biometric-gated reads (enrollment doc
  // + installId share the gated FSS instance). Root cause of the
  // fingerprint-on-every-prove: checkFaceAny reads enrollment, listen
  // reads it again, and every _prove rotation reads installId + signs —
  // each secure read re-prompts (Android enforceBiometrics, iOS
  // biometryCurrentSet). The HW 4h grant + face check already gate use,
  // so one prompt per process per value is enough; writes invalidate.
  StoredEnrollment? _enrollmentCache;
  bool _enrollmentLoaded = false;
  String? _installIdCache;
  bool _installIdLoaded = false;
  // Last secure-read failure (biometric cancel/lockout/dead keychain):
  // reads inside the cooldown return the cached value without touching
  // the store, so a cancel + 600ms auto-retry cannot hammer the prompt.
  DateTime? _lastSecureFailAt;
  static const _secureFailCooldown = Duration(seconds: 5);

  bool _inSecureCooldown(DateTime now) =>
      _lastSecureFailAt != null &&
      now.difference(_lastSecureFailAt!) < _secureFailCooldown;

  @override
  Future<StoredEnrollment?> readEnrollment() async {
    if (_enrollmentLoaded) return _enrollmentCache;
    final now = DateTime.now().toUtc();
    if (_inSecureCooldown(now)) return _enrollmentCache;
    // Fail-open: unsigned simulator builds have no keychain (err -34018);
    // a missing enrollment just means "enroll".
    String? raw;
    try {
      raw = await _secure.read(key: _kEnroll);
    } catch (_) {
      _lastSecureFailAt = now;
      return _enrollmentCache;
    }
    if (raw == null) {
      _enrollmentCache = null;
      _enrollmentLoaded = true;
      return null;
    }
    late final Map<String, dynamic> doc;
    late final StoredEnrollment parsed;
    try {
      doc = jsonDecode(raw) as Map<String, dynamic>;
      parsed = StoredEnrollment.fromJson(doc);
    } catch (_) {
      return null;
    }
    // Fresh-only (security §2 F1): no raw-seed migration — the doc is
    // sealed-only by construction. Unknown keys are ignored by fromJson.
    _enrollmentCache = parsed;
    _enrollmentLoaded = true;
    return parsed;
  }

  @override
  Future<void> writeEnrollment(StoredEnrollment e) async {
    await _secure.write(key: _kEnroll, value: jsonEncode(e.toJson()));
    _enrollmentCache = e;
    _enrollmentLoaded = true;
  }

  @override
  Future<void> clearEnrollment() async {
    await _secure.delete(key: _kEnroll);
    _enrollmentCache = null;
    _enrollmentLoaded = true;
  }

  @override
  Future<List<ClassRecord>> readHistory() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kHistory);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = <ClassRecord>[];
      for (final e in list) {
        try {
          if (e is Map) {
            out.add(ClassRecord.fromJson(Map<String, dynamic>.from(e)));
          }
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> appendHistory(ClassRecord record) async {
    final prefs = await _prefs();
    final cur = await readHistory();
    cur.add(record);
    await prefs.setString(
        _kHistory, jsonEncode(cur.map((e) => e.toJson()).toList()));
  }

  @override
  Future<List<String>> readCatalog() async {
    final prefs = await _prefs();
    return prefs.getStringList(_kCatalog) ?? const [];
  }

  @override
  Future<void> addClass(String label) async {
    final clean = label.trim();
    if (clean.isEmpty) return;
    final prefs = await _prefs();
    final cur = await readCatalog();
    if (!cur.contains(clean)) {
      await prefs.setStringList(_kCatalog, [...cur, clean]);
    }
  }

  @override
  Future<List<Course>> readCourses() async {
    final prefs = await _prefs();
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
      final out = <Course>[];
      for (final e in list) {
        try {
          if (e is Map) {
            final c =
                Course.fromJson(Map<String, dynamic>.from(e));
            if (c.name.isNotEmpty) out.add(c);
          }
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> addCourse(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    final prefs = await _prefs();
    final cur = await readCourses();
    if (cur.any((c) => c.name == clean)) return;
    cur.add(Course(name: clean, createdAt: todayIso()));
    await prefs.setString(
        _kCourses, jsonEncode(cur.map((e) => e.toJson()).toList()));
    await addClass(clean);
  }

  @override
  Future<bool> renameCourse(String oldName, String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty || clean == oldName) return false;
    final prefs = await _prefs();
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
        if (recordInCourse(r, oldName))
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
              org: r.org,
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
    final prefs = await _prefs();
    return prefs.getString(_kMode);
  }

  @override
  Future<void> writeMode(String? mode) async {
    final prefs = await _prefs();
    if (mode == null) {
      await prefs.remove(_kMode);
    } else {
      await prefs.setString(_kMode, mode);
    }
  }

  @override
  Future<String> readHostName() async {
    final prefs = await _prefs();
    return prefs.getString(_kHostName) ?? '';
  }

  @override
  Future<void> writeHostName(String name) async {
    final prefs = await _prefs();
    await prefs.setString(_kHostName, name.trim());
  }

  @override
  Future<bool> readShowProfPhoto(String course) async {
    final prefs = await _prefs();
    return prefs.getBool('$_kShowProfPhoto${course.trim()}') ?? false;
  }

  @override
  Future<void> writeShowProfPhoto(String course, bool show) async {
    final key = course.trim();
    if (key.isEmpty) return;
    final prefs = await _prefs();
    await prefs.setBool('$_kShowProfPhoto$key', show);
  }

  @override
  Future<String> readCourseProfPhoto(String course) async {
    final prefs = await _prefs();
    return prefs.getString('$_kCourseProfPhoto${course.trim()}') ?? '';
  }

  @override
  Future<void> writeCourseProfPhoto(String course, String photoUrl) async {
    final key = course.trim();
    final url = photoUrl.trim();
    if (key.isEmpty || url.isEmpty) return;
    final prefs = await _prefs();
    await prefs.setString('$_kCourseProfPhoto$key', url);
  }

  @override
  Future<String?> readLastHost() async {
    final prefs = await _prefs();
    return prefs.getString(_kLastHost);
  }

  @override
  Future<void> writeLastHost(String hostPort) async {
    final prefs = await _prefs();
    await prefs.setString(_kLastHost, hostPort.trim());
  }

  @override
  Future<String?> readExportDir() async {
    final prefs = await _prefs();
    final v = (prefs.getString(exportDirPrefsKey) ?? '').trim();
    return v.isEmpty ? null : v;
  }

  @override
  Future<void> writeExportDir(String path) async {
    final clean = path.trim();
    if (clean.isEmpty) return;
    final prefs = await _prefs();
    await prefs.setString(exportDirPrefsKey, clean);
  }

  @override
  Future<void> clearExportDir() async {
    final prefs = await _prefs();
    await prefs.remove(exportDirPrefsKey);
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
      final prefs = await _prefs();
      await prefs.setString(
          _kCourses, jsonEncode(courses.map((e) => e.toJson()).toList()));
      coursesRemoved = 1;
    }
    final history = await readHistory();
    final keep = history.where((r) => !recordInCourse(r, name)).toList();
    final sessionsRemoved = history.length - keep.length;
    if (sessionsRemoved > 0) await writeHistory(keep);
    final prefs = await _prefs();
    final catalog = await readCatalog();
    if (catalog.contains(name)) {
      await prefs.setStringList(
          _kCatalog, catalog.where((c) => c != name).toList());
    }
    return (coursesRemoved, sessionsRemoved);
  }

  @override
  Future<void> writeHistory(List<ClassRecord> records) async {
    final prefs = await _prefs();
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
    final prefs = await _prefs();
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
    if (v == null) return null;
    try {
      if (v is! Map) return null;
      return Map<String, dynamic>.from(v);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeSession(String course, Map<String, dynamic> draft) async {
    final prefs = await _prefs();
    final all = await _readSessions();
    all[course] = draft;
    await prefs.setString(_kSessions, jsonEncode(all));
  }

  @override
  Future<void> clearSession(String course) async {
    final prefs = await _prefs();
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
    final prefs = await _prefs();
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
    final prefs = await _prefs();
    await prefs.setString(_kRole, jsonEncode(role));
  }

  @override
  Future<void> clearRole() async {
    final prefs = await _prefs();
    await prefs.remove(_kRole);
  }

  @override
  Future<String?> readInstallId() async {
    if (_installIdLoaded) return _installIdCache;
    final now = DateTime.now().toUtc();
    if (_inSecureCooldown(now)) return _installIdCache;
    try {
      final v = await _secure.read(key: _kInstall);
      _installIdCache = v;
      _installIdLoaded = true;
      return v;
    } catch (_) {
      _lastSecureFailAt = now;
      return _installIdCache;
    }
  }

  @override
  Future<void> writeInstallId(String id) async {
    await _secure.write(key: _kInstall, value: id);
    _installIdCache = id;
    _installIdLoaded = true;
  }

  @override
  Future<Set<String>> readHiddenSessions() async {
    final prefs = await _prefs();
    return prefs.getStringList(_kHidden)?.toSet() ?? {};
  }

  @override
  Future<void> hideSession(String id) async {
    final prefs = await _prefs();
    final cur = prefs.getStringList(_kHidden)?.toSet() ?? <String>{};
    cur.add(id);
    await prefs.setStringList(_kHidden, cur.toList());
  }

  @override
  Future<void> unhideSession(String id) async {
    final prefs = await _prefs();
    final cur = prefs.getStringList(_kHidden)?.toSet() ?? <String>{};
    cur.remove(id);
    await prefs.setStringList(_kHidden, cur.toList());
  }

  static const _kPendingAdds = 'prox.pendingAdds.v1';
  static const _kPendingSessions = 'prox.pendingSessions.v1';
  static const _kTombstones = 'prox.tombstones.v1';

  @override
  Future<List<Map<String, dynamic>>> readPendingAdds() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kPendingAdds);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = <Map<String, dynamic>>[];
      for (final e in list) {
        try {
          if (e is Map) out.add(Map<String, dynamic>.from(e));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> writePendingAdds(List<Map<String, dynamic>> items) async {
    final prefs = await _prefs();
    await prefs.setString(_kPendingAdds, jsonEncode(items));
  }

  Future<List<Map<String, dynamic>>> _readJsonList(String key) async {
    final prefs = await _prefs();
    final raw = prefs.getString(key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = <Map<String, dynamic>>[];
      for (final e in list) {
        try {
          if (e is Map) out.add(Map<String, dynamic>.from(e));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> readPendingSessions() =>
      _readJsonList(_kPendingSessions);

  @override
  Future<void> writePendingSessions(
      List<Map<String, dynamic>> items) async {
    final prefs = await _prefs();
    await prefs.setString(_kPendingSessions, jsonEncode(items));
  }

  @override
  Future<List<Map<String, dynamic>>> readTombstones() =>
      _readJsonList(_kTombstones);

  @override
  Future<void> writeTombstones(List<Map<String, dynamic>> items) async {
    final prefs = await _prefs();
    await prefs.setString(_kTombstones, jsonEncode(items));
  }

  @override
  Future<List<ClassRecord>> readStudentSessions() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kStudentSessions);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = <ClassRecord>[];
      for (final e in list) {
        try {
          if (e is Map) {
            out.add(ClassRecord.fromJson(Map<String, dynamic>.from(e)));
          }
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> writeStudentSessions(List<ClassRecord> records) async {
    final prefs = await _prefs();
    await prefs.setString(_kStudentSessions,
        jsonEncode(records.map((e) => e.toJson()).toList()));
  }

  /// H8 secure hash backend: the CRL integrity hash lives in the
  /// biometric-bound secure store (same instance/options as the
  /// enrollment doc), never the prefs sidecar.
  @override
  RevocationHashStore get revocationHashStore =>
      SecureRevocationHashStore(_secure);

  static const _kProfPins = 'prox.profPins.v1';

  @override
  Future<List<Map<String, dynamic>>> readProfPin(String emailLower) async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kProfPins);
    if (raw == null) return const [];
    try {
      final all = jsonDecode(raw) as Map<String, dynamic>;
      final list = all[emailLower.trim().toLowerCase()];
      if (list is! List) return const [];
      return [
        for (final e in list)
          if (e is Map) Map<String, dynamic>.from(e)
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> writeProfPin(
      String emailLower, List<Map<String, dynamic>> keys) async {
    final prefs = await _prefs();
    Map<String, dynamic> all = {};
    try {
      final raw = prefs.getString(_kProfPins);
      if (raw != null) all = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      all = {};
    }
    all[emailLower.trim().toLowerCase()] =
        [for (final e in keys) Map<String, dynamic>.from(e)];
    await prefs.setString(_kProfPins, jsonEncode(all));
  }

  static const _kStudentKeyPins = 'prox.studentKeyPins.v1';
  static const _kPendingProfVerify = 'prox.pendingProfVerify.v1';

  @override
  Future<Map<String, String>> readStudentKeyPins() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_kStudentKeyPins);
      if (raw == null) return const {};
      final all = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in all.entries)
          if (e.value is String &&
              e.key.trim().isNotEmpty &&
              (e.value as String).trim().isNotEmpty)
            e.key.trim().toLowerCase():
                (e.value as String).trim().toLowerCase(),
      };
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<void> writeStudentKeyPins(Map<String, String> pins) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(
          _kStudentKeyPins,
          jsonEncode({
            for (final e in pins.entries)
              if (e.key.trim().isNotEmpty && e.value.trim().isNotEmpty)
                e.key.trim().toLowerCase(): e.value.trim().toLowerCase(),
          }));
    } catch (_) {}
  }

  @override
  Future<Set<String>> readPendingProfVerifications() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_kPendingProfVerify);
      if (raw == null) return const {};
      final list = jsonDecode(raw) as List;
      return {
        for (final e in list)
          if (e is String && e.trim().isNotEmpty) e.trim().toLowerCase(),
      };
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<void> writePendingProfVerifications(Set<String> emails) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(
          _kPendingProfVerify,
          jsonEncode([
            for (final e in emails)
              if (e.trim().isNotEmpty) e.trim().toLowerCase(),
          ]));
    } catch (_) {}
  }
}

/// H8 [RevocationHashStore] backend (secure-store wiring): the CRL body
/// hash lives in `flutter_secure_storage` under a dedicated key, so a
/// prefs-only edit cannot go undetected (mismatch forces stale on load).
/// Fail-open like every revocation path: read/write never throw (a locked
/// keychain degrades to the prefs sidecar — detection preserved, the
/// secure copy is best-effort hardening, not a gate).
class SecureRevocationHashStore implements RevocationHashStore {
  static const key = 'prox.revocation.v1.sha256.secure';
  final FlutterSecureStorage _secure;
  const SecureRevocationHashStore(this._secure);

  @override
  Future<String?> readHash() async {
    try {
      return await _secure.read(key: key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeHash(String sha256Hex) async {
    try {
      await _secure.write(key: key, value: sha256Hex);
    } catch (_) {}
  }
}
