// DeviceStore abstract interface + StoredEnrollment.
// Split out of core/device_store.dart (M6 sync refactor) — bodies verbatim.
// Backends live in secure_store.dart / memory_store.dart; shared pure
// helpers in record_helpers.dart.
library;

import 'package:proximity_storage/storage.dart';

class StoredEnrollment {
  final String email;
  final String name;
  final String roll;
  /// SKey Ed25519 seed: DKey-sealed ciphertext hex in production (only
  /// ciphertext at rest — unwrap needs the HW DKey; a backup-restore
  /// clone fails unwrap → 'restore detected — re-enroll'). Raw seed hex
  /// in tests / legacy docs (sealedKeyHex empty → raw path).
  final String seedHex;
  final String pkHex;
  /// DKey-sealed SKey envelope hex ('' = unsealed legacy/test path).
  final String sealedKeyHex;
  /// Opaque face identity: sha256(gmailLower+installId) hex — never raw
  /// Gmail. The plugin store is keyed by this. '' = never enrolled.
  final String faceId;
  final DateTime enrolledAt;
  /// Pipeline tag that produced the enrollment
  /// (`face_verification/<pkgVer>+<assetHash8>`). '' = pre-plugin
  /// template → always stale → forced re-face, key kept.
  final String verifierVer;
  final String org; // Google-account domain (see orgOf), '' = legacy
  // --- Device binding (Track 3), persisted locally for dSig + heartbeat.
  /// DKey public bytes hex ('' = unbound legacy).
  final String pkDHex;
  /// Attestation level wire name ('FULL'/'STD'/'NONE').
  final String attestationLevel;
  final DateTime attestedAt;
  final DateTime attestedUntil;
  StoredEnrollment({
    required this.email,
    required this.name,
    required this.roll,
    required this.seedHex,
    required this.pkHex,
    this.sealedKeyHex = '',
    this.faceId = '',
    required this.enrolledAt,
    this.verifierVer = '',
    this.org = '',
    this.pkDHex = '',
    this.attestationLevel = 'NONE',
    DateTime? attestedAt,
    DateTime? attestedUntil,
  })  : attestedAt = attestedAt ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        attestedUntil = attestedUntil ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  /// Stale pipeline: anything not stamped with the current plugin
  /// verifierVer is incomparable — forced re-face, key kept.
  bool isFaceStale(String currentVerifierVer) =>
      faceId.isEmpty || verifierVer != currentVerifierVer;

  Map<String, dynamic> toJson() => {
        'email': email,
        'name': name,
        'roll': roll,
        'seedHex': seedHex,
        'pkHex': pkHex,
        'sealedKeyHex': sealedKeyHex,
        'faceId': faceId,
        'enrolledAt': enrolledAt.toIso8601String(),
        'verifierVer': verifierVer,
        'org': org,
        'pkDHex': pkDHex,
        'attestationLevel': attestationLevel,
        'attestedAt': attestedAt.toIso8601String(),
        'attestedUntil': attestedUntil.toIso8601String(),
      };

  factory StoredEnrollment.fromJson(Map<String, dynamic> j) {
    // Legacy migration: pre-plugin docs carried templateCsv/modelVer
    // (deleted — embeddings incomparable with the plugin FaceNet space).
    // They map to faceId '' + verifierVer = old modelVer (or ''), so the
    // stale check forces re-face while the SKey is kept.
    final legacyModel = j['modelVer'] as String? ?? '';
    final hasTemplate =
        (j['templateCsv'] as String?)?.trim().isNotEmpty ?? false;
    return StoredEnrollment(
      email: j['email'] as String,
      name: j['name'] as String,
      roll: j['roll'] as String? ?? '',
      seedHex: j['seedHex'] as String,
      pkHex: j['pkHex'] as String,
      sealedKeyHex: j['sealedKeyHex'] as String? ?? '',
      faceId: j['faceId'] as String? ?? '',
      enrolledAt: DateTime.parse(j['enrolledAt'] as String),
      verifierVer: j['verifierVer'] as String? ??
          (hasTemplate ? legacyModel : ''),
      org: j['org'] as String? ?? '',
      pkDHex: j['pkDHex'] as String? ?? '',
      attestationLevel: j['attestationLevel'] as String? ?? 'NONE',
      attestedAt: j['attestedAt'] == null
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.parse(j['attestedAt'] as String),
      attestedUntil: j['attestedUntil'] == null
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.parse(j['attestedUntil'] as String),
    );
  }
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
