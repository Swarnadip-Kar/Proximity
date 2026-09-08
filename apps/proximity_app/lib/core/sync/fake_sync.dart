// In-memory CloudSync fake for widget/unit tests (no Firebase).
// Split out of core/cloud_sync.dart (M6 sync refactor) — all bodies verbatim
// EXCEPT claimStudentDevice, whose exact-duplicate verdict+write computation
// now calls the shared pure helper [resolveStudentClaimWrite] (see claim.dart).
library;

import 'package:proximity_protocol/protocol.dart';
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
  final Map<String, FacePrintDoc> prints = {}; // emailLower -> face print
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
            attestedUntilMillis: doc.attestedUntilMillis);
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
      bool moveIntentValid = false,
      FacePrintDoc? facePrint}) async {
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
        moveIntentValid: moveIntentValid);
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
    );
    installs[installId] = key;
    dir[key] =
        StudentDirectoryEntry(email: key, name: doc.name, roll: doc.roll, org: org, updatedAtMillis: atMillis);
    // Same atomicity as the Firestore tx: binding + print land together.
    if (facePrint != null) {
      prints[key] = FacePrintDoc(
        org: org,
        verifierVer: facePrint.verifierVer,
        embQ: facePrint.embQ,
        buckets: List<String>.from(facePrint.buckets),
        updatedAtMillis: atMillis,
      );
    }
    return ClaimOutcome(isFirst: isFirst, isMove: isMove);
  }

  @override
  Future<Map<String, FacePrintDoc>> queryFacePrints(
      {required String org,
      required List<String> buckets,
      int limit = kFacePrintQueryLimit}) async {
    _needOnline();
    if (org.isEmpty || buckets.isEmpty) return const {};
    final want = buckets.toSet();
    final out = <String, FacePrintDoc>{};
    final keys = prints.keys.toList()..sort();
    for (final k in keys) {
      final p = prints[k]!;
      if (p.org != org) continue;
      if (p.buckets.any(want.contains)) out[k] = p;
      if (out.length >= limit) break;
    }
    return out;
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
    );
    return true;
  }

  /// Post-hoc double-pkD audit over the in-memory bindings (see
  /// findDoublePkD in claim.dart): pkD values shared by 2+ Gmails.
  /// Offline and permanent: clone-or-shared-device signal for review.
  Map<String, List<String>> auditDoublePkD() => findDoublePkD(devices);

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
    final print = prints[key];
    if (print != null &&
        stampOlderThan(
            stampMillis: print.updatedAtMillis,
            now: at,
            age: kStudentPurgeStale)) {
      prints.remove(key);
      deleted.add('facePrints/$key');
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
      required ClassRecord record,
      String? profOrg}) async {
    _needOnline();
    lastPushedBy = profUid;
    // Session org immutable on update: a stamped doc keeps its org.
    final prev = sessions[record.id];
    final prevOrg = prev?['org'] as String? ?? '';
    final wantOrg = record.org.isNotEmpty
        ? record.org
        : (prevOrg.isNotEmpty
            ? prevOrg
            : ((profOrg != null && profOrg.isNotEmpty)
                ? profOrg
                : orgOf(profEmail)));
    final stamped = wantOrg.isNotEmpty && record.org != wantOrg
        ? ClassRecord(
            id: record.id,
            courseId: record.courseId,
            classLabel: record.classLabel,
            dateIso: record.dateIso,
            timestampIso: record.timestampIso,
            startIso: record.startIso,
            windows: record.windows,
            names: record.names,
            rolls: record.rolls,
            org: wantOrg)
        : record;
    sessions[record.id] = sessionToDoc(
        profUid: profUid,
        profEmail: profEmail,
        profName: profName,
        record: stamped,
        profOrg: wantOrg);
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
