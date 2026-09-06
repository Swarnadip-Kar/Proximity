// Cloud sync: professor session backup + student device binding + roles.
// Firestore collections (see firestore.rules):
//   users/{uid}: {email, name, roles[prof|student], displayName, lastMode,
//     updatedAt} — one doc per Firebase uid; the SAME Gmail can hold BOTH
//     roles (prof multi-device, student single-device). lastMode is the last
//     used mode (landing + relaunch default). Local history stays source of
//     truth for sessions.
//   studentDevices/{emailLower}: {email, uid, pkHex, installId, name, roll,
//     modelVer, platform, createdAt/lastMoveAt/lastSeenAt/updatedAtMillis,
//     moveCount} — one enrolled student device per Gmail. Same-device writes
//     (pkHex or installId unchanged) are always allowed; moves to a different
//     device need a 7-day cooldown (request.time - lastMoveAtMillis > 7d)
//     unless the doc predates timestamps (one migration move). Clients claim
//     via a transaction so racing devices resolve to exactly one winner.
//     NO reset path exists by design: professor registration is
//     self-asserted this phase, so any reset permission would let a student
//     self-reset around the cooldown. Genuine loss waits out the week;
//     manual attendance covers the gap. Face photos/templates are NEVER
//     written here — only the device public key + install id.
//   studentDirectory/{emailLower}: {email, name, roll, nameLower,
//     updatedAtMillis} — minimal professor-searchable directory, maintained
//     by the claim transaction. Professors (role-gated) prefix-search it to
//     add students to records; students read only their own doc. NOTE: the
//     prof gate is advisory until professor roles are institute-verified —
//     any self-registered prof can list it (emails/names/rolls only).
//   deviceInstalls/{installId}: {email, pkHex, updatedAtMillis} — one
//     student Gmail per app install. Stops the same phone (incl. app clones,
//     which get their own installId) from holding two student enrollments.
//   classSessions/{sessionId}: {courseId, courseName, classLabel, profUid,
//     profEmail, profName, dateIso, timestampIso, startIso, windows, names,
//     rolls, studentEmails[], updatedAt}
//   classSessions/{sessionId}: {courseId, courseName, classLabel, profUid,
//     profEmail, profName, dateIso, timestampIso, startIso, windows, names,
//     rolls, studentEmails[], updatedAt}
// Local history stays the offline source of truth; cloud is the sync copy.
// Firestore offline persistence queues writes automatically — first sign-in
// merges both ways, later changes push on save and pull on open/refresh.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_storage/storage.dart';

/// Professor and/or student role record. One doc per Firebase uid — the same
/// Gmail can hold BOTH roles (professor on many devices, student on one).
/// [role] is the legacy single-role constructor param (maps to roles:[role]);
/// new code passes [roles]. [lastMode] ('prof'|'student'|'') is the last used
/// mode and drives the landing default + relaunch routing.
class RoleDoc {
  final String uid;
  final String email;
  final String name;
  final List<String> roles; // subset of ['prof', 'student']
  final String displayName;
  final String lastMode;
  RoleDoc(
      {required this.uid,
      required this.email,
      required this.name,
      List<String>? roles,
      String? role,
      this.displayName = '',
      this.lastMode = ''})
      : roles = roles ??
            (role != null && role.isNotEmpty ? [role] : const <String>[]);

  /// Legacy single-role read (first role, or ''). New code uses [roles].
  String get role => roles.isEmpty ? '' : roles.first;
  bool get isProf => roles.contains('prof');
  bool get isStudent => roles.contains('student');
}

/// Local role-cache helpers. Cache shape (see DeviceStore.readRole):
/// {roles: 'prof,student', lastMode: 'prof'|'student', email, uid,
///  displayName} plus a legacy mirror 'role' (= lastMode or first role).

/// Parses held roles from a cache map (legacy single 'role' supported).
Set<String> roleSet(Map<String, String>? role) {
  if (role == null) return const {};
  final out = <String>{};
  for (final part in (role['roles'] ?? '').split(',')) {
    final r = part.trim();
    if (r == 'prof' || r == 'student') out.add(r);
  }
  final legacy = (role['role'] ?? '').trim();
  if (legacy == 'prof' || legacy == 'student') out.add(legacy);
  return out;
}

/// True when the cached role belongs to [email] and holds [which].
bool roleHas(Map<String, String>? role, String which, {String? email}) {
  if (role == null) return false;
  if (email != null &&
      (role['email'] ?? '').toLowerCase() != email.toLowerCase()) {
    return false;
  }
  return roleSet(role).contains(which);
}

/// Last used mode from cache ('prof'|'student'|'').
String roleLastMode(Map<String, String>? role) {
  if (role == null) return '';
  final m = (role['lastMode'] ?? '').trim();
  if (m == 'prof' || m == 'student') return m;
  final set = roleSet(role);
  if (set.length == 1) return set.first;
  return '';
}

/// Merges a registration/continue event into a role-cache map.
Map<String, String> mergeRoleCache(Map<String, String>? existing,
    {required String email,
    required String uid,
    String displayName = '',
    String? addRole,
    String? lastMode}) {
  final set = {...roleSet(existing)};
  if (addRole == 'prof') {
    set.add('prof');
  } else if (addRole == 'student') {
    set.add('student');
  }
  final prev = existing ?? const <String, String>{};
  final mode = (lastMode == 'prof' || lastMode == 'student')
      ? lastMode!
      : (prev['lastMode'] ?? '');
  final ordered = [
    if (set.contains('prof')) 'prof',
    if (set.contains('student')) 'student'
  ];
  final primary = mode.isNotEmpty
      ? mode
      : (ordered.isNotEmpty ? ordered.first : '');
  return {
    'roles': ordered.join(','),
    'role': primary, // legacy mirror
    'lastMode': mode,
    'email': email.toLowerCase(),
    'uid': uid,
    'displayName': displayName,
  };
}

/// One enrolled student device per Gmail (client + rules enforce).
/// [installId] is the app-install UUID (secure storage; app clones and work
/// profiles get their own, so a clone counts as a different device).
/// Millis fields are UTC epoch ms: [createdAtMillis] first bind,
/// [lastMoveAtMillis] last device change (0/legacy = pre-timestamp doc —
/// the next move is allowed once and stamps it), [lastSeenAtMillis] last
/// online touch from the bound device (powers the lost-phone story:
/// professors see recency in the console, students see their retry date).
class StudentDeviceDoc {
  final String email; // lowercased
  final String uid;
  final String pkHex;
  final String name;
  final String roll;
  final String modelVer;
  final String installId;
  final String platform;
  final int createdAtMillis;
  final int lastMoveAtMillis;
  final int lastSeenAtMillis;
  final int updatedAtMillis;
  final int moveCount;
  const StudentDeviceDoc(
      {required this.email,
      required this.uid,
      required this.pkHex,
      required this.name,
      required this.roll,
      required this.modelVer,
      this.installId = '',
      this.platform = '',
      this.createdAtMillis = 0,
      this.lastMoveAtMillis = 0,
      this.lastSeenAtMillis = 0,
      this.updatedAtMillis = 0,
      this.moveCount = 0});
}

/// Minimum gap between two different-device enrollments of one Gmail.
/// Genuine phone loss waits this out (unlimited moves, at most one per
/// week); ping-ponging two phones cannot. No reset shortcut exists: any
/// reset permission would be self-service since professor registration is
/// self-asserted this phase.
const kStudentMoveCooldown = Duration(days: 7);

/// Verdict of [evaluateStudentClaim].
enum StudentClaim {
  /// No binding yet and this install holds no other Gmail: bind freely.
  firstBind,
  /// Same app install (installId matches; legacy docs without one still
  /// honor a pk match for migration): re-key / touch freely.
  sameDevice,
  /// Different device and the cooldown since the last move elapsed: move.
  /// (Unlimited moves lifetime, at most one per [kStudentMoveCooldown].)
  allowedMove,
  /// Different device but moved too recently: refuse until [retryAfter].
  /// Genuine loss waits this out; manual attendance covers the gap.
  cooldownBlocked,
  /// This app install is enrolled as a DIFFERENT Gmail: hard refuse (wipe
  /// app data to switch identity). One install = one student Gmail, so the
  /// same phone — clones included — can never hold two enrollments.
  installConflict,
}

class StudentClaimResult {
  final StudentClaim claim;
  final DateTime? retryAfter; // cooldownBlocked only
  final String? installEmail; // installConflict only
  const StudentClaimResult(this.claim, {this.retryAfter, this.installEmail});
  bool get ok => claim == StudentClaim.firstBind ||
      claim == StudentClaim.sameDevice ||
      claim == StudentClaim.allowedMove;
}

/// Pure claim verdict shared by the Firestore transaction, the fake, and
/// the landing pre-check (so the UI refuses for exactly the reasons the
/// server refuses). [installEmail] is deviceInstalls[installId].email.
StudentClaimResult evaluateStudentClaim({
  required String localPkHex,
  required String localInstallId,
  required StudentDeviceDoc? binding,
  required String? installEmail,
  required String email,
  DateTime? now,
}) {
  final at = (now ?? DateTime.now()).toUtc();
  final want = email.toLowerCase();
  final held = installEmail?.toLowerCase();
  if (binding == null) {
    if (held != null && held.isNotEmpty && held != want) {
      return StudentClaimResult(StudentClaim.installConflict,
          installEmail: installEmail);
    }
    return const StudentClaimResult(StudentClaim.firstBind);
  }
  final pkSame = localPkHex.isNotEmpty &&
      binding.pkHex.toLowerCase() == localPkHex.toLowerCase();
  final instSame = localInstallId.isNotEmpty &&
      binding.installId.isNotEmpty &&
      binding.installId == localInstallId;
  // The install is the device identity: a bare pk match from a DIFFERENT
  // install is a move (backup/clone restore carrying the key), not the same
  // device — otherwise copying a public key would bypass the cooldown.
  // Legacy docs without an installId still honor a pk match (migration).
  if (instSame || (pkSame && binding.installId.isEmpty)) {
    return const StudentClaimResult(StudentClaim.sameDevice);
  }
  if (held != null && held.isNotEmpty && held != want) {
    return StudentClaimResult(StudentClaim.installConflict,
        installEmail: installEmail);
  }
  final base = binding.lastMoveAtMillis;
  if (base > 0 &&
      at.millisecondsSinceEpoch - base <
          kStudentMoveCooldown.inMilliseconds) {
    return StudentClaimResult(StudentClaim.cooldownBlocked,
        retryAfter: DateTime.fromMillisecondsSinceEpoch(
            base + kStudentMoveCooldown.inMilliseconds,
            isUtc: true));
  }
  return const StudentClaimResult(StudentClaim.allowedMove);
}

/// User-facing refusal copy for a non-ok [StudentClaimResult]. The cooldown
/// path always names the re-enroll date (moves are unlimited lifetime, at
/// most one per 7 days) and points at manual attendance for the gap — there
/// is deliberately no reset shortcut (any reset permission would be
/// self-service, since professor registration is self-asserted).
String studentClaimMessage(StudentClaimResult r, StudentDeviceDoc? binding) {
  switch (r.claim) {
    case StudentClaim.installConflict:
      return 'This device is already enrolled as ${r.installEmail ?? 'another account'} — '
          'one phone holds one student enrollment (app clones count as the same phone). '
          'To switch identity here, clear the app data / reinstall and enroll again. '
          'If you need attendance marked meanwhile, ask your professor for manual attendance.';
    case StudentClaim.cooldownBlocked:
      final retry = r.retryAfter != null
          ? ' You can re-enroll this device on ${_dayOf(r.retryAfter!)} — enrollment moves to a new phone once a week (unlimited times).'
          : '';
      final seen = binding != null && binding.lastSeenAtMillis > 0
          ? ' Its last online activity was ${_dayOf(DateTime.fromMillisecondsSinceEpoch(binding.lastSeenAtMillis, isUtc: true))}.'
          : '';
      return 'This Gmail is enrolled on another device.$seen$retry '
          'Until then, ask your professor to mark your attendance manually (Request manual attendance in class).';
    default:
      return '';
  }
}

String _dayOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Outcome of a successful [CloudSync.claimStudentDevice].
class ClaimOutcome {
  final bool isFirst;
  final bool isMove;
  const ClaimOutcome({this.isFirst = false, this.isMove = false});
}

/// One row of the professor-searchable student directory: the minimum a
/// professor needs to add someone to a record. Written by the claim
/// transaction, never by hand.
class StudentDirectoryEntry {
  final String email;
  final String name;
  final String roll;
  const StudentDirectoryEntry(
      {required this.email, required this.name, required this.roll});
}

abstract class CloudSync {
  bool get available;
  Future<bool> isOnline();
  Future<RoleDoc?> fetchRole(String uid);
  Future<void> setRole(RoleDoc doc);
  Future<StudentDeviceDoc?> fetchStudentDevice(String emailLower);

  /// Legacy raw write (tests/seeds). Production enrolls via
  /// [claimStudentDevice], which enforces single-device + cooldown.
  Future<void> writeStudentDevice(StudentDeviceDoc doc);

  /// Atomic enroll-or-move: reads the Gmail binding AND the install mapping
  /// in one transaction, applies [evaluateStudentClaim], and on success
  /// writes both docs (bumping lastSeen; stamping lastMove + moveCount on a
  /// move). Throws StateError with user-facing copy when refused
  /// (cooldown/install-conflict) — the second of two racing devices loses.
  Future<ClaimOutcome> claimStudentDevice(
      {required StudentDeviceDoc doc, required String installId, DateTime? now});

  /// Best-effort last-online heartbeat: bumps lastSeenAtMillis only when
  /// this device still holds the binding. Returns true when touched.
  Future<bool> touchStudentDevice(
      {required String emailLower,
      required String pkHex,
      required String installId,
      DateTime? now});

  /// deviceInstalls/{installId} owner Gmail, or null when this install never
  /// enrolled. Drives the same-phone second-enrollment refusal.
  Future<String?> fetchInstallEmail(String installId);

  /// Professor directory search over enrolled students (online). Each
  /// non-empty prefix runs a server-side prefix query (email / roll /
  /// nameLower), results merged by email and capped at [limit]. Single-field
  /// queries only — no composite index needed. Throws StateError offline or
  /// when rules refuse (deploy them).
  Future<List<StudentDirectoryEntry>> searchStudents(
      {String emailPrefix = '',
      String rollPrefix = '',
      String namePrefix = '',
      int limit = 10});
  Future<void> pushSession(
      {required String profUid,
      required String profEmail,
      required String profName,
      required ClassRecord record});
  Future<List<ClassRecord>> pullProfSessions(String profUid);
  Future<List<ClassRecord>> pullStudentSessions(String emailLower);
  Future<void> renameCourseCloud(
      {required String profUid, required String oldName, required String newName});
  Future<void> deleteSessionsCloud(
      {required String profUid, required List<String> ids});
}

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

/// True when the error means "no working network". Anything else from the
/// server (permission-denied, unauthenticated, failed-precondition for a
/// missing index, …) proves the server WAS reached — i.e. online.
bool _isOfflineError(Object e) {
  if (e is TimeoutException) return true;
  if (e is FirebaseException) {
    return e.code == 'unavailable' ||
        e.code == 'deadline-exceeded' ||
        e.code == 'network-request-failed' ||
        e.code == 'cancelled';
  }
  return false;
}

/// Wraps Firestore permission failures with the actionable fix (rules not
/// deployed or a binding conflict), instead of a bare code.
StateError _rulesError(String op) => StateError(
    'Cloud $op refused by security rules (permission-denied) — deploy them with:\n'
    'firebase deploy --only firestore:rules --project proximity-attendence');

class FirestoreCloudSync implements CloudSync {
  @override
  final bool available;
  FirestoreCloudSync({this.available = true});

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  void _needAvailable() {
    if (!available) {
      throw StateError(
          'Cloud sync is unavailable on this build (offline-only).');
    }
  }

  @override
  Future<bool> isOnline() async {
    if (!available) return false;
    // Any answer from the server counts as online — including
    // permission-denied (rules reachable, e.g. signed-out probe) and
    // unauthenticated. Only transport failures and timeouts mean offline.
    try {
      await _db
          .collection('users')
          .limit(1)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 6));
      return true;
    } on FirebaseException catch (e) {
      return !_isOfflineError(e);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<RoleDoc?> fetchRole(String uid) async {
    _needAvailable();
    try {
      final snap = await _db
          .collection('users')
          .doc(uid)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 8));
      if (!snap.exists) return null;
      final d = snap.data();
      if (d == null) return null;
      final roles = <String>[];
      final rawRoles = d['roles'];
      if (rawRoles is List) {
        for (final r in rawRoles) {
          if (r == 'prof' || r == 'student') roles.add(r as String);
        }
      }
      // Legacy single-role docs.
      final legacy = d['role'] as String?;
      if (roles.isEmpty && (legacy == 'prof' || legacy == 'student')) {
        roles.add(legacy!);
      }
      return RoleDoc(
        uid: uid,
        email: (d['email'] as String? ?? '').toLowerCase(),
        name: d['name'] as String? ?? '',
        roles: roles,
        displayName: d['displayName'] as String? ?? '',
        lastMode: d['lastMode'] as String? ?? '',
      );
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw _rulesError('role lookup');
      if (_isOfflineError(e)) return null;
      rethrow;
    } catch (e) {
      if (_isOfflineError(e)) return null;
      rethrow;
    }
  }

  @override
  Future<void> setRole(RoleDoc doc) async {
    _needAvailable();
    // Merge semantics: registering a second role unions it in — never drops
    // the first. lastMode only rides along when explicitly set (merge:true
    // would otherwise clobber it with '').
    final data = <String, dynamic>{
      'email': doc.email.toLowerCase(),
      'name': doc.name,
      'roles': FieldValue.arrayUnion(doc.roles),
      'displayName': doc.displayName,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    if (doc.lastMode == 'prof' || doc.lastMode == 'student') {
      data['lastMode'] = doc.lastMode;
    }
    try {
      await _db
          .collection('users')
          .doc(doc.uid)
          .set(data, SetOptions(merge: true))
          .timeout(const Duration(seconds: 8));
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw _rulesError('registration');
      if (_isOfflineError(e)) {
        throw StateError('You appear offline — connect to the internet to register.');
      }
      rethrow;
    } catch (e) {
      if (_isOfflineError(e)) {
        throw StateError('You appear offline — connect to the internet to register.');
      }
      rethrow;
    }
  }

  @override
  Future<StudentDeviceDoc?> fetchStudentDevice(String emailLower) async {
    _needAvailable();
    final key = emailLower.toLowerCase();
    try {
      final snap = await _db
          .collection('studentDevices')
          .doc(key)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 8));
      if (!snap.exists) return null;
      final d = snap.data();
      if (d == null) return null;
      return StudentDeviceDoc(
        email: key,
        uid: d['uid'] as String? ?? '',
        pkHex: d['pkHex'] as String? ?? '',
        name: d['name'] as String? ?? '',
        roll: d['roll'] as String? ?? '',
        modelVer: d['modelVer'] as String? ?? '',
        installId: d['installId'] as String? ?? '',
        platform: d['platform'] as String? ?? '',
        createdAtMillis: (d['createdAtMillis'] as num?)?.toInt() ?? 0,
        lastMoveAtMillis: (d['lastMoveAtMillis'] as num?)?.toInt() ?? 0,
        lastSeenAtMillis: (d['lastSeenAtMillis'] as num?)?.toInt() ?? 0,
        updatedAtMillis: (d['updatedAtMillis'] as num?)?.toInt() ?? 0,
        moveCount: (d['moveCount'] as num?)?.toInt() ?? 0,
      );
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw _rulesError('device lookup');
      if (_isOfflineError(e)) return null;
      rethrow;
    } catch (e) {
      if (_isOfflineError(e)) return null;
      rethrow;
    }
  }

  @override
  Future<void> writeStudentDevice(StudentDeviceDoc doc) async {
    // Dead in production on purpose: a raw set(merge:true) here would
    // bypass the claim transaction (single-device verdict + 7-day cooldown
    // + directory row). Enrollment goes through [claimStudentDevice]; the
    // fake keeps a working copy so tests can seed bindings.
    throw UnimplementedError(
        'use claimStudentDevice (atomic verdict + cooldown), not a raw write');
  }

  @override
  Future<void> pushSession(
      {required String profUid,
      required String profEmail,
      required String profName,
      required ClassRecord record}) async {
    _needAvailable();
    try {
      await _db
          .collection('classSessions')
          .doc(record.id)
          .set(
              sessionToDoc(
                  profUid: profUid,
                  profEmail: profEmail,
                  profName: profName,
                  record: record),
              SetOptions(merge: true))
          .timeout(const Duration(seconds: 8));
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw _rulesError('sync');
      rethrow;
    }
  }

  Future<List<ClassRecord>> _querySessions(
      Query<Map<String, dynamic>> Function(
              CollectionReference<Map<String, dynamic>>)
          build) async {
    _needAvailable();
    final col = _db.collection('classSessions').withConverter<Map<String, dynamic>>(
        fromFirestore: (s, _) => s.data() ?? {}, toFirestore: (v, _) => v);
    QuerySnapshot<Map<String, dynamic>> snap;
    try {
      snap = await build(col)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      if (_isOfflineError(e)) {
        snap = await build(col).get(const GetOptions(source: Source.cache));
      } else {
        rethrow;
      }
    }
    // Newest first (client-side: single-filter queries need no composite
    // index, so ordering happens here, not on the server).
    final out = [
      for (final d in snap.docs) docToRecord(d.id, d.data()),
    ]..sort((a, b) => b.timestampIso.compareTo(a.timestampIso));
    return out;
  }

  @override
  Future<List<ClassRecord>> pullProfSessions(String profUid) => _querySessions(
      (col) => col.where('profUid', isEqualTo: profUid).limit(200));

  @override
  Future<List<ClassRecord>> pullStudentSessions(String emailLower) =>
      _querySessions((col) => col
          .where('studentEmails', arrayContains: emailLower.toLowerCase())
          .limit(200));

  @override
  Future<void> renameCourseCloud(
      {required String profUid,
      required String oldName,
      required String newName}) async {
    _needAvailable();
    final sessions = await pullProfSessions(profUid);
    try {
      var batch = _db.batch();
      var n = 0;
      // Rename bumps timestampIso (not just updatedAt): mergeHistories
      // adopts the NEWER record per id, so without this any device holding
      // a newer-timestamped copy under the OLD name would resurrect it on
      // the next merge — the rename would never converge, for professors
      // or for students reading the same docs.
      final nowIso = DateTime.now().toUtc().toIso8601String();
      for (final s in sessions) {
        if (s.courseId == oldName ||
            (s.courseId.isEmpty && s.classLabel == oldName)) {
          batch.set(
              _db.collection('classSessions').doc(s.id),
              {
                'courseId': newName,
                'courseName': newName,
                if (s.classLabel == oldName) 'classLabel': newName,
                'timestampIso': nowIso,
                'updatedAt': nowIso,
              },
              SetOptions(merge: true));
          if (++n % 400 == 0) {
            await batch.commit();
            batch = _db.batch();
          }
        }
      }
      if (n % 400 != 0 || n == 0) {
        if (n > 0) await batch.commit();
      }
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw _rulesError('rename');
      rethrow;
    }
  }

  @override
  Future<void> deleteSessionsCloud(
      {required String profUid, required List<String> ids}) async {
    _needAvailable();
    try {
      final batch = _db.batch();
      for (final id in ids) {
        batch.delete(_db.collection('classSessions').doc(id));
      }
      await batch.commit().timeout(const Duration(seconds: 10));
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw _rulesError('delete');
      rethrow;
    }
  }

  StudentDeviceDoc _deviceFrom(Map<String, dynamic>? d, String key) =>
      StudentDeviceDoc(
        email: key,
        uid: d?['uid'] as String? ?? '',
        pkHex: d?['pkHex'] as String? ?? '',
        name: d?['name'] as String? ?? '',
        roll: d?['roll'] as String? ?? '',
        modelVer: d?['modelVer'] as String? ?? '',
        installId: d?['installId'] as String? ?? '',
        platform: d?['platform'] as String? ?? '',
        createdAtMillis: (d?['createdAtMillis'] as num?)?.toInt() ?? 0,
        lastMoveAtMillis: (d?['lastMoveAtMillis'] as num?)?.toInt() ?? 0,
        lastSeenAtMillis: (d?['lastSeenAtMillis'] as num?)?.toInt() ?? 0,
        updatedAtMillis: (d?['updatedAtMillis'] as num?)?.toInt() ?? 0,
        moveCount: (d?['moveCount'] as num?)?.toInt() ?? 0,
      );

  @override
  Future<ClaimOutcome> claimStudentDevice(
      {required StudentDeviceDoc doc,
      required String installId,
      DateTime? now}) async {
    _needAvailable();
    final at = (now ?? DateTime.now()).toUtc();
    final atMillis = at.millisecondsSinceEpoch;
    final key = doc.email.toLowerCase();
    try {
      ClaimOutcome? outcome;
      await _db.runTransaction((tx) async {
        final devRef = _db.collection('studentDevices').doc(key);
        final instRef = _db.collection('deviceInstalls').doc(installId);
        final devSnap = await tx.get(devRef);
        final instSnap = await tx.get(instRef);
        final binding =
            devSnap.exists ? _deviceFrom(devSnap.data(), key) : null;
        String? installEmail;
        if (instSnap.exists) {
          installEmail = (instSnap.data()?['email'] as String?);
        }
        final verdict = evaluateStudentClaim(
            localPkHex: doc.pkHex,
            localInstallId: installId,
            binding: binding,
            installEmail: installEmail,
            email: key,
            now: at);
        if (!verdict.ok) {
          throw StateError(studentClaimMessage(verdict, binding));
        }
        final isFirst = verdict.claim == StudentClaim.firstBind;
        final isMove = verdict.claim == StudentClaim.allowedMove;
        tx.set(devRef, {
          'email': key,
          'uid': doc.uid,
          'pkHex': doc.pkHex,
          'installId': installId,
          'name': doc.name,
          'roll': doc.roll,
          'modelVer': doc.modelVer,
          'platform': doc.platform,
          'createdAtMillis':
              binding != null && binding.createdAtMillis > 0
                  ? binding.createdAtMillis
                  : atMillis,
          'lastMoveAtMillis': isMove || isFirst || binding == null
              ? atMillis
              : (binding.lastMoveAtMillis > 0
                  ? binding.lastMoveAtMillis
                  : atMillis),
          'lastSeenAtMillis': atMillis,
          'updatedAtMillis': atMillis,
          'moveCount':
              (binding?.moveCount ?? 0) + (isMove ? 1 : 0),
          'updatedAt': at.toIso8601String(),
        }, SetOptions(merge: true));
        tx.set(instRef, {
          'email': key,
          'pkHex': doc.pkHex,
          'updatedAtMillis': atMillis,
          'updatedAt': at.toIso8601String(),
        }, SetOptions(merge: true));
        // Professor-searchable directory row (name/roll/email only).
        tx.set(_db.collection('studentDirectory').doc(key), {
          'email': key,
          'name': doc.name,
          'roll': doc.roll,
          'nameLower': doc.name.toLowerCase(),
          'updatedAtMillis': atMillis,
          'updatedAt': at.toIso8601String(),
        }, SetOptions(merge: true));
        outcome = ClaimOutcome(isFirst: isFirst, isMove: isMove);
      }).timeout(const Duration(seconds: 12));
      return outcome ?? const ClaimOutcome();
    } on StateError {
      rethrow; // refusal copy reaches the UI verbatim
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw _rulesError('enrollment');
      if (_isOfflineError(e)) {
        throw StateError(
            'Student enrollment needs internet (one enrolled device per Gmail is checked online). Connect and tap Save again — your 5 angles are kept.');
      }
      rethrow;
    } catch (e) {
      if (_isOfflineError(e)) {
        throw StateError(
            'Student enrollment needs internet (one enrolled device per Gmail is checked online). Connect and tap Save again — your 5 angles are kept.');
      }
      rethrow;
    }
  }

  @override
  Future<bool> touchStudentDevice(
      {required String emailLower,
      required String pkHex,
      required String installId,
      DateTime? now}) async {
    _needAvailable();
    final at = (now ?? DateTime.now()).toUtc();
    final key = emailLower.toLowerCase();
    try {
      var touched = false;
      await _db.runTransaction((tx) async {
        final devRef = _db.collection('studentDevices').doc(key);
        final snap = await tx.get(devRef);
        if (!snap.exists) return;
        final binding = _deviceFrom(snap.data(), key);
        final pkSame = pkHex.isNotEmpty &&
            binding.pkHex.toLowerCase() == pkHex.toLowerCase();
        final instSame = installId.isNotEmpty &&
            binding.installId.isNotEmpty &&
            binding.installId == installId;
        if (!pkSame && !instSame) return; // moved away: never touch
        tx.set(devRef, {
          'lastSeenAtMillis': at.millisecondsSinceEpoch,
          'updatedAtMillis': at.millisecondsSinceEpoch,
        }, SetOptions(merge: true));
        touched = true;
      }).timeout(const Duration(seconds: 10));
      return touched;
    } catch (e) {
      if (_isOfflineError(e)) return false;
      if (e is FirebaseException && e.code == 'permission-denied') {
        return false;
      }
      return false;
    }
  }

  @override
  Future<String?> fetchInstallEmail(String installId) async {
    _needAvailable();
    if (installId.isEmpty) return null;
    try {
      final snap = await _db
          .collection('deviceInstalls')
          .doc(installId)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 8));
      if (!snap.exists) return null;
      return snap.data()?['email'] as String?;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw _rulesError('device lookup');
      if (_isOfflineError(e)) return null;
      rethrow;
    } catch (e) {
      if (_isOfflineError(e)) return null;
      rethrow;
    }
  }

  Future<List<StudentDirectoryEntry>> _prefixQuery(
      String field, String prefix, int limit) async {
    final snap = await _db
        .collection('studentDirectory')
        .where(field, isGreaterThanOrEqualTo: prefix)
        .where(field, isLessThan: '$prefix\uf8ff')
        .limit(limit)
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 8));
    return [
      for (final d in snap.docs)
        StudentDirectoryEntry(
          email: (d.data()['email'] as String? ?? '').toLowerCase(),
          name: d.data()['name'] as String? ?? '',
          roll: d.data()['roll'] as String? ?? '',
        ),
    ];
  }

  @override
  Future<List<StudentDirectoryEntry>> searchStudents(
      {String emailPrefix = '',
      String rollPrefix = '',
      String namePrefix = '',
      int limit = 10}) async {
    _needAvailable();
    final eq = emailPrefix.trim().toLowerCase();
    final rq = rollPrefix.trim();
    final nq = namePrefix.trim().toLowerCase();
    if (eq.isEmpty && rq.isEmpty && nq.isEmpty) return const [];
    try {
      // Perf: one round trip — the non-empty prefix queries fan out in
      // parallel (independent single-field range queries, no composite
      // index), then merge by email client-side.
      final futures = <Future<List<StudentDirectoryEntry>>>[];
      if (rq.isNotEmpty) futures.add(_prefixQuery('roll', rq, limit));
      if (nq.isNotEmpty) futures.add(_prefixQuery('nameLower', nq, limit));
      if (eq.isNotEmpty) futures.add(_prefixQuery('email', eq, limit));
      final parts = await Future.wait(futures);
      final seen = <String, StudentDirectoryEntry>{};
      for (final list in parts) {
        for (final e in list) {
          seen.putIfAbsent(e.email, () => e);
        }
      }
      final out = seen.values.toList()
        ..sort((a, b) => a.email.compareTo(b.email));
      return out.take(limit).toList();
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw _rulesError('directory search');
      if (_isOfflineError(e)) {
        throw StateError('Directory search needs internet.');
      }
      rethrow;
    } catch (e) {
      if (_isOfflineError(e)) {
        throw StateError('Directory search needs internet.');
      }
      rethrow;
    }
  }
}

/// In-memory fake for widget/unit tests (no Firebase).
class FakeCloudSync implements CloudSync {
  @override
  bool available;
  bool online;
  final Map<String, RoleDoc> roles = {};
  final Map<String, StudentDeviceDoc> devices = {};
  final Map<String, String> installs = {}; // installId -> emailLower
  final Map<String, StudentDirectoryEntry> dir = {}; // emailLower -> entry
  final Map<String, Map<String, dynamic>> sessions = {};
  String? lastPushedBy;
  FakeCloudSync({this.available = true, this.online = true});

  void _needOnline() {
    if (!available || !online) {
      throw StateError('You appear offline — connect to the internet.');
    }
  }

  @override
  Future<bool> isOnline() async => available && online;

  @override
  Future<RoleDoc?> fetchRole(String uid) async => roles[uid];

  @override
  Future<void> setRole(RoleDoc doc) async {
    _needOnline();
    // Merge semantics mirror Firestore arrayUnion: roles accumulate.
    final prev = roles[doc.uid];
    final set = {...?prev?.roles, ...doc.roles};
    final lastMode = (doc.lastMode == 'prof' || doc.lastMode == 'student')
        ? doc.lastMode
        : (prev?.lastMode ?? '');
    roles[doc.uid] = RoleDoc(
        uid: doc.uid,
        email: doc.email,
        name: doc.name,
        roles: set.toList(),
        displayName:
            doc.displayName.isNotEmpty ? doc.displayName : (prev?.displayName ?? ''),
        lastMode: lastMode);
  }

  @override
  Future<StudentDeviceDoc?> fetchStudentDevice(String emailLower) async =>
      devices[emailLower.toLowerCase()];

  @override
  Future<void> writeStudentDevice(StudentDeviceDoc doc) async {
    _needOnline();
    devices[doc.email.toLowerCase()] = doc;
    if (doc.installId.isNotEmpty) {
      installs[doc.installId] = doc.email.toLowerCase();
    }
    dir[doc.email.toLowerCase()] = StudentDirectoryEntry(
        email: doc.email.toLowerCase(), name: doc.name, roll: doc.roll);
  }

  @override
  Future<String?> fetchInstallEmail(String installId) async =>
      installs[installId];

  @override
  Future<List<StudentDirectoryEntry>> searchStudents(
      {String emailPrefix = '',
      String rollPrefix = '',
      String namePrefix = '',
      int limit = 10}) async {
    _needOnline();
    final eq = emailPrefix.trim().toLowerCase();
    final rq = rollPrefix.trim();
    final nq = namePrefix.trim().toLowerCase();
    if (eq.isEmpty && rq.isEmpty && nq.isEmpty) return const [];
    final seen = <String, StudentDirectoryEntry>{};
    for (final e in dir.values) {
      if (eq.isNotEmpty && e.email.startsWith(eq)) seen[e.email] = e;
      if (rq.isNotEmpty && e.roll.startsWith(rq)) seen[e.email] = e;
      if (nq.isNotEmpty && e.name.toLowerCase().startsWith(nq)) {
        seen[e.email] = e;
      }
    }
    final out = seen.values.toList()
      ..sort((a, b) => a.email.compareTo(b.email));
    return out.take(limit).toList();
  }

  @override
  Future<ClaimOutcome> claimStudentDevice(
      {required StudentDeviceDoc doc,
      required String installId,
      DateTime? now}) async {
    _needOnline();
    final at = (now ?? DateTime.now()).toUtc();
    final atMillis = at.millisecondsSinceEpoch;
    final key = doc.email.toLowerCase();
    final binding = devices[key];
    final verdict = evaluateStudentClaim(
        localPkHex: doc.pkHex,
        localInstallId: installId,
        binding: binding,
        installEmail: installs[installId],
        email: key,
        now: at);
    if (!verdict.ok) {
      throw StateError(studentClaimMessage(verdict, binding));
    }
    final isFirst = verdict.claim == StudentClaim.firstBind;
    final isMove = verdict.claim == StudentClaim.allowedMove;
    devices[key] = StudentDeviceDoc(
      email: key,
      uid: doc.uid,
      pkHex: doc.pkHex,
      name: doc.name,
      roll: doc.roll,
      modelVer: doc.modelVer,
      installId: installId,
      platform: doc.platform,
      createdAtMillis: binding != null && binding.createdAtMillis > 0
          ? binding.createdAtMillis
          : atMillis,
      lastMoveAtMillis: isMove || isFirst || binding == null
          ? atMillis
          : (binding.lastMoveAtMillis > 0
              ? binding.lastMoveAtMillis
              : atMillis),
      lastSeenAtMillis: atMillis,
      updatedAtMillis: atMillis,
      moveCount: (binding?.moveCount ?? 0) + (isMove ? 1 : 0),
    );
    installs[installId] = key;
    dir[key] = StudentDirectoryEntry(email: key, name: doc.name, roll: doc.roll);
    return ClaimOutcome(isFirst: isFirst, isMove: isMove);
  }

  @override
  Future<bool> touchStudentDevice(
      {required String emailLower,
      required String pkHex,
      required String installId,
      DateTime? now}) async {
    if (!available || !online) return false;
    final key = emailLower.toLowerCase();
    final binding = devices[key];
    if (binding == null) return false;
    final pkSame = pkHex.isNotEmpty &&
        binding.pkHex.toLowerCase() == pkHex.toLowerCase();
    final instSame = installId.isNotEmpty &&
        binding.installId.isNotEmpty &&
        binding.installId == installId;
    if (!pkSame && !instSame) return false;
    final at = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    devices[key] = StudentDeviceDoc(
      email: binding.email,
      uid: binding.uid,
      pkHex: binding.pkHex,
      name: binding.name,
      roll: binding.roll,
      modelVer: binding.modelVer,
      installId: binding.installId,
      platform: binding.platform,
      createdAtMillis: binding.createdAtMillis,
      lastMoveAtMillis: binding.lastMoveAtMillis,
      lastSeenAtMillis: at,
      updatedAtMillis: at,
      moveCount: binding.moveCount,
    );
    return true;
  }

  @override
  Future<void> pushSession(
      {required String profUid,
      required String profEmail,
      required String profName,
      required ClassRecord record}) async {
    _needOnline();
    lastPushedBy = profUid;
    sessions[record.id] = sessionToDoc(
        profUid: profUid,
        profEmail: profEmail,
        profName: profName,
        record: record);
  }

  @override
  Future<List<ClassRecord>> pullProfSessions(String profUid) async {
    final docs = [
      for (final e in sessions.entries)
        if ((e.value['profUid'] as String? ?? '') == profUid) e
    ];
    final out = [for (final e in docs) docToRecord(e.key, e.value)]
      ..sort((a, b) => b.timestampIso.compareTo(a.timestampIso));
    return out;
  }

  @override
  Future<List<ClassRecord>> pullStudentSessions(String emailLower) async {
    final key = emailLower.toLowerCase();
    final out = [
      for (final e in sessions.entries)
        if (((e.value['studentEmails'] as List? ?? const [])
                .map((x) => '$x')
                .contains(key)))
          docToRecord(e.key, e.value)
    ]..sort((a, b) => b.timestampIso.compareTo(a.timestampIso));
    return out;
  }

  @override
  Future<void> renameCourseCloud(
      {required String profUid,
      required String oldName,
      required String newName}) async {
    _needOnline();
    // Same timestampIso bump as the real impl: merges adopt the rename.
    final nowIso = DateTime.now().toUtc().toIso8601String();
    for (final e in sessions.entries) {
      final d = e.value;
      if (d['profUid'] != profUid) continue;
      if (d['courseId'] == oldName) {
        d['courseId'] = newName;
        d['courseName'] = newName;
        d['timestampIso'] = nowIso;
        d['updatedAt'] = nowIso;
      }
    }
  }

  @override
  Future<void> deleteSessionsCloud(
      {required String profUid, required List<String> ids}) async {
    _needOnline();
    for (final id in ids) {
      sessions.remove(id);
    }
  }
}

/// Professor push identity: null when offline / skipped sign-in / no prof
/// role (local-only data, never pushed). Prefers the registered professor
/// display name, then the typed host name, then the Gmail name. A Gmail
/// holding BOTH roles still pushes as professor here — prof and student
/// modes coexist on one phone.
({String uid, String email, String name})? profPushIdentity(
    {required String? authEmail,
    required String? authUid,
    required String? authName,
    required Map<String, String>? role,
    required String hostNameFallback}) {
  if (authEmail == null || authEmail.isEmpty) return null;
  if (role == null) return null; // offline-skipped professor: local only
  if (!roleHas(role, 'prof', email: authEmail)) return null;
  final uid =
      (authUid != null && authUid.isNotEmpty) ? authUid : authEmail.toLowerCase();
  final display = (role['displayName'] ?? '').trim();
  final name = display.isNotEmpty
      ? display
      : (hostNameFallback.trim().isNotEmpty
          ? hostNameFallback.trim()
          : (authName ?? authEmail));
  return (uid: uid, email: authEmail.toLowerCase(), name: name);
}

final cloudSyncProvider = Provider<CloudSync>((ref) {
  throw UnimplementedError('Override in main / tests');
});
