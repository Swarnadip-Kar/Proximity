// Enrollment flow: Google sign-in → device Ed25519 keypair → on-device
// face enrollment → atomic online claim (one student device per Gmail,
// one Gmail per install; see cloud_sync claim logic).
//
// Identity is the Gmail account itself: display name is imported directly,
// ID number is user-entered (compulsory, unverified). Students type nothing
// in class — attendance auto-attaches the linked identity.
//
// No roster: in-class attendance never consults a server-side key list
// (whoever proves presence over radio lands in the class union); the cloud
// claim only gates WHICH device may enroll as a Gmail.
//
// Face templates never leave the phone, full stop.
// Key seed lives in secure storage; production uses Keystore/StrongBox
// (Android), Secure Enclave (iOS), OS keychain (desktop).
// Face capture: injected [FaceEmbedder]. Production injects the vendored
// EdgeFace-XS TFLite (`EdgeFaceEmbedder`, fail-closed when unloadable);
// [MockFaceEmbedder] drives unit tests only, never the shipped app.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_face/face.dart';
import 'package:proximity_protocol/protocol.dart';

import '../mode.dart';
import 'auth.dart';
import 'cloud_sync.dart';
import 'device_store.dart';
import 'edgeface.dart';
import 'enroll_finalize.dart';

/// Minimum pairwise cosine between enrollment frames: all accepted
/// stills must show the SAME person. Measured 2026-09-05 through the
/// shipped pipeline: same person frontal 0.80, same person head-turned
/// 0.50–0.57, strangers ~0.0. Applies to SLOT MEANS across guided poses
/// (see [captureSlot]): sits below the worst legit cross-pose pairing
/// with margin, far above stranger scores. Never gate near the 0.60
/// match threshold.
const kEnrollConsistencyMin = 0.35;

/// Minimum pairwise cosine WITHIN one guided-pose slot. Same-instruction
/// frames are near-duplicates (~0.95+ frontal, ~0.8+ slight tilt when held
/// still); an intruder frame pairs at ~0.0. Bar 0.70: a 0.65 same-pose
/// pair is a bad frame, never a pass — it drops only that angle for a
/// targeted rescan, others kept. Pose spread lives BETWEEN slots, never
/// within one, so this never punishes turns. Strangers still read ~0.0,
/// so 0.70 keeps full impostor separation with margin.
///
/// Shares its value with the live camera gate ([kEnrollSectionScoreMin],
/// passed as `sectionScoreMin` by the enrollment screen): the camera
/// completes a section on this exact pair score and the controller
/// re-validates it, so the two agree by construction.
const kSlotConsistencyMin = 0.70;

/// Live camera section gate for enrollment (see above): each guided angle
/// completes once its best embedded pair reaches this. Single source of
/// truth — the enrollment screen passes it as `sectionScoreMin` so the
/// camera and the controller share one bar.
const kEnrollSectionScoreMin = 0.70;

/// Cross-pose hold-out floor for the final enrollment check (see
/// [_tryFinalize]): the held-out CENTRE frame vs the mean of the LEFT+RIGHT
/// slot means only (symmetric yaw cancels back toward frontal, so the probe
/// reads frontal-like on any decent capture day).
///
/// 0.50: WITHIN-slot near-duplicates pair high, so the per-angle 0.70 bar
/// ([kSlotConsistencyMin]) is fair; ACROSS poses the same person reads far
/// lower — measured 0.50–0.57 head-turned through this exact pipeline, and
/// the public cross-pose benchmarks agree (EdgeFace-XS: LFW frontal 99.73%
/// vs CPLFW cross-pose ~91.6%). A 0.78 cross-pose read is a GOOD capture
/// day, not a failure. Strangers still read ~0.0, so 0.50 keeps full
/// impostor separation with margin. Top/Bottom join the saved
/// template but stay out of the hold-out mean: pitched embeddings
/// foreshorten under the similarity warp and would drag any 5-way mean
/// down past any pass — they are validated instead by their own 0.70
/// within-slot pair plus the 0.35 global pairwise floor below.
const kEnrollHoldoutMin = 0.50;

/// Guided enrollment poses, in scan order: centre + slight left/right +
/// slight top/bottom. Yaw AND slight pitch — but SLIGHT (10–20°): the
/// holder's head stays near-frontal the whole time, the phone stays at eye
/// level, each angle needs only a small readable turn. Pitched faces
/// inherently score lower than frontal (pitch >30° degrades embeddings),
/// so the gates ask for the SMALLEST tilt that still leaves a dead-centre
/// stare behind (see the pitch gates in face_detect.dart) — never an
/// exaggerated pose. Marking happens near-frontal anyway; the side/top/
/// bottom slots exist for template diversity (pose-aware multi-stage
/// enrollment lifts accuracy 78%→96% in the literature), not as an
/// obstacle course. Every slot clears independently at a 0.70 within-slot
/// pair; the cross-pose agreement floor is [kEnrollConsistencyMin].
const enrollSlotNames = ['Centre', 'Left', 'Right', 'Top', 'Bottom'];
const enrollSlotHints = [
  'Look straight at the camera',
  'Turn your head slightly left',
  'Turn your head slightly right',
  'Tilt your chin slightly up',
  'Tilt your chin slightly down',
];

/// First incomplete slot index (scan resume point), or -1 when all are
/// done. Pure so the resume mapping stays testable.
int firstMissingSlot(List<bool> done) {
  for (var i = 0; i < done.length; i++) {
    if (!done[i]) return i;
  }
  return -1;
}

/// All incomplete slot indices, in order. Resume scans ONLY these — never
/// the contiguous tail from [firstMissingSlot] (which re-captured already
/// good angles when a middle slot was dropped as odd-one-out, wiping
/// progress and frustrating the holder).
List<int> missingSlots(List<bool> done) => [
      for (var i = 0; i < done.length; i++)
        if (!done[i]) i
    ];

/// Chunk a flat section-ordered frame list into pairs, dropping a
/// trailing single (partial sections never travel). Pure, tested.
List<List<List<int>>> slotPairs(List<List<int>> frames) {
  final out = <List<List<int>>>[];
  for (var i = 0; i + 1 < frames.length; i += 2) {
    out.add([frames[i], frames[i + 1]]);
  }
  return out;
}

/// Scan button copy: full run vs resume remainder.
String scanButtonLabel(List<bool> done) {
  final missing = enrollSlotNames.length -
      done.where((d) => d).length.clamp(0, enrollSlotNames.length);
  if (missing <= 0 || missing >= enrollSlotNames.length) {
    return 'Scan all angles';
  }
  return 'Scan remaining angle${missing > 1 ? 's' : ''} ($missing left)';
}

enum EnrollPhase {
  signedOut,
  signedIn,
  keyReady,
  faceDone,
  uploaded,
  error,
}

class EnrollmentState {
  final EnrollPhase phase;
  final SignedAccount? account;
  final String roll;
  final String pkHex;
  final double faceScore;
  final String message;
  final bool restored; // key came from this device's secure storage
  /// Guided-pose slots completed ([enrollSlotNames] order). Progress
  /// survives retried slots: only the failing slot is ever cleared.
  final List<bool> angleSlots;
  const EnrollmentState({
    this.phase = EnrollPhase.signedOut,
    this.account,
    this.roll = '',
    this.pkHex = '',
    this.faceScore = 0,
    this.message = '',
    this.restored = false,
    this.angleSlots = const [false, false, false, false, false],
  });

  EnrollmentState copyWith({
    EnrollPhase? phase,
    SignedAccount? account,
    String? roll,
    String? pkHex,
    double? faceScore,
    String? message,
    bool? restored,
    List<bool>? angleSlots,
  }) =>
      EnrollmentState(
        phase: phase ?? this.phase,
        account: account ?? this.account,
        roll: roll ?? this.roll,
        pkHex: pkHex ?? this.pkHex,
        faceScore: faceScore ?? this.faceScore,
        message: message ?? this.message,
        restored: restored ?? this.restored,
        angleSlots: angleSlots ?? this.angleSlots,
      );
}

/// Canonical template hash: float64LE bytes → SHA-256 hex. Uploaded only.
String faceTemplateHash(List<double> template) {
  final b = ByteData(template.length * 8);
  for (var i = 0; i < template.length; i++) {
    b.setFloat64(i * 8, template[i], Endian.little);
  }
  return hexEncode(ProxCrypto.sha256Sync(b.buffer.asUint8List()));
}

/// Cross-platform install label for the device binding (no hardware IDs —
/// the (pkHex, installId) pair is the identity; this is display/debug only).
String _platformName() => defaultTargetPlatform.name;

/// Mean embedding direction of several enrollment frames, L2-normalized.
/// All vectors must share a length; single-frame input returns it unchanged.
/// Pure math lives in enroll_finalize.dart ([averageUnit]); this wrapper
/// keeps existing call sites identical.
List<double> _averageUnit(List<List<double>> vectors) =>
    averageUnit(vectors);

class EnrollmentController extends StateNotifier<EnrollmentState> {
  final AuthService _auth;
  final DeviceStore _store;
  final FaceEmbedder _embedder;
  // Cloud device binding (null in unit tests → local-only behavior).
  final CloudSync? _cloud;

  /// The face embedder (shared with the live scan for per-section scores).
  FaceEmbedder get embedder => _embedder;

  ed.KeyPair? _keys;
  List<double>? _template;
  String? _restoredRoll;
  // Per-slot mean embeddings + one representative frame each. Slots fill
  // in any order and rescan independently; only the failing slot is ever
  // cleared, so progress is never lost to a single bad angle.
  final List<List<double>?> _slotMeans =
      List.filled(enrollSlotNames.length, null);
  final List<List<int>?> _slotProbeFrames =
      List.filled(enrollSlotNames.length, null);

  EnrollmentController({
    required AuthService auth,
    required DeviceStore store,
    required FaceEmbedder embedder,
    SignedAccount? preseed,
    CloudSync? cloud,
  })  : _auth = auth,
        _store = store,
        _embedder = embedder,
        _cloud = cloud,
        super(EnrollmentState(
            phase: preseed == null
                ? EnrollPhase.signedOut
                : EnrollPhase.signedIn,
            account: preseed));

  /// Background account pickup for the enrollment page (NO sign-in tap):
  /// adopts the persisted Firebase session when one exists — the common
  /// case, since students sign in on the landing BEFORE reaching here —
  /// and best-effort refreshes the token when online, proving live
  /// account status at start. Offline (or a stale session) the persisted
  /// account still stands for key+face; Save re-verifies online. Fresh
  /// installs with no session keep the manual sign-in button: the cloud
  /// claim binds to the Google identity, so it cannot run unsigned.
  Future<void> pickUpAccount() async {
    if (state.account != null) return;
    SignedAccount? acct;
    try {
      acct = _auth.current;
    } catch (_) {
      return;
    }
    if (acct == null) return;
    state = state.copyWith(
        phase: EnrollPhase.signedIn, account: acct, message: '');
    try {
      await _auth.getIdToken().timeout(const Duration(seconds: 6));
    } catch (_) {
      // Offline: the persisted account still stands; Save re-checks.
    }
    await _tryRestore(acct);
  }

  /// Step 1 (manual fallback): Google sign-in (persists via Firebase
  /// Auth), then same-device restore when this phone already holds a key
  /// for the account. Only needed on fresh installs with no session —
  /// [pickUpAccount] covers everyone else silently.
  Future<void> signIn() async {
    try {
      final acct = await _auth.signInWithGoogle();
      if (acct == null) {
        state = state.copyWith(
            phase: EnrollPhase.signedOut, message: 'Sign-in cancelled.');
        return;
      }
      state = state.copyWith(
          phase: EnrollPhase.signedIn, account: acct, message: '');
      await _tryRestore(acct);
    } catch (e) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Sign-in failed: $e');
    }
  }

  Future<void> _tryRestore(SignedAccount acct) async {
    final email = acct.email.toLowerCase();
    final stored = await _store.readEnrollment();
    if (stored == null || stored.email.toLowerCase() != email) return;
    try {
      final seed = hexDecode(stored.seedHex);
      final sk = ed.newKeyFromSeed(seed);
      final pk = ed.public(sk);
      _keys = ed.KeyPair(sk, pk);
      _restoredRoll = stored.roll;
      // Stale face pipeline (e.g. pre-alignfix templates): the key is still
      // valid, but the template is incomparable garbage — keep the key,
      // drop the template, land on the key step for a fresh face capture.
      if (stored.modelVer != kFacePipelineVer) {
        state = state.copyWith(
          phase: EnrollPhase.keyReady,
          pkHex: stored.pkHex,
          roll: stored.roll,
          restored: true,
          faceScore: 0,
          message: 'Face recognition was improved — scan your face again.',
        );
        return;
      }
      // Local-only restore: a valid key + current-pipeline template links
      // immediately — no server round-trip needed to keep attending.
      // The score is NOT a fresh match (nothing was scanned just now), so
      // it stays 0 with an honest message instead of a synthetic 1.00.
      _template = stored.template;
      state = state.copyWith(
        phase: EnrollPhase.uploaded,
        pkHex: stored.pkHex,
        roll: stored.roll,
        restored: true,
        faceScore: 0,
        message:
            'Key restored from this device — no fresh match yet. Scan again to verify.',
      );
    } catch (_) {
      // Corrupt store entry: ignore, proceed as fresh enrollment.
    }
  }

  /// Identity for the linked banner. Valid once uploaded/restored.
  LinkedIdentity? get currentIdentity {
    final acct = state.account;
    if (acct == null || state.phase != EnrollPhase.uploaded) return null;
    final roll = state.roll.isNotEmpty ? state.roll : (_restoredRoll ?? '');
    return LinkedIdentity(
      name: acct.displayName,
      gmail: acct.email.toLowerCase(),
      roll: roll,
      org: acct.org,
    );
  }

  /// ID number (compulsory, unverified). Stored as-is.
  void setRoll(String roll) {
    state = state.copyWith(roll: roll.trim());
  }

  /// Step 2: generate Ed25519 keypair. A fresh key simply replaces any
  /// previous one on this device; cross-device duplicates are refused by
  /// the online claim at Save (one device per Gmail).
  Future<void> generateKey() async {
    final acct = state.account;
    if (acct == null) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Sign in first.');
      return;
    }
    try {
      final kp = ProxCrypto.generateEdKeypair();
      final pkHex =
          hexEncode(Uint8List.fromList(kp.publicKey.bytes.sublist(0, 32)));
      _keys = kp;
      _restoredRoll = null;
      state = state.copyWith(
          phase: EnrollPhase.keyReady, pkHex: pkHex, restored: false);
    } catch (e) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Key generation failed: $e');
    }
  }

  /// Step 3: slot-wise on-device face enrollment (template stays on phone).
  /// Each slot captures one guided pose ([enrollSlotNames]); the screen
  /// pushes one scan session per slot and retries ONLY the failing slot,
  /// so a bad angle never restarts the whole enrollment. The template is
  /// the normalized mean of the slot means and is stored ONLY when the
  /// cross-pose check + self-check pass — a failed capture leaves no
  /// template behind, so a bad scan can never advance to upload
  /// (fail-closed with faceScore 0).
  Future<void> captureSlot(int slot, List<List<int>> frames) async {
    if (slot < 0 || slot >= enrollSlotNames.length || frames.isEmpty) {
      return;
    }
    if (state.phase != EnrollPhase.keyReady &&
        state.phase != EnrollPhase.error) {
      // Wrong step (e.g. Scan tapped before key): never silently drop —
      // surface the prerequisite so the holder knows what to do.
      state = state.copyWith(
          phase: EnrollPhase.error,
          message: state.account == null
              ? 'Sign in first.'
              : 'Generate the device key first, then scan.');
      return;
    }
    try {
      final vectors = <List<double>>[];
      for (final f in frames) {
        vectors.add(await _embedder.embed(f));
      }
      // Within-slot agreement: one guided pose → near-identical frames.
      // A mixed slot (intruder frame) is dropped alone; other slots keep
      // their progress.
      if (vectors.length > 1 &&
          _minPairwise(vectors) < kSlotConsistencyMin) {
        _slotMeans[slot] = null;
        _slotProbeFrames[slot] = null;
        _emitSlots(
            message:
                '${enrollSlotNames[slot]} angle had mixed faces — rescan it alone.${_pitchHint([slot])}');
        return;
      }
      _slotMeans[slot] = _averageUnit(vectors);
      _slotProbeFrames[slot] = frames.first;
      await _tryFinalize();
    } catch (e) {
      _slotMeans[slot] = null;
      _slotProbeFrames[slot] = null;
      state = state.copyWith(
          phase: EnrollPhase.error,
          faceScore: 0,
          message: 'Face capture failed: $e');
    }
  }

  /// Lowest pairwise cosine in [vectors] (1.0 for a single vector).
  /// Pure math lives in enroll_finalize.dart ([minPairwise]).
  double _minPairwise(List<List<double>> vectors) => minPairwise(vectors);

  void _emitSlots({required String message}) {
    state = state.copyWith(
      phase: EnrollPhase.keyReady,
      angleSlots: [for (final m in _slotMeans) m != null],
      faceScore: 0,
      message: message,
    );
  }

  void _clearSlots() {
    for (var i = 0; i < _slotMeans.length; i++) {
      _slotMeans[i] = null;
      _slotProbeFrames[i] = null;
    }
  }

  /// Extra coaching when a pitch slot (Top/Bottom) is dropped: the usual
  /// failure mode is OVER-tilting — a bigger tilt degrades the embedding
  /// further, which drops the slot again, so the holder tilts even more
  /// next round. Break the vicious cycle by asking for LESS tilt.
  static String _pitchHint(Iterable<int> dropped) =>
      dropped.any((k) => k == 3 || k == 4)
          ? ' For Top/Bottom, tilt LESS — barely move your chin and keep the phone at eye level.'
          : '';

  /// Runs whenever a slot lands and all slots are present: cross-pose
  /// agreement over slot means, then a self-check on the frontal frame.
  /// A disagreeing angle is dropped ALONE for a targeted rescan —
  /// completed angles are never cleared wholesale (a full clear after the
  /// last angle scanned is what forced whole re-enrollments). At most the
  /// odd ones out — or, with no agreeing pair at all, the single worst
  /// slot — go per round, so progress is monotonic: rescan one angle,
  /// keep the others. The key is always kept.
  Future<void> _tryFinalize() async {
    if (_slotMeans.any((m) => m == null)) {
      _emitSlots(message: '');
      return;
    }
    final means = [for (final m in _slotMeans) m!];
    // Best agreeing pair; every slot is then judged against it.
    // Pure math lives in enroll_finalize.dart ([bestAgreeingPair]).
    final bestPair = bestAgreeingPair(means);
    final bi = bestPair.bi, bj = bestPair.bj;
    final best = bestPair.best;
    // Odd-ones-out vs the best pair at the single agreement floor: a
    // stranger reads ~0.0 either way, so no per-slot bar is needed now
    // that every slot is yaw (see enrollSlotNames).
    // Pure math lives in enroll_finalize.dart ([oddOnesOut]).
    final odd = oddOnesOut(means, bi, bj, kEnrollConsistencyMin);
    if (best >= kEnrollConsistencyMin && odd.isNotEmpty) {
      // Odd slots out (e.g. a friend did one angle): drop them alone.
      for (final k in odd) {
        _slotMeans[k] = null;
        _slotProbeFrames[k] = null;
      }
      _emitSlots(
          message:
              '${odd.map((k) => enrollSlotNames[k]).join(', ')} angle${odd.length > 1 ? 's' : ''} didn\'t match the others — rescan ${odd.length > 1 ? 'them' : 'it'} alone.${_pitchHint(odd)}');
      return;
    }
    if (best < kEnrollConsistencyMin) {
      // No agreeing pair at all: drop ONLY the worst slot (lowest total
      // agreement with the rest), never the whole set.
      _dropWorstSlot(means,
          'No two angles agreed — rescan the weakest one alone.');
      return;
    }
    try {
      // Hold-out validation: enroll the mean of the LEFT+RIGHT slots, then
      // verify the held-out centre frame against it. Symmetric yaw cancels
      // in the mean (left+right average back toward frontal), so the probe
      // reads frontal-like on any decent capture day. Top/Bottom stay OUT
      // of this mean (pitched foreshortening would drag it down past any
      // pass) — they join the saved template below and are validated by
      // their own 0.70 within-slot pair + the 0.35 global floor above.
      // Floor is kEnrollHoldoutMin (0.50): cross-pose same-person reads
      // 0.50–0.57 measured, strangers ~0.0 — a high bar here looped forever.
      const holdOut = 0;
      // Pure composition lives in enroll_finalize.dart ([holdoutProbe]).
      final probe = holdoutProbe(means);
      final session = FaceSession(
          embedder: _embedder,
          gate: FaceGate(threshold: kEnrollHoldoutMin));
      session.enroll(probe);
      final front = _slotProbeFrames[holdOut]!;
      final res = await session.verify(front,
          challenge: Uint8List.fromList(const [0, 0, 0, 0, 0, 0, 0, 0]),
          now: DateTime.now().toUtc());
      if (res.decision == FaceDecision.pass && res.score >= kEnrollHoldoutMin) {
        // Persist the mean of ALL FIVE slots (best template); the hold-out
        // mean above was validation-only.
        // Pure composition lives in enroll_finalize.dart ([finalizeTemplate]).
        _template = finalizeTemplate(means);
        state = state.copyWith(
            phase: EnrollPhase.faceDone,
            faceScore: res.score,
            // The landing slot never re-emitted progress (only the
            // incomplete branch does), so the bar froze under the
            // success copy — refresh it here.
            angleSlots: [for (final m in _slotMeans) m != null]);
      } else {
        // Hold-out failed: drop ONLY the worst slot (badly lit angle
        // dragging the mean down), never the set.
        _template = null;
        _dropWorstSlot(means,
            'didn\'t match clearly — rescan it alone in good light, holding still.');
      }
    } catch (e) {
      // Systemic failure (embedder threw): keep the slots, report the
      // error — the holder retries from the key step with progress intact.
      _template = null;
      state = state.copyWith(
          phase: EnrollPhase.error,
          faceScore: 0,
          message: 'Face capture failed: $e');
    }
  }

  /// Drops the single slot with the lowest total agreement with the rest
  /// (least sum of pairwise cosines) and asks for it alone by name.
  /// Monotonic-progress primitive: every finalize failure funnels here (or
  /// drops explicit odd-ones-out), so a bad angle costs one rescan, never
  /// the other four.
  void _dropWorstSlot(List<List<double>> means, String tailCopy) {
    // Pure math lives in enroll_finalize.dart ([worstSlotIndex]).
    final worst = worstSlotIndex(means);
    _slotMeans[worst] = null;
    _slotProbeFrames[worst] = null;
    _emitSlots(
        message:
            '${enrollSlotNames[worst]} angle $tailCopy${_pitchHint([worst])}');
  }

  /// Step 4: persist key + identity on this device AND claim the Gmail's
  /// single student-device slot online (one enrolled student device per
  /// Gmail, one Gmail per app install — see cloud_sync claim logic).
  /// Fail-closed: requires ALL five angle slots plus a validated template —
  /// a single scanned section can never save (the Save button is disabled
  /// until then, and this validates again for programmatic callers).
  /// Online-only: the claim needs internet, which stops students
  /// from enrolling anywhere offline for false attendance. A Gmail held by
  /// a different device refuses here (weekly cooldown with an exact
  /// re-enroll date; manual attendance covers the gap), as does an install
  /// enrolled as another Gmail. Racing devices lose atomically: exactly
  /// one claim wins.
  Future<LinkedIdentity?> upload() async {
    final acct = state.account;
    final kp = _keys;
    final template = _template;
    // Slots first so a partial scan reports angles-left (specific), not a
    // generic "complete all steps".
    if (_slotMeans.any((m) => m == null)) {
      final missing = enrollSlotNames.length -
          _slotMeans.where((m) => m != null).length;
      state = state.copyWith(
          phase: EnrollPhase.error,
          message:
              'Scan all 5 face angles first ($missing left) — a partial scan cannot save.');
      return null;
    }
    if (acct == null || kp == null || template == null) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Complete all steps first.');
      return null;
    }
    if (state.roll.isEmpty &&
        (_restoredRoll == null || _restoredRoll!.isEmpty)) {
      state = state.copyWith(
          phase: EnrollPhase.error,
          message: 'Enter your ID number to continue.');
      return null;
    }
    try {
      final email = acct.email.toLowerCase();
      final roll =
          state.roll.isNotEmpty ? state.roll : _restoredRoll ?? '';
      final name = acct.displayName;
      final org = acct.org.isNotEmpty
          ? acct.org
          : (() {
              final e = email.trim().toLowerCase();
              final at = e.lastIndexOf('@');
              if (at <= 0 || at == e.length - 1) return '';
              var domain = e.substring(at + 1).trim();
              if (domain == 'googlemail.com') return 'gmail.com';
              return domain;
            })();
      final pk32 = Uint8List.fromList(kp.publicKey.bytes.sublist(0, 32));
      final pkHex = hexEncode(pk32);
      // Online device claim first (atomic): a different bound device, or
      // an install enrolled as another Gmail, refuses before anything is
      // stored locally (false-attendance enrollments stop here).
      final cloud = _cloud;
      if (cloud != null && cloud.available) {
        var online = false;
        try {
          online = await cloud.isOnline().timeout(const Duration(seconds: 8));
        } catch (_) {
          online = false;
        }
        if (!online) {
          state = state.copyWith(
              phase: EnrollPhase.error,
              message:
                  'Student enrollment needs internet (one enrolled device per Gmail is checked online). Connect and tap Save again — your 5 angles are kept.');
          return null;
        }
        final installId = await getOrCreateInstallId(_store);
        try {
          final outcome = await cloud.claimStudentDevice(
              doc: StudentDeviceDoc(
                  email: email,
                  uid: acct.uid,
                  pkHex: pkHex,
                  name: name,
                  roll: roll,
                  modelVer: kFacePipelineVer,
                  installId: installId,
                  platform: _platformName(),
                  org: org),
              installId: installId);
          BleLog.log('SYNC',
              'device claim ok (${outcome.isFirst ? 'first bind' : outcome.isMove ? 'device move' : 'same device'})');
        } on StateError catch (e) {
          BleLog.log('SYNC', 'device claim refused (see screen message)');
          state = state.copyWith(
              phase: EnrollPhase.error, message: e.message);
          return null;
        } catch (e) {
          state = state.copyWith(
              phase: EnrollPhase.error, message: 'Save failed: $e');
          return null;
        }
      }
      await _store.writeEnrollment(StoredEnrollment(
        email: email,
        name: name,
        roll: roll,
        seedHex: hexEncode(ed.seed(kp.privateKey)),
        pkHex: pkHex,
        templateCsv: StoredEnrollment.csvOf(template),
        enrolledAt: DateTime.now().toUtc(),
        modelVer: kFacePipelineVer,
        org: org,
      ));
      state = state.copyWith(phase: EnrollPhase.uploaded);
      return LinkedIdentity(name: name, gmail: email, roll: roll, org: org);
    } catch (e) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Save failed: $e');
      return null;
    }
  }

  /// Explicit re-scan (restored users, changed appearance): keeps the
  /// device key, clears slot progress AND the in-memory template. The
  /// stored template on disk is untouched (attendance still works via the
  /// linked identity until the new capture validates), but this screen
  /// cannot save the OLD template after a single new angle — Save stays
  /// blocked until all five new angles validate.
  void restartFace() {
    _clearSlots();
    _template = null;
    state = state.copyWith(
        phase: EnrollPhase.keyReady,
        angleSlots: const [false, false, false, false, false],
        faceScore: 0,
        message: '');
  }

  /// Retry from the last good step (error is non-destructive). Invariant:
  /// a failed capture stores no template (see [captureSlot]), so this
  /// lands back on the key step — never on faceDone with score 0. Slot
  /// progress is kept: only explicitly failed slots are cleared.
  void dismissError() {
    final back = _keys != null
        ? (_template != null ? EnrollPhase.faceDone : EnrollPhase.keyReady)
        : (state.account != null ? EnrollPhase.signedIn : EnrollPhase.signedOut);
    state = state.copyWith(phase: back, message: '');
  }
}

final enrollmentControllerProvider =
    StateNotifierProvider<EnrollmentController, EnrollmentState>((ref) {
  throw UnimplementedError('Override in main / tests');
});
