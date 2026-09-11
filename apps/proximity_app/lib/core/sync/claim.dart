// Student device binding: claim verdict + shared verdict/write helper +
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

/// Face re-scan quota: at most one SAVED face-template replacement per
/// account every 30 days. Same duration as [kStudentMoveCooldown] but a
/// SEPARATE rule (device moves vs face-template replaces): changing one
/// must never change the other, hence the separate constant even though
/// both are currently 30 days. Enforced locally on the rescan-SAVE path
/// only (see EnrollmentController.upload); no claim/rules/server change.
const kFaceRescanCooldown = Duration(days: 30);

/// Lost-phone exemption window: when the STORED binding's last-seen is
/// older than this, a different device may re-enroll immediately — the old
/// phone is probably lost (a live phone heartbeats lastSeen on every
/// online return, so a genuinely old stamp proves real silence).
/// Keys off the stored value ONLY: there is deliberately no parameter for
/// asserting "I've been offline" at move time (worthless — self-forged),
/// and the stored value is trustworthy only because every write stamping
/// it must prove fresh against the server clock (see the rules'
/// fresh-stamp gate). Mirrored server-side with request.time, so
/// local-clock games change nothing.
const kStudentLostPhoneStale = Duration(days: 60);

/// Cloud-expiry window: owner-lazy purge eligibility per doc (see
/// CloudSync.purgeExpiredSelfData). Six months as a fixed 180-day bound —
/// not calendar months — so client pre-check and rules agree bit-exactly.
const kStudentPurgeStale = Duration(days: 180);

/// True when [stampMillis] (UTC epoch ms) is older than [age] before [now].
/// Zero/missing stamps are NEVER old (fail-closed: unknown age must unlock
/// neither the lost-phone exemption nor the purge).
bool stampOlderThan(
    {required int stampMillis, required DateTime now, required Duration age}) {
  if (stampMillis <= 0) return false;
  return now.toUtc().millisecondsSinceEpoch - stampMillis > age.inMilliseconds;
}

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
/// Without it the 30d cooldown stands, EXCEPT the lost-phone exemption:
/// a binding whose STORED lastSeen is past [kStudentLostPhoneStale] moves
/// immediately (lost/stolen path, manual attendance covers the gap).
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
  // Lost-phone exemption (stored lastSeen ONLY — no move-time assertion
  // exists to forge: the trust chain is freshness-checked writes →
  // trustworthy stored lastSeen → this read, re-evaluated server-side
  // with request.time). Runs before the cooldown, after the install gate
  // (a stale binding never frees the install's one-Gmail rule).
  if (stampOlderThan(
      stampMillis: binding.lastSeenAtMillis,
      now: at,
      age: kStudentLostPhoneStale)) {
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
      // Global date rule, display only: DD-MM-YYYY.
      final retry = r.retryAfter != null
          ? ' You can re-enroll this device on ${displayDateOf(r.retryAfter!)} — enrollment moves to a new phone once a month (unlimited moves, at most one per 30 days).'
          : '';
      final seen = binding != null && binding.lastSeenAtMillis > 0
          ? ' Its last online activity was ${displayDateOf(DateTime.fromMillisecondsSinceEpoch(binding.lastSeenAtMillis, isUtc: true))}.'
          : '';
      return 'This Gmail is enrolled on another device.$seen$retry '
          'Until then, ask your professor to mark your attendance manually (Request manual attendance in class).';
    default:
      return '';
  }
}

/// True when a saved face re-scan at [stampMillis] (UTC epoch ms) blocks
/// another saved re-scan at [now]. Zero/missing stamps (never rescanned,
/// incl. pre-upgrade docs) NEVER block — the first post-upgrade rescan is
/// always allowed once, then it stamps. Durations derive from
/// [kFaceRescanCooldown], never literals.
bool faceRescanBlocked({required int stampMillis, required DateTime now}) {
  if (stampMillis <= 0) return false;
  return now.toUtc().millisecondsSinceEpoch - stampMillis <
      kFaceRescanCooldown.inMilliseconds;
}

/// Eligible UTC date for the next saved face re-scan after [stampMillis].
/// Derives from [kFaceRescanCooldown], never literals.
DateTime faceRescanEligibleAt(int stampMillis) =>
    DateTime.fromMillisecondsSinceEpoch(
        stampMillis + kFaceRescanCooldown.inMilliseconds,
        isUtc: true);

/// Friendly refusal copy for a blocked face re-scan. Names the exact
/// eligible date via [displayDateOf] (global DD-MM-YYYY rule) and points
/// at manual attendance for the gap (same voice as the move-cooldown
/// copy). Single source of truth — EnrollmentController.upload returns
/// this verbatim. Verbatim — do not reword without updating the rescan
/// tests.
String faceRescanCooldownMessage(DateTime eligible) =>
    'You already updated your face scan recently. '
    'You can scan again on ${displayDateOf(eligible.toUtc())} — '
    'face re-scans are allowed once every ${kFaceRescanCooldown.inDays} days. '
    'Until then, ask your professor to mark your attendance manually '
    '(Request manual attendance in class).';

/// Actionable deploy hint wrapping Firestore permission failures (rules not
/// deployed or a binding conflict) instead of a bare code. Single source of
/// truth for the hint text — [firestore_sync]'s `_rulesError` delegates
/// here, and the enroll pre-claim reuses it for the genuine-rules-problem
/// everywhere. Verbatim — do not reword.
String cloudRulesHint(String op) =>
    'Cloud $op refused by security rules (permission-denied) — deploy them with:\n'
    'firebase deploy --only firestore:rules --project proximity-attendence';

/// True when [message] is a rules-denial deploy hint (see [cloudRulesHint])
/// rather than friendly claim copy. Pure evidence check shared by the
/// enroll pre-claim and the entry gate: a denied install-doc read after a
/// clean own-doc read proves the install holds another Gmail (rules deny
/// cross-org install reads while missing own docs read clean), i.e. an
/// installConflict the transaction could never see.
bool isRulesDenialMessage(String message) {
  final m = message.toLowerCase();
  return m.contains('security rules') && m.contains('permission-denied');
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

// --- Owner-lazy purge result (see CloudSync.purgeExpiredSelfData) ---
//
/// Outcome of the six-month purge: `collection/id` of every doc
/// actually deleted. Empty = nothing eligible (or offline/denied — purge
/// is best-effort and never blocks entry).
class PurgeOutcome {
  final List<String> deleted;
  const PurgeOutcome([this.deleted = const []]);
  bool get purgedAny => deleted.isNotEmpty;
}

// --- App-install identity (folded in from core/device_identity.dart) ---
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
