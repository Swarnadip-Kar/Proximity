// DeviceStore abstract interface + StoredEnrollment.
// Backends live in secure_store.dart / memory_store.dart; shared pure
// helpers in record_helpers.dart.
library;

import 'package:proximity_storage/storage.dart';

import '../../security/revocation_cache.dart' show RevocationHashStore;

class StoredEnrollment {
  // One record (fresh-only): the HW-sealed enrollment (faceId,
  // verifierVer, sealed SKey, DKey binding) rides a single JSON doc.
  // There is no raw-seed field and no pre-plugin compat: unknown keys
  // are ignored on parse, missing keys default to never-enrolled/stale
  // (re-enroll). No IMEI/serial/phone-ID ever lives here (install UUID
  // only).
  final String email;
  final String name;
  final String roll;
  final String pkHex;
  /// DKey-sealed SKey envelope hex ('' = never-enrolled; sealed-only —
  /// empty means re-enroll, never a raw fallback).
  final String sealedKeyHex;
  /// HW attestation chain, leaf-first DER hex (security §2 + §7
  /// `attestationChain` wire form). `[]` = unbound (never confirms —
  /// manual path only). Never contains IMEI/serial — X.509 certs only,
  /// verified offline against pinned roots (see `AttestationChain` in
  /// protocol).
  final List<String> chainDERHex;
  /// Opaque face identity: sha256(gmailLower+installId) hex — never raw
  /// Gmail. The plugin store is keyed by this. '' = never enrolled.
  final String faceId;
  final DateTime enrolledAt;
  /// Pipeline tag that produced the enrollment
  /// (`face_verification/<pkgVer>+<assetHash8>`). '' = never-enrolled →
  /// always stale → forced re-face, key kept.
  final String verifierVer;
  final String org; // Google-account domain (see orgOf), '' = unstamped
  /// DKey public bytes hex ('' = unbound — never confirms).
  final String pkDHex;
  /// Attestation level wire name ('FULL'/'STD'/'NONE').
  final String attestationLevel;
  final DateTime attestedAt;
  final DateTime attestedUntil;
  /// Last SAVED face re-scan stamp, UTC epoch millis (0 = never rescanned
  /// → allowed; covers pre-upgrade docs missing the key). Stamped only by
  /// a successful rescan save (EnrollmentController.upload replacing an
  /// existing template); first enrollment leaves 0, started-but-unsaved
  /// rescans never stamp. Additive migration: old docs parse with 0.
  final int lastFaceRescanAtMillis;
  StoredEnrollment({
    required this.email,
    required this.name,
    required this.roll,
    required this.pkHex,
    this.sealedKeyHex = '',
    List<String>? chainDERHex,
    this.faceId = '',
    required this.enrolledAt,
    this.verifierVer = '',
    this.org = '',
    this.pkDHex = '',
    this.attestationLevel = 'NONE',
    DateTime? attestedAt,
    DateTime? attestedUntil,
    this.lastFaceRescanAtMillis = 0,
  })  : chainDERHex = List.unmodifiable(chainDERHex ?? const <String>[]),
        attestedAt = attestedAt ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        attestedUntil = attestedUntil ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  /// Last saved rescan as a UTC DateTime (epoch 0 = never rescanned).
  DateTime get lastFaceRescanAt => DateTime.fromMillisecondsSinceEpoch(
      lastFaceRescanAtMillis,
      isUtc: true);

  /// Stale pipeline: anything not stamped with the current plugin
  /// verifierVer is incomparable — forced re-face, key kept.
  bool isFaceStale(String currentVerifierVer) =>
      faceId.isEmpty || verifierVer != currentVerifierVer;

  Map<String, dynamic> toJson() => {
        'email': email,
        'name': name,
        'roll': roll,
        // Security §2 sealed-only: `sealedKeyHex` + `pkDHex` + `chainDERHex`.
        'pkHex': pkHex,
        'sealedKeyHex': sealedKeyHex,
        'chainDERHex': List<String>.of(chainDERHex),
        // Firestore wire alias (security §7 `attestationChain`): written
        // alongside for forward-compat with sec-sync claim/sync layers.
        'attestationChain': List<String>.of(chainDERHex),
        'faceId': faceId,
        'enrolledAt': enrolledAt.toIso8601String(),
        'verifierVer': verifierVer,
        'org': org,
        'pkDHex': pkDHex,
        'attestationLevel': attestationLevel,
        'attestedAt': attestedAt.toIso8601String(),
        'attestedUntil': attestedUntil.toIso8601String(),
        'lastFaceRescanAtMillis': lastFaceRescanAtMillis,
      };

  factory StoredEnrollment.fromJson(Map<String, dynamic> j) {
    // Fresh-only: unknown keys (incl. any pre-plugin `templateCsv` /
    // `modelVer` / `seedHex`) are ignored. Missing keys default to
    // never-enrolled/stale (faceId '' → forced re-face).
    // chainDERHex: local `chainDERHex` or Firestore wire
    // `attestationChain` (security §7), else unbound ([] — never confirms).
    List<String> chainFromJson(Map<String, dynamic> j) {
      final raw = j['chainDERHex'] ?? j['attestationChain'];
      if (raw is List) {
        return [
          for (final e in raw)
            if (e is String && e.trim().isNotEmpty) e.trim()
        ];
      }
      return const <String>[];
    }

    return StoredEnrollment(
      email: j['email'] as String,
      name: j['name'] as String,
      roll: j['roll'] as String? ?? '',
      pkHex: j['pkHex'] as String,
      sealedKeyHex: j['sealedKeyHex'] as String? ?? '',
      chainDERHex: chainFromJson(j),
      faceId: j['faceId'] as String? ?? '',
      enrolledAt: DateTime.parse(j['enrolledAt'] as String),
      verifierVer: j['verifierVer'] as String? ?? '',
      org: j['org'] as String? ?? '',
      pkDHex: j['pkDHex'] as String? ?? '',
      attestationLevel: j['attestationLevel'] as String? ?? 'NONE',
      attestedAt: j['attestedAt'] == null
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.parse(j['attestedAt'] as String),
      attestedUntil: j['attestedUntil'] == null
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.parse(j['attestedUntil'] as String),
      lastFaceRescanAtMillis:
          (j['lastFaceRescanAtMillis'] as num?)?.toInt() ?? 0,
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

  /// Per-course opt-in: show the hosting professor's Gmail profile photo
  /// to joining students (gated /window unicast). Absent = false (off by
  /// default — students see initials until the professor opts in).
  Future<bool> readShowProfPhoto(String course);
  Future<void> writeShowProfPhoto(String course, bool show);

  /// Student-side cache: the hosting professor's Gmail photo per course,
  /// saved when a gated /window poll delivers one. Absent = '' (no photo
  /// seen yet). Lets the course LIST show the photo offline; the waiting
  /// room always prefers the live poll value.
  Future<String> readCourseProfPhoto(String course);
  Future<void> writeCourseProfPhoto(String course, String photoUrl);

  /// Last professor host joined (host:port) for one-tap rejoin.
  Future<String?> readLastHost();
  Future<void> writeLastHost(String hostPort);

  /// Professor export default location (absolute directory path, per
  /// device). Null/'' = no custom location → system Downloads. Lives
  /// next to the other per-device prefs (host name, last host).
  Future<String?> readExportDir();
  Future<void> writeExportDir(String path);
  Future<void> clearExportDir();

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
  /// see processPendingAdds in core/sync/queue.dart). Plain JSON maps.
  Future<List<Map<String, dynamic>>> readPendingAdds();
  Future<void> writePendingAdds(List<Map<String, dynamic>> items);

  /// keyed by record id + per-entry retry state (see PendingSession in
  /// sync/sessions.dart). Every local history mutation upserts the outbox
  /// in the same call (SyncEngine.saveSessionLocal); the flush pushes due
  /// entries per-course FIFO and rewrites the remainder once at the end
  /// (partial-failure discipline). Plain JSON maps.
  Future<List<Map<String, dynamic>>> readPendingSessions();
  Future<void> writePendingSessions(List<Map<String, dynamic>> items);

  /// Durable delete tombstones (see SessionTombstone in
  /// sync/sessions.dart): deletes win over older upserts across merges AND
  /// propagate to the cloud on flush. Plain JSON maps.
  Future<List<Map<String, dynamic>>> readTombstones();
  Future<void> writeTombstones(List<Map<String, dynamic>> items);

  /// Last synced student attendance (My Attendance cache): the pulled
  /// cloud sessions containing this Gmail, so records stay visible
  /// offline and course renames/attendance pushes converge here on the
  /// next pull. Replaced wholesale on every successful pull.
  Future<List<ClassRecord>> readStudentSessions();
  Future<void> writeStudentSessions(List<ClassRecord> records);

  /// H8 CRL-hash backend (secure-store wiring): null by default
  /// (memory/test stores — the hash travels in the prefs sidecar);
  /// [SecureDeviceStore] serves the biometric-bound backend so a
  /// prefs-only edit cannot go undetected. Callers pass this straight
  /// into `RevocationCache.load/refreshBestEffort` (null = sidecar).
  RevocationHashStore? get revocationHashStore => null;

  /// Professor lecture-key pins (anti-fake-professor, anybody-can-host):
  /// cached `profDevices/{email}` pin lists, keyed by lowercased prof email.
  /// Each entry is `{pkP, createdAtMillis}`. Prefs-backed (non-sensitive —
  /// public keys only). Empty list = no cache for that email (first-seen).
  Future<List<Map<String, dynamic>>> readProfPin(String emailLower);
  Future<void> writeProfPin(
      String emailLower, List<Map<String, dynamic>> keys);

  /// Student-key pins (anti-fake-student, rosterless phase): persistent
  /// emailLower → pkS-hex cache hydrated from the professor-readable
  /// directory (`studentDirectory` + `pkS`, same-org) whenever online.
  /// The live [ProxServer] pins enforce `unknown-pkS` offline from this
  /// map; first-seen (absent) emails stay TOFU with an
  /// `unverified-student-key` flag (visible, never silent). Public keys
  /// only — prefs-backed like the prof pins above.
  Future<Map<String, String>> readStudentKeyPins();
  Future<void> writeStudentKeyPins(Map<String, String> pins);

  /// Pending prof-email verifications (offline-first queue): prof emails
  /// first seen while offline (or with an empty pin cache) wait here for
  /// auto-verify when the app returns online (connectivity edge / resume /
  /// 15 min backstop). Lowercased emails, no PII beyond what the gated
  /// /window unicast already showed.
  Future<Set<String>> readPendingProfVerifications();
  Future<void> writePendingProfVerifications(Set<String> emails);
}
