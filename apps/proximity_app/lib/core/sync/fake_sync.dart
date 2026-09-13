// In-memory CloudSync fake for widget/unit tests (no Firebase).
// EXCEPT claimStudentDevice, whose exact-duplicate verdict+write computation
// now calls the shared pure helper [resolveStudentClaimWrite] (see claim.dart).
library;

import 'package:proximity_storage/storage.dart';

import 'claim.dart';
import 'cloud_api.dart';
import 'directory.dart';
import 'org.dart';
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
    // Org stamps once (creation) and never blanks: an explicit org wins,
    // else the previous stamp survives, else derive from the email.
    final org = doc.org.isNotEmpty
        ? doc.org
        : ((prev?.org ?? '').isNotEmpty ? prev!.org : orgOf(doc.email));
    roles[doc.uid] = RoleDoc(
        uid: doc.uid,
        email: doc.email,
        name: doc.name,
        roles: set.toList(),
        displayName:
            doc.displayName.isNotEmpty ? doc.displayName : (prev?.displayName ?? ''),
        lastMode: lastMode,
        org: org,
        updatedAtMillis: DateTime.now().toUtc().millisecondsSinceEpoch);
  }

  @override
  Future<StudentDeviceDoc?> fetchStudentDevice(String emailLower) async =>
      devices[emailLower.toLowerCase()];

  @override
  Future<void> writeStudentDevice(StudentDeviceDoc doc) async {
    _needOnline();
    final withOrg = doc.org.isNotEmpty
        ? doc
        : StudentDeviceDoc(
            email: doc.email,
            uid: doc.uid,
            pkHex: doc.pkHex,
            name: doc.name,
            roll: doc.roll,
            modelVer: doc.modelVer,
            installId: doc.installId,
            platform: doc.platform,
            org: orgOf(doc.email),
            createdAtMillis: doc.createdAtMillis,
            lastMoveAtMillis: doc.lastMoveAtMillis,
            lastSeenAtMillis: doc.lastSeenAtMillis,
            updatedAtMillis: doc.updatedAtMillis,
            moveCount: doc.moveCount,
            pkDHex: doc.pkDHex,
            attestationLevel: doc.attestationLevel,
            attestedAtMillis: doc.attestedAtMillis,
            attestedUntilMillis: doc.attestedUntilMillis,
            attestationChain: List<String>.of(doc.attestationChain),
            livenessVer: doc.livenessVer,
            integrityFlag: doc.integrityFlag);
    devices[withOrg.email.toLowerCase()] = withOrg;
    if (withOrg.installId.isNotEmpty) {
      installs[withOrg.installId] = withOrg.email.toLowerCase();
    }
    dir[withOrg.email.toLowerCase()] = StudentDirectoryEntry(
        email: withOrg.email.toLowerCase(),
        name: withOrg.name,
        roll: withOrg.roll,
        org: withOrg.org);
  }

  @override
  Future<String?> fetchInstallEmail(String installId) async =>
      installs[installId];

  /// Test seam for the rules-denied branch: when true, [updateStudentRoll]
  /// throws StateError(cloudRulesHint('id update')) like production rules
  /// would before a rules deploy.
  bool denyIdUpdate = false;

  @override
  Future<void> updateStudentRoll(
      {required String emailLower, required String newRoll}) async {
    _needOnline();
    // CLIENT-SIDE ONLY — production needs
    // `firebase deploy --only firestore:rules --project proximity-attendence`
    // for this path; denied rules surface as the deploy hint (existing
    // rules-error pattern), never raw text.
    if (denyIdUpdate) throw StateError(cloudRulesHint('id update'));
    final want = newRoll.trim();
    if (want.isEmpty) throw StateError('ID Number is required.');
    final key = emailLower.toLowerCase();
    final binding = devices[key];
    if (binding == null) {
      throw StateError(
          'No enrolled device found for this account — enroll this device first.');
    }
    final atMillis = DateTime.now().toUtc().millisecondsSinceEpoch;
    devices[key] = StudentDeviceDoc(
      email: binding.email,
      uid: binding.uid,
      pkHex: binding.pkHex,
      name: binding.name,
      roll: want,
      modelVer: binding.modelVer,
      installId: binding.installId,
      platform: binding.platform,
      org: binding.org,
      createdAtMillis: binding.createdAtMillis,
      lastMoveAtMillis: binding.lastMoveAtMillis,
      lastSeenAtMillis: binding.lastSeenAtMillis,
      updatedAtMillis: atMillis,
      moveCount: binding.moveCount,
      pkDHex: binding.pkDHex,
      attestationLevel: binding.attestationLevel,
      attestedAtMillis: binding.attestedAtMillis,
      attestedUntilMillis: binding.attestedUntilMillis,
      attestationChain: List<String>.of(binding.attestationChain),
      livenessVer: binding.livenessVer,
      integrityFlag: binding.integrityFlag,
    );
    final row = dir[key];
    if (row != null) {
      dir[key] = StudentDirectoryEntry(
          email: row.email,
          name: row.name,
          roll: want,
          org: row.org,
          updatedAtMillis: atMillis);
    } else {
      dir[key] = StudentDirectoryEntry(
          email: key,
          name: binding.name,
          roll: want,
          org: binding.org,
          updatedAtMillis: atMillis);
    }
  }

  @override
  Future<List<StudentDirectoryEntry>> searchStudents(
      {String emailPrefix = '',
      String rollPrefix = '',
      String namePrefix = '',
      int limit = 10,
      String org = ''}) async {
    _needOnline();
    final (email: eq, roll: rq, name: nq) = normalizeSearchPrefixes(
        emailPrefix: emailPrefix,
        rollPrefix: rollPrefix,
        namePrefix: namePrefix);
    if (eq.isEmpty && rq.isEmpty && nq.isEmpty) return const [];
    final seen = <String, StudentDirectoryEntry>{};
    for (final e in dir.values) {
      if (org.isNotEmpty && e.org.isNotEmpty && e.org != org) continue;
      if (org.isNotEmpty && e.org.isEmpty) continue;
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
      DateTime? now,
      MoveIntent? moveIntent}) async {
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
        now: at,
        moveIntent: moveIntent);
    final isFirst = claim.isFirst;
    final isMove = claim.isMove;
    final org = doc.org.isNotEmpty ? doc.org : orgOf(key);
    devices[key] = StudentDeviceDoc(
      email: key,
      uid: doc.uid,
      pkHex: doc.pkHex,
      name: doc.name,
      roll: doc.roll,
      modelVer: doc.modelVer,
      installId: installId,
      platform: doc.platform,
      org: org,
      createdAtMillis: claim.createdAtMillis,
      lastMoveAtMillis: claim.lastMoveAtMillis,
      lastSeenAtMillis: atMillis,
      updatedAtMillis: atMillis,
      moveCount: claim.moveCount,
      pkDHex: doc.pkDHex,
      attestationLevel: doc.attestationLevel,
      attestedAtMillis: doc.attestedAtMillis,
      attestedUntilMillis: doc.attestedUntilMillis,
      attestationChain: List<String>.of(doc.attestationChain),
      livenessVer: doc.livenessVer,
      integrityFlag: doc.integrityFlag,
    );
    installs[installId] = key;
    dir[key] =
        StudentDirectoryEntry(email: key, name: doc.name, roll: doc.roll, org: org, updatedAtMillis: atMillis);
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
      org: binding.org,
      createdAtMillis: binding.createdAtMillis,
      lastMoveAtMillis: binding.lastMoveAtMillis,
      lastSeenAtMillis: at,
      updatedAtMillis: at,
      moveCount: binding.moveCount,
      pkDHex: binding.pkDHex,
      attestationLevel: binding.attestationLevel,
      attestedAtMillis: binding.attestedAtMillis,
      attestedUntilMillis: binding.attestedUntilMillis,
      attestationChain: List<String>.of(binding.attestationChain),
      livenessVer: binding.livenessVer,
      integrityFlag: binding.integrityFlag,
    );
    return true;
  }

  @override
  Future<PurgeOutcome> purgeExpiredSelfData(
      {required String emailLower, String uid = '', DateTime? now}) async {
    if (!available || !online) return const PurgeOutcome();
    final at = (now ?? DateTime.now()).toUtc();
    final key = emailLower.toLowerCase();
    final deleted = <String>[];
    // Per-doc staleness on the STORED stamp (fail-closed on zero/missing);
    // sessions are never in scope — professors' past records stay.
    final binding = devices[key];
    if (binding != null &&
        stampOlderThan(
            stampMillis: binding.lastSeenAtMillis,
            now: at,
            age: kStudentPurgeStale)) {
      devices.remove(key);
      deleted.add('studentDevices/$key');
    }
    final row = dir[key];
    if (row != null &&
        stampOlderThan(
            stampMillis: row.updatedAtMillis, now: at, age: kStudentPurgeStale)) {
      dir.remove(key);
      deleted.add('studentDirectory/$key');
    }
    if (uid.isNotEmpty) {
      final role = roles[uid];
      if (role != null &&
          stampOlderThan(
              stampMillis: role.updatedAtMillis,
              now: at,
              age: kStudentPurgeStale)) {
        roles.remove(uid);
        deleted.add('users/$uid');
      }
    }
    return PurgeOutcome(deleted);
  }

  @override
  Future<void> pushSession(
      {required String profUid,
      required String profEmail,
      required String profName,
      required ClassRecord record}) async {
    _needOnline();
    // Full-fresh mirror of the real push: the stamped record org is
    // written verbatim (no fallback) — org-less writes land org-less
    // here and deny against the real rules.
    sessions[record.id] = sessionToDoc(
        profUid: profUid,
        profEmail: profEmail,
        profName: profName,
        record: record);
  }

  @override
  Future<List<ClassRecord>> pullProfSessions(String profUid,
      {String org = ''}) async {
    final docs = [
      for (final e in sessions.entries)
        if ((e.value['profUid'] as String? ?? '') == profUid &&
            (org.isEmpty || (e.value['org'] as String? ?? '') == org))
          e
    ];
    final out = [for (final e in docs) docToRecord(e.key, e.value)]
      ..sort((a, b) => b.timestampIso.compareTo(a.timestampIso));
    return out;
  }

  @override
  Future<List<ClassRecord>> pullStudentSessions(String emailLower,
      {String org = ''}) async {
    final key = emailLower.toLowerCase();
    final out = [
      for (final e in sessions.entries)
        if (((e.value['studentEmails'] as List? ?? const [])
                .map((x) => '$x')
                .contains(key)) &&
            (org.isEmpty || (e.value['org'] as String? ?? '') == org))
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
