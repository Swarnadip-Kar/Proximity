// In-memory CloudSync fake for widget/unit tests (no Firebase).
// Split out of core/cloud_sync.dart (M6 sync refactor) — all bodies verbatim
// EXCEPT claimStudentDevice, whose exact-duplicate verdict+write computation
// now calls the shared pure helper [resolveStudentClaimWrite] (see claim.dart).
library;

import 'package:proximity_storage/storage.dart';

import 'claim.dart';
import 'cloud_api.dart';
import 'directory.dart';
import 'roles.dart';
import 'sessions.dart';

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
    // Shared verdict+write computation (see claim.dart): same refusal copy
    // and same stamp/count derivation as the Firestore transaction.
    final claim = resolveStudentClaimWrite(
        doc: doc,
        installId: installId,
        binding: binding,
        installEmail: installs[installId],
        email: key,
        now: at);
    final isFirst = claim.isFirst;
    final isMove = claim.isMove;
    devices[key] = StudentDeviceDoc(
      email: key,
      uid: doc.uid,
      pkHex: doc.pkHex,
      name: doc.name,
      roll: doc.roll,
      modelVer: doc.modelVer,
      installId: installId,
      platform: doc.platform,
      createdAtMillis: claim.createdAtMillis,
      lastMoveAtMillis: claim.lastMoveAtMillis,
      lastSeenAtMillis: atMillis,
      updatedAtMillis: atMillis,
      moveCount: claim.moveCount,
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
