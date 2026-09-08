// CloudSync public API surface: abstract interface + professor push
// identity + provider. Split out of core/cloud_sync.dart (M6 sync
// refactor) — bodies verbatim. Backend implementations live in
// firestore_sync.dart / fake_sync.dart.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_storage/storage.dart';

import 'claim.dart';
import 'directory.dart';
import 'roles.dart';

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
  /// [moveIntentValid]: old-DKey-signed MoveIntent verified by the caller —
  /// instant move even inside the 30d cooldown.
  Future<ClaimOutcome> claimStudentDevice(
      {required StudentDeviceDoc doc,
      required String installId,
      DateTime? now,
      bool moveIntentValid = false});

  /// Best-effort last-online heartbeat: bumps lastSeenAtMillis only when
  /// this device still holds the binding. Returns true when touched.
  Future<bool> touchStudentDevice(
      {required String emailLower,
      required String pkHex,
      required String installId,
      DateTime? now});

  /// Owner-lazy six-month purge (the no-backend deleter — no Cloud
  /// Functions, no TTL policy, both billing-gated on Spark): deletes the
  /// caller's OWN enrollment pair (studentDevices + studentDirectory, keyed
  /// by email) plus their users doc (keyed by [uid])
  /// when each doc's STORED stamp is past [kStudentPurgeStale] by the
  /// client's clock (pre-check only — rules re-gate EVERY delete on
  /// request.time, so clock games delete nothing early, and a live
  /// enrollment can never be taken: missing/zero stamps deny).
  /// Best-effort: offline, denied, or absent → empty outcome, never throws.
  /// classSessions are never touched by any purge path (professors' past
  /// records stay); deviceInstalls rows linger by design (unguessable
  /// UUID keys, unlistable — the install→email mapping they hold keeps
  /// enforcing one-Gmail-per-install after the binding is gone).
  Future<PurgeOutcome> purgeExpiredSelfData(
      {required String emailLower, String uid = '', DateTime? now});

  /// deviceInstalls/{installId} owner Gmail, or null when this install never
  /// enrolled. Drives the same-phone second-enrollment refusal.
  Future<String?> fetchInstallEmail(String installId);

  /// Professor directory search over enrolled students (online). Each
  /// non-empty prefix runs a server-side prefix query (email / roll /
  /// nameLower), results merged by email and capped at [limit]. When [org]
  /// is non-empty each query additionally filters where('org', == org), so
  /// cross-domain rows never list. Throws StateError offline or when rules
  /// refuse (deploy them).
  Future<List<StudentDirectoryEntry>> searchStudents(
      {String emailPrefix = '',
      String rollPrefix = '',
      String namePrefix = '',
      int limit = 10,
      String org = ''});
  Future<void> pushSession(
      {required String profUid,
      required String profEmail,
      required String profName,
      required ClassRecord record,
      String? profOrg});
  Future<List<ClassRecord>> pullProfSessions(String profUid,
      {String org = ''});
  Future<List<ClassRecord>> pullStudentSessions(String emailLower,
      {String org = ''});
  Future<void> renameCourseCloud(
      {required String profUid, required String oldName, required String newName});
  Future<void> deleteSessionsCloud(
      {required String profUid, required List<String> ids});
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
