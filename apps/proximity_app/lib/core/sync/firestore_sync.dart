// Firestore CloudSync backend. Split out of core/cloud_sync.dart (M6 sync
// refactor) — all bodies verbatim EXCEPT claimStudentDevice, whose
// exact-duplicate verdict+write computation now calls the shared pure
// helper [resolveStudentClaimWrite] (see claim.dart).
library;

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:proximity_storage/storage.dart';

import 'attest_http.dart';
import 'claim.dart';
import 'cloud_api.dart';
import 'directory.dart';
import 'org.dart';
import 'roles.dart';
import 'sessions.dart';

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

  /// Seams for the attestation callable (see attest_http.dart): [idTokenOf]
  /// supplies the Firebase ID token (wired to AuthService.getIdToken in
  /// main; absent in tests/offline builds → verify reports unreachable and
  /// the engine defers). [postJson] defaults to the platform HTTP client.
  final Future<String?> Function()? idTokenOf;
  final Future<({int status, Map<String, dynamic> json})> Function(
      Uri url, Map<String, String> headers, String body)? postJson;

  FirestoreCloudSync(
      {this.available = true, this.idTokenOf, this.postJson});

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
      final email = (d['email'] as String? ?? '').toLowerCase();
      return RoleDoc(
        uid: uid,
        email: email,
        name: d['name'] as String? ?? '',
        roles: roles,
        displayName: d['displayName'] as String? ?? '',
        lastMode: d['lastMode'] as String? ?? '',
        org: (d['org'] as String? ?? '').isNotEmpty
            ? (d['org'] as String)
            : orgOf(email),
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
    final org =
        doc.org.isNotEmpty ? doc.org : orgOf(doc.email);
    final data = <String, dynamic>{
      'email': doc.email.toLowerCase(),
      'name': doc.name,
      'roles': FieldValue.arrayUnion(doc.roles),
      'displayName': doc.displayName,
      'org': org,
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
        org: (d['org'] as String? ?? '').isNotEmpty
            ? (d['org'] as String)
            : orgOf(key),
        createdAtMillis: (d['createdAtMillis'] as num?)?.toInt() ?? 0,
        lastMoveAtMillis: (d['lastMoveAtMillis'] as num?)?.toInt() ?? 0,
        lastSeenAtMillis: (d['lastSeenAtMillis'] as num?)?.toInt() ?? 0,
        updatedAtMillis: (d['updatedAtMillis'] as num?)?.toInt() ?? 0,
        moveCount: (d['moveCount'] as num?)?.toInt() ?? 0,
        pkDHex: d['pkDHex'] as String? ?? '',
        attestationLevel: d['attestationLevel'] as String? ?? 'NONE',
        attestedAtMillis: (d['attestedAtMillis'] as num?)?.toInt() ?? 0,
        attestedUntilMillis:
            (d['attestedUntilMillis'] as num?)?.toInt() ?? 0,
        // Server-verdict fields are READ here (for the cheap-trigger gate
        // + Track 5 review queries) but never written by clients — see
        // kAttestationServerFields; the claim write below omits them.
        attestationAnomaly: (d['attestationAnomaly'] as bool?) ?? false,
        serverVerifiedAtMillis:
            (d['serverVerifiedAtMillis'] as num?)?.toInt() ?? 0,
        serverVerifyReason: d['serverVerifyReason'] as String? ?? '',
        attestMaterialJson: d['attestMaterialJson'] as String? ?? '',
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
      required ClassRecord record,
      String? profOrg}) async {
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
                  record: record,
                  profOrg: profOrg),
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
  Future<List<ClassRecord>> pullProfSessions(String profUid,
          {String org = ''}) =>
      _querySessions((col) {
        var q = col.where('profUid', isEqualTo: profUid);
        if (org.isNotEmpty) q = q.where('org', isEqualTo: org);
        return q.limit(200);
      });

  @override
  Future<List<ClassRecord>> pullStudentSessions(String emailLower,
          {String org = ''}) =>
      _querySessions((col) {
        var q = col.where('studentEmails',
            arrayContains: emailLower.toLowerCase());
        if (org.isNotEmpty) q = q.where('org', isEqualTo: org);
        return q.limit(200);
      });

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
      // Rename bumps timestampIso (not just updatedAt): union merge takes
      // the NEWER record's header fields per id, so without this any device
      // holding a newer-timestamped copy under the OLD name would resurrect
      // it on the next merge — the rename would never converge, for
      // professors or for students reading the same docs.
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
        org: (d?['org'] as String? ?? '').isNotEmpty
            ? (d?['org'] as String)
            : orgOf(key),
        createdAtMillis: (d?['createdAtMillis'] as num?)?.toInt() ?? 0,
        lastMoveAtMillis: (d?['lastMoveAtMillis'] as num?)?.toInt() ?? 0,
        lastSeenAtMillis: (d?['lastSeenAtMillis'] as num?)?.toInt() ?? 0,
        updatedAtMillis: (d?['updatedAtMillis'] as num?)?.toInt() ?? 0,
        moveCount: (d?['moveCount'] as num?)?.toInt() ?? 0,
        pkDHex: d?['pkDHex'] as String? ?? '',
        attestationLevel: d?['attestationLevel'] as String? ?? 'NONE',
        attestedAtMillis: (d?['attestedAtMillis'] as num?)?.toInt() ?? 0,
        attestedUntilMillis:
            (d?['attestedUntilMillis'] as num?)?.toInt() ?? 0,
        attestationAnomaly: (d?['attestationAnomaly'] as bool?) ?? false,
        serverVerifiedAtMillis:
            (d?['serverVerifiedAtMillis'] as num?)?.toInt() ?? 0,
        serverVerifyReason: d?['serverVerifyReason'] as String? ?? '',
        attestMaterialJson: d?['attestMaterialJson'] as String? ?? '',
      );

  @override
  Future<ClaimOutcome> claimStudentDevice(
      {required StudentDeviceDoc doc,
      required String installId,
      DateTime? now,
      bool moveIntentValid = false}) async {
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
        // Shared verdict+write computation (see claim.dart): same refusal
        // copy and same stamp/count derivation as the fake.
        final claim = resolveStudentClaimWrite(
            doc: doc,
            installId: installId,
            binding: binding,
            installEmail: installEmail,
            email: key,
            now: at,
            moveIntentValid: moveIntentValid);
        final isFirst = claim.isFirst;
        final isMove = claim.isMove;
        final org = doc.org.isNotEmpty ? doc.org : orgOf(key);
        tx.set(devRef, {
          'email': key,
          'uid': doc.uid,
          'pkHex': doc.pkHex,
          'installId': installId,
          'name': doc.name,
          'roll': doc.roll,
          'modelVer': doc.modelVer,
          'platform': doc.platform,
          'org': org,
          'createdAtMillis': claim.createdAtMillis,
          'lastMoveAtMillis': claim.lastMoveAtMillis,
          'lastSeenAtMillis': atMillis,
          'updatedAtMillis': atMillis,
          'moveCount': claim.moveCount,
          // Tracks 2+3 extended claim (offline-verifiable device binding)
          // + client-written attestation material. The server-verdict
          // fields (kAttestationServerFields) are deliberately ABSENT:
          // only the endpoint's admin writes may set them (rules deny
          // client writes that change them).
          'pkDHex': doc.pkDHex,
          'attestationLevel': doc.attestationLevel,
          'attestedAtMillis': doc.attestedAtMillis,
          'attestedUntilMillis': doc.attestedUntilMillis,
          'attestMaterialJson': doc.attestMaterialJson,
          'updatedAt': at.toIso8601String(),
        }, SetOptions(merge: true));
        tx.set(instRef, {
          'email': key,
          'pkHex': doc.pkHex,
          'org': org,
          'updatedAtMillis': atMillis,
          'updatedAt': at.toIso8601String(),
        }, SetOptions(merge: true));
        // Professor-searchable directory row (name/roll/email/org only).
        tx.set(_db.collection('studentDirectory').doc(key), {
          'email': key,
          'name': doc.name,
          'roll': doc.roll,
          'nameLower': doc.name.toLowerCase(),
          'org': org,
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
  Future<AttestationVerifyOutcome> verifyAttestationChain(
      {required String emailLower, required String org}) async {
    _needAvailable();
    const unreachable =
        AttestationVerifyOutcome(ok: false, reason: 'unreachable');
    // No client arguments are sent: the endpoint verifies the caller's own
    // stored doc from Auth identity, so there is nothing here to forge.
    final provider = idTokenOf;
    if (provider == null) return unreachable;
    String? token;
    try {
      token = await provider().timeout(const Duration(seconds: 8));
    } catch (_) {
      return unreachable;
    }
    if (token == null || token.isEmpty) return unreachable;
    try {
      final res = await (postJson ?? postCallableJson)(
        Uri.parse(kVerifyAttestationUrl),
        {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        jsonEncode(const {'data': <String, dynamic>{}}),
      ).timeout(const Duration(seconds: 15));
      final err = res.json['error'];
      if (err is Map) {
        // v1 callables surface HttpsErrors as 200 + {error}: NOT_FOUND (no
        // binding), FAILED_PRECONDITION (roots-missing), mid-call drops —
        // all defer, none flag.
        final status = '${err['status'] ?? 'UNKNOWN'}';
        return AttestationVerifyOutcome(
            ok: false, reason: 'server-${status.toLowerCase()}');
      }
      if (res.status != 200) return unreachable;
      final result = res.json['result'];
      if (result is! Map) return unreachable;
      return AttestationVerifyOutcome(
        ok: true,
        anomaly: result['anomaly'] == true,
        reason: '${result['reason'] ?? ''}',
        serverVerifiedAtMillis:
            (result['serverVerifiedAtMillis'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return unreachable;
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
      String field, String prefix, int limit,
      {String org = ''}) async {
    var q = _db
        .collection('studentDirectory')
        .where(field, isGreaterThanOrEqualTo: prefix)
        .where(field, isLessThan: '$prefix\uf8ff');
    if (org.isNotEmpty) q = q.where('org', isEqualTo: org);
    final snap = await q
        .limit(limit)
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 8));
    return [
      for (final d in snap.docs)
        StudentDirectoryEntry(
          email: (d.data()['email'] as String? ?? '').toLowerCase(),
          name: d.data()['name'] as String? ?? '',
          roll: d.data()['roll'] as String? ?? '',
          org: d.data()['org'] as String? ?? '',
        ),
    ];
  }

  @override
  Future<List<StudentDirectoryEntry>> searchStudents(
      {String emailPrefix = '',
      String rollPrefix = '',
      String namePrefix = '',
      int limit = 10,
      String org = ''}) async {
    _needAvailable();
    final eq = emailPrefix.trim().toLowerCase();
    final rq = rollPrefix.trim();
    final nq = namePrefix.trim().toLowerCase();
    if (eq.isEmpty && rq.isEmpty && nq.isEmpty) return const [];
    try {
      // Perf: one round trip — the non-empty prefix queries fan out in
      // parallel (org-scoped prefix queries + client merge).
      final futures = <Future<List<StudentDirectoryEntry>>>[];
      if (rq.isNotEmpty) futures.add(_prefixQuery('roll', rq, limit, org: org));
      if (nq.isNotEmpty) {
        futures.add(_prefixQuery('nameLower', nq, limit, org: org));
      }
      if (eq.isNotEmpty) futures.add(_prefixQuery('email', eq, limit, org: org));
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
