// Student device binding: claim verdict + shared verdict/write helper +
// app-install identity. Split out of core/cloud_sync.dart (M6 sync refactor)
// with getOrCreateInstallId/newInstallId folded in from
// core/device_identity.dart — bodies verbatim except the ONE extracted
// shared helper [resolveStudentClaimWrite] (see below).
library;

import 'dart:math';

import 'store/record_helpers.dart';
import 'store/store_base.dart';

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
  final String org; // Google-account domain (see orgOf), '' = legacy
  final int createdAtMillis;
  final int lastMoveAtMillis;
  final int lastSeenAtMillis;
  final int updatedAtMillis;
  final int moveCount;
  // --- Tracks 2+3 extended claim {pkS,pkD,installId,attestationLevel,
  // attestedAt,attestedUntil=+90d} (+ pipeline tag for flapping audit).
  // Defaults keep legacy constructors compiling; enrollment always stamps
  // them. [modelVer] is kept as the pipeline-version slot (now stamped
  // with the plugin verifierVer) so existing rules/queries keep working.
  /// DKey public bytes hex ('' = unbound legacy).
  final String pkDHex;
  /// Attestation level wire name ('FULL'/'STD'/'NONE').
  final String attestationLevel;
  final int attestedAtMillis;
  final int attestedUntilMillis;
  const StudentDeviceDoc(
      {required this.email,
      required this.uid,
      required this.pkHex,
      required this.name,
      required this.roll,
      required this.modelVer,
      this.installId = '',
      this.platform = '',
      this.org = '',
      this.createdAtMillis = 0,
      this.lastMoveAtMillis = 0,
      this.lastSeenAtMillis = 0,
      this.updatedAtMillis = 0,
      this.moveCount = 0,
      this.pkDHex = '',
      this.attestationLevel = 'NONE',
      this.attestedAtMillis = 0,
      this.attestedUntilMillis = 0});
}

/// Minimum gap between two different-device enrollments of one Gmail.
/// Genuine phone change waits this out (unlimited moves, at most one per
/// 30 days); ping-ponging two phones cannot. No reset shortcut exists: any
/// reset permission would be self-service since professor registration is
/// self-asserted this phase.
const kStudentMoveCooldown = Duration(days: 30);

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
/// [moveIntentValid]: an old-DKey-signed MoveIntent (verified by the
/// caller against the PREVIOUS binding's pkD) grants an instant move even
/// inside the cooldown — genuine phone change with the old phone at hand.
/// Without it the 30d cooldown stands (lost/stolen path, manual attendance
/// covers the gap).
StudentClaimResult evaluateStudentClaim({
  required String localPkHex,
  required String localInstallId,
  required StudentDeviceDoc? binding,
  required String? installEmail,
  required String email,
  DateTime? now,
  bool moveIntentValid = false,
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
  // Old-DKey-signed MoveIntent: instant move (the old phone vouches).
  if (moveIntentValid) {
    return const StudentClaimResult(StudentClaim.allowedMove);
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
/// most one per 30 days) and points at manual attendance for the gap — there
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
          ? ' You can re-enroll this device on ${dateIsoOf(r.retryAfter!)} — enrollment moves to a new phone once a month (unlimited moves, at most one per 30 days).'
          : '';
      final seen = binding != null && binding.lastSeenAtMillis > 0
          ? ' Its last online activity was ${dateIsoOf(DateTime.fromMillisecondsSinceEpoch(binding.lastSeenAtMillis, isUtc: true))}.'
          : '';
      return 'This Gmail is enrolled on another device.$seen$retry '
          'Until then, ask your professor to mark your attendance manually (Request manual attendance in class).';
    default:
      return '';
  }
}

/// Outcome of a successful [CloudSync.claimStudentDevice].
class ClaimOutcome {
  final bool isFirst;
  final bool isMove;
  const ClaimOutcome({this.isFirst = false, this.isMove = false});
}

/// Pure verdict+write computation for a claim transaction.
///
/// This is the ONE shared helper extracted (M6) from the exact-duplicate
/// bodies in FirestoreCloudSync.claimStudentDevice and
/// FakeCloudSync.claimStudentDevice: both called [evaluateStudentClaim],
/// threw the same StateError refusal copy, and derived the same
/// isFirst/isMove/createdAt/lastMove/moveCount values — only the write
/// mechanism differs (Firestore tx.set map vs in-memory copy), which stays
/// in each backend. Throws StateError with the user-facing copy when
/// refused (cooldown/install-conflict) — the second of two racing devices
/// loses.
class ClaimWrite {
  final StudentClaimResult verdict;
  final bool isFirst;
  final bool isMove;
  final int createdAtMillis;
  final int lastMoveAtMillis;
  final int moveCount;
  const ClaimWrite(
      {required this.verdict,
      required this.isFirst,
      required this.isMove,
      required this.createdAtMillis,
      required this.lastMoveAtMillis,
      required this.moveCount});
}

ClaimWrite resolveStudentClaimWrite({
  required StudentDeviceDoc doc,
  required String installId,
  required StudentDeviceDoc? binding,
  required String? installEmail,
  required String email,
  DateTime? now,
  bool moveIntentValid = false,
}) {
  final at = (now ?? DateTime.now()).toUtc();
  final atMillis = at.millisecondsSinceEpoch;
  final key = email.toLowerCase();
  final verdict = evaluateStudentClaim(
      localPkHex: doc.pkHex,
      localInstallId: installId,
      binding: binding,
      installEmail: installEmail,
      email: key,
      now: at,
      moveIntentValid: moveIntentValid);
  if (!verdict.ok) {
    throw StateError(studentClaimMessage(verdict, binding));
  }
  final isFirst = verdict.claim == StudentClaim.firstBind;
  final isMove = verdict.claim == StudentClaim.allowedMove;
  return ClaimWrite(
    verdict: verdict,
    isFirst: isFirst,
    isMove: isMove,
    createdAtMillis: binding != null && binding.createdAtMillis > 0
        ? binding.createdAtMillis
        : atMillis,
    lastMoveAtMillis: isMove || isFirst || binding == null
        ? atMillis
        : (binding.lastMoveAtMillis > 0 ? binding.lastMoveAtMillis : atMillis),
    moveCount: (binding?.moveCount ?? 0) + (isMove ? 1 : 0),
  );
}

// --- App-install identity (folded in from core/device_identity.dart) ---
//
// No reliable cross-platform hardware ID exists (Android ANDROID_ID resets,
// iOS offers nothing stable), so the binding key is an app-generated 128-bit
// UUID persisted in secure storage (Keystore/Keychain). Properties:
//   - stable across restarts and app updates on the same install;
//   - app-data clear / reinstall regenerates it (counts as a device move,
//     subject to the 30-day cooldown);
//   - app clones, dual-app copies and work profiles hold SEPARATE secure
//     storage, so a clone gets its own installId and counts as a different
//     device — the same phone can never hold two student enrollments.
// Identity here is only ever (pkHex, installId) joined against the cloud
// studentDevices/deviceInstalls docs (see cloud_sync claim logic).

/// Generates a 128-bit hex install ID. [random] is injectable for tests.
String newInstallId([Random? random]) {
  final r = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Returns the persisted install ID, creating and storing one on first run.
Future<String> getOrCreateInstallId(DeviceStore store) async {
  try {
    final existing = await store.readInstallId();
    if (existing != null && existing.isNotEmpty) return existing;
  } catch (_) {}
  final id = newInstallId();
  try {
    await store.writeInstallId(id);
  } catch (_) {}
  return id;
}

// --- Track 3 device-proof seam (beside evaluateStudentClaim) ---
//
// The pure device-proof verdict itself lives in the protocol
// ([evaluateDeviceProof] in package:proximity_protocol — same import
// surface as the Sig_s helpers), so offline professor verification and
// the app share one implementation. What lives HERE is the sync-side
// audit: the double-pkD flag.
//
// /// Double-pkD audit flag (post-hoc, on sync): groups enrolled bindings
// by non-empty pkDHex; every pkD shared by 2+ distinct Gmails is a
// clone-or-shared-device signal for professor review. Pure — the sync
// layer calls it after pulling studentDevices and surfaces the groups.
Map<String, List<String>> findDoublePkD(
    Map<String, StudentDeviceDoc> devices) {
  final byPkD = <String, List<String>>{};
  for (final e in devices.entries) {
    final pkD = e.value.pkDHex.trim();
    if (pkD.isEmpty) continue;
    byPkD.putIfAbsent(pkD.toLowerCase(), () => []).add(e.key);
  }
  return {
    for (final e in byPkD.entries)
      if (e.value.length > 1) e.key: (e.value..sort()),
  };
}
