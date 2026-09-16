// refactor) — all bodies verbatim EXCEPT claimStudentDevice, whose
// exact-duplicate verdict+write computation now calls the shared pure
// helper [resolveStudentClaimWrite] (see claim.dart).
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

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
StateError _rulesError(String op) => StateError(cloudRulesHint(op));

class FirestoreCloudSync implements CloudSync {
  @override
  final bool available;

  /// DI seam for the online probe: resolves the signed-in uid. Defaults to
  /// FirebaseAuth; tests inject a stub so no Firebase is needed.
  final String? Function()? currentUid;

  FirestoreCloudSync({this.available = true, this.currentUid});

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
    // Owner-doc probe: rules allow get users/<uid> for the owner while
    // `allow list: if false` denies every collection query. The previous
    // `.collection('users').limit(1).get(server)` was such a list
    // (Query users order by __name__) — denied on every startup.
    // Signed-out has no owner doc: return false without touching Firestore
    // (callers' server gets still decide offline; sync stays local-only).
    String? uid;
    try {
      uid = currentUid?.call() ?? FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      uid = null;
    }
    if (uid == null || uid.isEmpty) return false;
    // Any answer from the server counts as online — including
    // permission-denied (rules reachable) and unauthenticated. Only
    // transport failures and timeouts mean offline.
    try {
      await _db
          .collection('users')
          .doc(uid)
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
        updatedAtMillis: (d['updatedAtMillis'] as num?)?.toInt() ?? 0,
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
      // Numeric twin of updatedAt: the owner-lazy purge gate compares it
      // against request.time (ISO strings don't compare server-side).
      'updatedAtMillis': DateTime.now().toUtc().millisecondsSinceEpoch,
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
      return _deviceFrom(d, key);
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
    // bypass the claim transaction (single-device verdict + 30-day cooldown
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
  Future<List<ClassRecord>> pullProfSessions(String profUid,
          {String org = ''}) =>
      // H1/H2: org-scoped when stamped (callers always pass org; rules
      // deny org-less rows, so an unstamped call only sees stamped docs).
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
        attestationChain: [
          for (final e in (d?['attestationChain'] as List? ?? const []))
            if (e is String && e.trim().isNotEmpty) e.trim()
        ],
        livenessVer: d?['livenessVer'] as String? ?? '',
        integrityFlag: d?['integrityFlag'] as String? ?? '',
        appAttestRawHex:
            (d?['appAttestRawHex'] as String? ?? '').trim().toLowerCase(),
        appAttestCredKeyHex:
            (d?['appAttestCredKeyHex'] as String? ?? '').trim().toLowerCase(),
        deviceId: (d?['deviceId'] as String? ?? '').trim(),
      );

  @override
  Future<ClaimOutcome> claimStudentDevice(
      {required StudentDeviceDoc doc,
      required String installId,
      DateTime? now,
      MoveIntent? moveIntent}) async {
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
            moveIntent: moveIntent);
        final isFirst = claim.isFirst;
        final isMove = claim.isMove;
        final org = doc.org.isNotEmpty ? doc.org : orgOf(key);        tx.set(devRef, {
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
          // Tracks 2+3 extended claim (offline device binding: pkD,
          // self-asserted attestation level + window). No server-verdict
          // fields exist — there is no server re-check.
          'pkDHex': doc.pkDHex,
          'attestationLevel': doc.attestationLevel,
          'attestedAtMillis': doc.attestedAtMillis,
          'attestedUntilMillis': doc.attestedUntilMillis,
          // Security §7 additive (offline verify + audit; no verdict change).
          'attestationChain': List<String>.of(doc.attestationChain),
          'livenessVer': doc.livenessVer,
          'integrityFlag': doc.integrityFlag,
          // iOS App Attest artifacts ('' on Android — professor iOS branch
          // parses appAttestRawHex; rules type-lock both, like the chain).
          'appAttestRawHex': doc.appAttestRawHex.trim().toLowerCase(),
          'appAttestCredKeyHex': doc.appAttestCredKeyHex.trim().toLowerCase(),
          // Stable phone id for the same-phone reclaim ('' when unknown —
          // desktop / pre-upgrade). Rules enforce the match server-side
          // (isSamePhoneReclaim); the client assertion alone moves nothing.
          'deviceId': doc.deviceId.trim(),
          'updatedAt': at.toIso8601String(),
        }, SetOptions(merge: true));
        tx.set(instRef, {
          'email': key,
          'pkHex': doc.pkHex,
          'org': org,
          'updatedAtMillis': atMillis,
          'updatedAt': at.toIso8601String(),
        }, SetOptions(merge: true));
        // Professor-searchable directory row (name/roll/email/org + the
        // student device public key for offline email→key pins).
        tx.set(_db.collection('studentDirectory').doc(key), {
          'email': key,
          'name': doc.name,
          'roll': doc.roll,
          'nameLower': doc.name.toLowerCase(),
          'org': org,
          'pkS': doc.pkHex.trim().toLowerCase(),
          'updatedAtMillis': atMillis,
          'updatedAt': at.toIso8601String(),
        }, SetOptions(merge: true));
        outcome = ClaimOutcome(
            isFirst: isFirst, isMove: isMove, isReclaim: claim.isReclaim);
      }).timeout(const Duration(seconds: 12));
      return outcome ?? const ClaimOutcome();
    } on StateError {
      rethrow; // refusal copy reaches the UI verbatim
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        // Scoped denial (verdict-by-evidence): the transaction's own reads
        // cannot distinguish "rules not deployed" from "install holds
        // another Gmail" (a cross-org install-doc read denies before the
        // client verdict ever runs). Probe by evidence — server source so
        // cached reads cannot mask the rules verdict:
        // - own binding denied → genuine rules problem → deploy hint.
        // - own binding clean + install doc denied → the install holds a
        //   different Gmail → friendly installConflict copy (the incumbent
        //   email is unreadable, so the 'another account' fallback applies).
        // - both readable → the denial came from a write the client verdict
        //   allowed (race/desync) → deploy hint for the dev to reconcile.
        throw await _scopedClaimDenial(key, installId);
      }
      if (_isOfflineError(e)) {
        throw StateError(
            'Student enrollment needs internet (one enrolled device per Gmail is checked online). Connect and tap Save again — your capture is kept.');
      }
      rethrow;
    } catch (e) {
      if (_isOfflineError(e)) {
        throw StateError(
            'Student enrollment needs internet (one enrolled device per Gmail is checked online). Connect and tap Save again — your capture is kept.');
      }
      rethrow;
    }
  }

  /// Scoped mapping for a permission-denied claim transaction (see the call
  /// site): own-doc denied → deploy hint; install-doc denied after a clean
  /// own-doc read → friendly installConflict copy; both readable → deploy
  /// hint. Offline probes surface the offline copy (verbatim). Never throws
  /// raw Firebase text — every branch is a StateError with user/dev copy.
  Future<StateError> _scopedClaimDenial(String key, String installId) async {
    const probeTimeout = Duration(seconds: 8);
    try {
      await _db
          .collection('studentDevices')
          .doc(key)
          .get(const GetOptions(source: Source.server))
          .timeout(probeTimeout);
    } on FirebaseException catch (e) {
      if (_isOfflineError(e)) {
        return StateError(
            'Student enrollment needs internet (one enrolled device per Gmail is checked online). Connect and tap Save again — your capture is kept.');
      }
      // Own binding unreadable (denied or otherwise) → rules problem.
      return _rulesError('enrollment');
    } catch (e) {
      if (_isOfflineError(e)) {
        return StateError(
            'Student enrollment needs internet (one enrolled device per Gmail is checked online). Connect and tap Save again — your capture is kept.');
      }
      return _rulesError('enrollment');
    }
    // Own-doc reads clean: probe the install mapping.
    try {
      await _db
          .collection('deviceInstalls')
          .doc(installId)
          .get(const GetOptions(source: Source.server))
          .timeout(probeTimeout);
    } on FirebaseException catch (e) {
      if (_isOfflineError(e)) {
        return StateError(
            'Student enrollment needs internet (one enrolled device per Gmail is checked online). Connect and tap Save again — your capture is kept.');
      }
      if (e.code == 'permission-denied') {
        return StateError(studentClaimMessage(
            const StudentClaimResult(StudentClaim.installConflict), null));
      }
      return _rulesError('enrollment');
    } catch (e) {
      if (_isOfflineError(e)) {
        return StateError(
            'Student enrollment needs internet (one enrolled device per Gmail is checked online). Connect and tap Save again — your capture is kept.');
      }
      return _rulesError('enrollment');
    }
    return _rulesError('enrollment');
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
        // Security §2/§7 heartbeat scope: this touch bumps lastSeen/updated
        // ONLY (merge:true preserves pkDHex/level/window + attestationChain/
        // livenessVer/integrityFlag untouched). attestedUntil rolls via the
        // local DeviceKey.heartbeat() before the next claimStudentDevice
        // (enroll/move/re-key rewrites the window); a touch never extends
        // the window without the device in hand, and MoveIntent/30d-cooldown
        // live in the claim verdict only (see claim.dart) — untouched here.
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
  Future<PurgeOutcome> purgeExpiredSelfData(
      {required String emailLower, String uid = '', DateTime? now}) async {
    if (!available) return const PurgeOutcome();
    final at = (now ?? DateTime.now()).toUtc();
    final key = emailLower.toLowerCase();
    final deleted = <String>[];
    // Eligibility here is a client-clock pre-check ONLY: every delete is
    // re-gated by the rules on request.time, so a wrong clock deletes
    // nothing early. Deletes run individually — a batch fails atomically,
    // and one not-yet-stale doc must not spare the rest. Denied/offline
    // per doc means "not eligible" and is swallowed (best-effort).
    Future<void> tryDelete(
        String label, DocumentReference<Map<String, dynamic>> ref) async {
      try {
        await ref.delete().timeout(const Duration(seconds: 8));
        deleted.add(label);
      } catch (_) {}
    }

    Future<int> storedStamp(String collection, String id, String field) async {
      final snap = await _db
          .collection(collection)
          .doc(id)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 8));
      if (!snap.exists) return 0;
      return (snap.data()?[field] as num?)?.toInt() ?? 0;
    }

    try {
      if (stampOlderThan(
          stampMillis:
              await storedStamp('studentDevices', key, 'lastSeenAtMillis'),
          now: at,
          age: kStudentPurgeStale)) {
        await tryDelete(
            'studentDevices/$key', _db.collection('studentDevices').doc(key));
      }
      if (stampOlderThan(
          stampMillis:
              await storedStamp('studentDirectory', key, 'updatedAtMillis'),
          now: at,
          age: kStudentPurgeStale)) {
        await tryDelete('studentDirectory/$key',
            _db.collection('studentDirectory').doc(key));
      }
      if (uid.isNotEmpty &&
          stampOlderThan(
              stampMillis:
                  await storedStamp('users', uid, 'updatedAtMillis'),
              now: at,
              age: kStudentPurgeStale)) {
        await tryDelete('users/$uid', _db.collection('users').doc(uid));
      }
    } catch (_) {
      return PurgeOutcome(deleted);
    }
    return PurgeOutcome(deleted);
  }

  @override
  Future<void> updateStudentRoll(
      {required String emailLower, required String newRoll}) async {
    // CLIENT-SIDE ONLY — requires
    // `firebase deploy --only firestore:rules --project proximity-attendence`
    // for the roll-update path (same-device owner update + directory row).
    // Permission-denied maps to the shared deploy hint (existing
    // rules-error pattern via _rulesError), never raw Firebase text.
    // Historical session rolls/names untouched — only the binding +
    // directory row change.
    _needAvailable();
    final want = newRoll.trim();
    if (want.isEmpty) throw StateError('ID Number is required.');
    final key = emailLower.toLowerCase();
    try {
      await _db.runTransaction((tx) async {
        final devRef = _db.collection('studentDevices').doc(key);
        final snap = await tx.get(devRef);
        if (!snap.exists) {
          throw StateError(
              'No enrolled device found for this account — enroll this device first.');
        }
        final binding = _deviceFrom(snap.data(), key);
        final at = DateTime.now().toUtc();
        final atMillis = at.millisecondsSinceEpoch;
        final org =
            binding.org.isNotEmpty ? binding.org : orgOf(key);
        // Same-device roll edit: preserve identity/binding stamps, refresh
        // only the fresh stamps the rules require (lastSeen/updated within
        // 1h) + the roll. lastMove/moveCount/created/pk/install untouched.
        tx.set(devRef, {
          'email': key,
          'uid': binding.uid,
          'pkHex': binding.pkHex,
          'installId': binding.installId,
          'name': binding.name,
          'roll': want,
          'modelVer': binding.modelVer,
          'platform': binding.platform,
          'org': org,
          'createdAtMillis': binding.createdAtMillis,
          'lastMoveAtMillis': binding.lastMoveAtMillis,
          'lastSeenAtMillis': atMillis,
          'updatedAtMillis': atMillis,
          'moveCount': binding.moveCount,
          'pkDHex': binding.pkDHex,
          'attestationLevel': binding.attestationLevel,
          'attestedAtMillis': binding.attestedAtMillis,
          'attestedUntilMillis': binding.attestedUntilMillis,
          'attestationChain':
              List<String>.of(binding.attestationChain),
          'livenessVer': binding.livenessVer,
          'integrityFlag': binding.integrityFlag,
          'updatedAt': at.toIso8601String(),
        }, SetOptions(merge: true));
        tx.set(_db.collection('studentDirectory').doc(key), {
          'email': key,
          'name': binding.name,
          'roll': want,
          'nameLower': binding.name.toLowerCase(),
          'org': org,
          'pkS': binding.pkHex.trim().toLowerCase(),
          'updatedAtMillis': atMillis,
          'updatedAt': at.toIso8601String(),
        }, SetOptions(merge: true));
      }).timeout(const Duration(seconds: 12));
      BleLog.log('SYNC', 'id update ok $key');
    } on StateError {
      rethrow;
    } on FirebaseException catch (e) {
      BleLog.log('SYNC', 'id update refused (${e.code}) — deploy hint');
      if (e.code == 'permission-denied') throw _rulesError('id update');
      if (_isOfflineError(e)) {
        throw StateError(
            'You appear offline — connect to the internet to update your ID.');
      }
      rethrow;
    } catch (e) {
      if (_isOfflineError(e)) {
        throw StateError(
            'You appear offline — connect to the internet to update your ID.');
      }
      rethrow;
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
    // H1: directory list is per-doc org-gated server-side — every prefix
    // query MUST carry where('org', == org) (callers always pass org), or
    // the query denies as a whole when it would match other-org rows.
    if (org.isEmpty) {
      throw StateError('Directory search needs an org (query-constraint).');
    }
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
          updatedAtMillis:
              (d.data()['updatedAtMillis'] as num?)?.toInt() ?? 0,
          pkSHex: (d.data()['pkS'] as String? ?? '').trim().toLowerCase(),
        ),
    ];
  }

  @override
  Future<Map<String, String>> fetchStudentKeyPins(
      {required String org, int limit = 200}) async {
    _needAvailable();
    if (org.trim().isEmpty) return const {};
    try {
      final snap = await _db
          .collection('studentDirectory')
          .where('org', isEqualTo: org.trim().toLowerCase())
          .limit(limit)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
      final out = <String, String>{};
      for (final d in snap.docs) {
        final email =
            (d.data()['email'] as String? ?? '').trim().toLowerCase();
        final pkS =
            (d.data()['pkS'] as String? ?? '').trim().toLowerCase();
        if (email.isNotEmpty && _isHex64(pkS)) out[email] = pkS;
      }
      return out;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') return const {};
      if (_isOfflineError(e)) return const {};
      rethrow;
    } catch (e) {
      if (_isOfflineError(e)) return const {};
      rethrow;
    }
  }

  static bool _isHex64(String s) {
    if (s.length != 64) return false;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (!((c >= 48 && c <= 57) ||
          (c >= 97 && c <= 102) ||
          (c >= 65 && c <= 70))) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<void> uploadProfKey(
      {required String emailLower,
      required String uid,
      required String org,
      required String pkPHex,
      DateTime? now}) async {
    _needAvailable();
    final key = emailLower.trim().toLowerCase();
    final pk = pkPHex.trim().toLowerCase();
    if (key.isEmpty || uid.isEmpty || !_isHex64(pk)) return;
    final at = (now ?? DateTime.now()).toUtc();
    final atMillis = at.millisecondsSinceEpoch;
    final ref = _db.collection('profDevices').doc(key);
    try {
      await _db.runTransaction((tx) async {
        final snap = await tx.get(ref);
        final List<Map<String, dynamic>> list = [
          for (final e in (snap.exists
                  ? (snap.data()?['pubKeys'] as List? ?? const [])
                  : const []))
            if (e is Map) Map<String, dynamic>.from(e)
        ];
        if (!list.any((e) => '${e['pkP']}'.toLowerCase() == pk)) {
          list.add({'pkP': pk, 'createdAtMillis': atMillis});
          list.sort((a, b) =>
              ((a['createdAtMillis'] as num?)?.toInt() ?? 0).compareTo(
                  (b['createdAtMillis'] as num?)?.toInt() ?? 0));
          while (list.length > 8) {
            list.removeAt(0);
          }
        }
        tx.set(ref, {
          'email': key,
          'uid': uid,
          'org': org,
          'pubKeys': list,
          'updatedAtMillis': atMillis,
          'updatedAt': at.toIso8601String(),
        }, SetOptions(merge: true));
      }).timeout(const Duration(seconds: 12));
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw _rulesError('prof key publish');
      if (_isOfflineError(e)) {
        throw StateError('You appear offline — connect to the internet.');
      }
      rethrow;
    } catch (e) {
      if (_isOfflineError(e)) {
        throw StateError('You appear offline — connect to the internet.');
      }
      rethrow;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchProfKeys(String emailLower) async {
    _needAvailable();
    final key = emailLower.trim().toLowerCase();
    if (key.isEmpty) return const [];
    try {
      final snap = await _db
          .collection('profDevices')
          .doc(key)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 8));
      if (!snap.exists) return const [];
      final list = snap.data()?['pubKeys'] as List? ?? const [];
      return [
        for (final e in list)
          if (e is Map) Map<String, dynamic>.from(e)
      ];
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw _rulesError('prof key fetch');
      if (_isOfflineError(e)) return const [];
      rethrow;
    } catch (e) {
      if (_isOfflineError(e)) return const [];
      rethrow;
    }
  }

  @override
  Future<List<StudentDirectoryEntry>> searchStudents(
      {String emailPrefix = '',
      String rollPrefix = '',
      String namePrefix = '',
      int limit = 10,
      String org = ''}) async {
    _needAvailable();
    final (email: eq, roll: rq, name: nq) = normalizeSearchPrefixes(
        emailPrefix: emailPrefix,
        rollPrefix: rollPrefix,
        namePrefix: namePrefix);
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
