// Enrollment flow: Google sign-in → device Ed25519 keypair (SKey, sealed
// to the HW device key) → on-device face enrollment (plugin) → atomic
// online claim (one student device per Gmail, one Gmail per install; see
// cloud_sync claim logic).
//
// Identity is the Gmail account itself: display name is imported directly,
// ID number is user-entered (compulsory, unverified). Students type nothing
// in class — attendance auto-attaches the linked identity.
//
// No roster: in-class attendance never consults a server-side key list
// (whoever proves presence over radio lands in the class union); the cloud
// claim only gates WHICH device may enroll as a Gmail.
//
// Face data never leaves the device, except student→professor-phone
// vectors over the local network during the live session: the plugin owns
// its on-device store keyed by faceId=sha256(gmail+installId) — never the
// raw Gmail — and, during marking, the student's proof carries a compact
// face vector to the professor's phone over the existing local HTTPS
// channel (the professor already sees every face physically; nothing
// reaches the cloud, ever). The app keeps only {faceId, verifierVer,
// enrolledAt}; the SKey seed is DKey-sealed (ciphertext only at rest).
//
// Key seed lives in secure storage; production uses Keystore/StrongBox→TEE
// (Android) / Secure Enclave (iOS) via HwDeviceKey on mobile only.
// Desktop/web are records-only fail-closed (UnavailableDeviceKey — no key,
// no seal, every op throws before signing).
// Face enrollment: injected [FaceVerifier]. Production injects
// [PluginFaceVerifier] (mobile-only); [FakeFaceVerifier] drives unit
// tests only, never the shipped app. Desktop/web get
// [UnavailableFaceVerifier] and fail closed before anything signs.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';

import '../features/device_identity/hw_device_key.dart';
import '../features/entry/entry_flow.dart' show entryRequireEnrollIntegrity;
import '../features/face_identity/device_key.dart';
import '../features/face_identity/face_verifier.dart';
import '../features/face_identity/liveness_gate.dart'
    show
        HeuristicLivenessGate,
        LivenessAction,
        LivenessGate,
        LivenessResult,
        kLivenessVer;
import '../features/face_identity/pose_gate.dart'
    show EnrollPoseWindows, PoseGate;
import '../mode.dart';
import 'auth.dart';
import 'attestation_self_check.dart';
import 'cloud_sync.dart';
import 'device_store.dart';
import 'platformx.dart';
import 'security/revocation_cache.dart';
import 'sync/device_hardware_id.dart';

/// Enroll side-slot liveness bar (app-local policy, NOT a ticket break).
/// The protocol Tl ([kLivenessThreshold] = 0.85) stays the decider for the
/// frontal centre still — the documented vitality decider, re-checked at
/// every marking — and for all marking proofs. The four diversity slots
/// (left/right/up/down) exist for template diversity + sustained presence
/// across the walked order; tilted captures systematically score lower
/// (field 2026-09-13 genuine: centre 0.90, left 0.95, right 0.89, up 0.79 —
/// foreshortened boxes pull in more background at the 2.7x crop), so gating
/// all five at 0.85 fails ~1 genuine enrollment in 4 on vitality alone
/// (joint 5/5 pass ≈ 0.75^5). 0.70 keeps anti-spoof margin on every measured
/// probe (moire-replay 0.026, recapture-blur 0.243, uniform ≤0.31 — the
/// uniform-64 0.76 outlier cannot reach this gate without a face: the Euler
/// pose check above aborts faceless stills first) while passing the field
/// genuine tilted range. Changing this constant breaks nothing on the wire
/// (the enroll claim carries only the pipeline tag [kLivenessVer], never a
/// score); lowering [kLivenessThreshold] itself would be a ticket break
/// (ver bump + min_version floor, never silent).
const double kEnrollSideLivenessThreshold = 0.70;

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
  const EnrollmentState({
    this.phase = EnrollPhase.signedOut,
    this.account,
    this.roll = '',
    this.pkHex = '',
    this.faceScore = 0,
    this.message = '',
    this.restored = false,
  });

  EnrollmentState copyWith({
    EnrollPhase? phase,
    SignedAccount? account,
    String? roll,
    String? pkHex,
    double? faceScore,
    String? message,
    bool? restored,
  }) =>
      EnrollmentState(
        phase: phase ?? this.phase,
        account: account ?? this.account,
        roll: roll ?? this.roll,
        pkHex: pkHex ?? this.pkHex,
        faceScore: faceScore ?? this.faceScore,
        message: message ?? this.message,
        restored: restored ?? this.restored,
      );
}

/// Cross-platform install label for the device binding (no hardware IDs —
// the (pkHex, installId) pair is the identity; this is display/debug only).
String _platformName() => defaultTargetPlatform.name;

class EnrollmentController extends StateNotifier<EnrollmentState> {
  final AuthService _auth;
  final DeviceStore _store;
  final FaceVerifier _verifier;
  final DeviceKey _deviceKey;
  final LivenessGate _liveness;
  // Face-scoring re-check gate (C4): per-slot Euler windows + face presence
  // on ALL 5 stills at enroll time (defense-in-depth over the capture-time
  // PoseGate classify-fill). Null in older call sites / unit tests (capture
  // already gated there) — liveness + plugin per-slot checks still run.
  final PoseGate? _poseGate;
  // Cloud device binding (null in unit tests → local-only behavior).
  final CloudSync? _cloud;
  // NONE-tier law: software device keys can NEVER enroll, in any build
  // mode (the debug allowance was removed 2026-09-13 — debug enrolls like
  // release, against real secure hardware; unit tests use FakeDeviceKey at
  // FULL tier). A NONE tier at generate/upload refuses with
  // Software-no-enroll, and NONE proofs never confirm at marking
  // (`device-none-requires-approval` → manual path).

  /// The face verifier (shared with the live check for the ticket stamp).
  FaceVerifier get verifier => _verifier;

  /// The HW device key (DKey) this enrollment seals to.
  DeviceKey get deviceKey => _deviceKey;

  ed.KeyPair? _keys;
  String? _faceId;
  String? _restoredRoll;
  // Latest slot-naming refusal in enrollFace (pose/liveness FAIL names its
  // slot for the capture session's single-slot recapture). Null when the
  // last run did not refuse a slot. Cleared on each new scoring run + on
  // faceDone; the gallery stays untouched on every refusal either way.
  String? _lastFailedSlot;

  /// Latest refused slot, if any (see [_lastFailedSlot]).
  String? get lastFailedSlot => _lastFailedSlot;

  /// Slot-naming refusal (see [_lastFailedSlot]): clears the face binding,
  /// records the slot, surfaces the message. Callers return before any
  /// gallery write, so a refused still is never stored.
  void _slotFail(String slot, String message) {
    _faceId = null;
    _lastFailedSlot = slot;
    state = state.copyWith(
        phase: EnrollPhase.error, faceScore: 0, message: message);
  }

  EnrollmentController({
    required AuthService auth,
    required DeviceStore store,
    required FaceVerifier verifier,
    required DeviceKey deviceKey,
    SignedAccount? preseed,
    CloudSync? cloud,
    LivenessGate? livenessGate,
    PoseGate? poseGate,
  })  : _auth = auth,
        _store = store,
        _verifier = verifier,
        _deviceKey = deviceKey,
        // Platform gate by default (native MiniFASNet scorer, web
        // fail-closed stub — same copy idiom as RealStudentDriver) so the
        // claimed livenessVer is MEASURED on every enroll, never asserted.
        // Tests inject FakeLivenessGate. main.dart needs no new override.
        _liveness = livenessGate ?? HeuristicLivenessGate(),
        _poseGate = poseGate,
        _cloud = cloud,
        super(EnrollmentState(
            phase: preseed == null
                ? EnrollPhase.signedOut
                : EnrollPhase.signedIn,
            account: preseed));

  /// Reconciles the draft with the CURRENT signed-in account (identity ==
  /// token — the join-gate/org design binds claim + org to the live
  /// session, never to a cached copy). Same email is a no-op preserving
  /// in-progress key/face/roll; a changed email (or sign-out) wipes the
  /// whole draft (keys, face, roll, restore) and adopts the current
  /// account fresh, so the card/claim/org can never ride a stale preseed.
  /// Call on every enroll entry + after sign-out/switch.
  Future<void> refreshFromAuth() async {
    SignedAccount? current;
    try {
      current = _auth.current;
    } catch (_) {
      return;
    }
    final prev = state.account?.email.toLowerCase() ?? '';
    final next = current?.email.toLowerCase() ?? '';
    if (prev == next) {
      // Same session: adopt only when the draft holds nothing yet (a
      // preseed-less controller opened straight onto the page).
      if (current != null && state.account == null) {
        state = state.copyWith(
            phase: EnrollPhase.signedIn, account: current, message: '');
        await _tryRestore(current);
        return;
      }
      // Same account but no usable key (e.g. a locked restore that only
      // recovered pkHex): retry the restore so a later Save does not hit
      // the key gate with a key this device holds. No-op when keys are
      // loaded or nothing is stored.
      if (current != null && _keys == null) {
        await _tryRestore(current);
      }
      return;
    }
    _keys = null;
    _faceId = null;
    _restoredRoll = null;
    if (current == null) {
      state = const EnrollmentState(phase: EnrollPhase.signedOut);
      return;
    }
    state = EnrollmentState(phase: EnrollPhase.signedIn, account: current);
    try {
      await _auth.getIdToken().timeout(const Duration(seconds: 6));
    } catch (_) {
      // Offline: the persisted account still stands; Save re-checks.
    }
    await _tryRestore(current);
  }

  /// Background account pickup for the enrollment page (NO sign-in tap):
  /// adopts the persisted Firebase session when one exists — the common
  /// case, since students sign in on the landing BEFORE reaching here —
  /// and best-effort refreshes the token when online, proving live
  /// account status at start. Reconciles (see [refreshFromAuth]): a stale
  /// preseed never blocks the current account. Fresh installs with no
  /// session keep the manual sign-in button: the cloud claim binds to the
  /// Google identity, so it cannot run unsigned.
  Future<void> pickUpAccount() => refreshFromAuth();

  /// Step 1 (manual fallback): Google sign-in (persists via Firebase
  /// Auth), then same-device restore when this phone already holds a key
  /// for the account. Only needed on fresh installs with no session —
  /// [pickUpAccount] covers everyone else silently. A different email
  /// than the draft wipes it first (same rule as [refreshFromAuth]).
  Future<void> signIn() async {
    try {
      final acct = await _auth.signInWithGoogle();
      if (acct == null) {
        state = state.copyWith(
            phase: EnrollPhase.signedOut, message: 'Sign-in cancelled.');
        return;
      }
      if (acct.email.toLowerCase() !=
          (state.account?.email.toLowerCase() ?? '')) {
        _keys = null;
        _faceId = null;
        _restoredRoll = null;
        state = EnrollmentState(phase: EnrollPhase.signedIn, account: acct);
      } else {
        state = state.copyWith(
            phase: EnrollPhase.signedIn, account: acct, message: '');
      }
      await _tryRestore(acct);
    } catch (e) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Sign-in failed: $e');
    }
  }

  /// Identity==token gate for the binding points (faceId + claim + org
  /// all derive from [state.account]): refuses when the Firebase session
  /// moved under an opened draft, adopting the current account fresh so a
  /// stale-account claim can never file. Returns the live account when it
  /// matches the draft, null after refusing (fail-closed).
  ///
  /// Mismatch is an ATOMIC resync (deliberate, behavior B): the fresh
  /// [EnrollmentState] adopts `current` AND resets roll/pkHex/face/keys in
  /// the same op (same wipe as [refreshFromAuth]), so the draft never sits
  /// half-migrated (new account + old roll/key). The freeze-until-refresh
  /// alternative was rejected: leaving the stale account visible after
  /// detection invites a stale claim on retry, while the resync forces a
  /// restart-as-new-account.
  SignedAccount? _requireLiveAccount() {
    SignedAccount? current;
    try {
      current = _auth.current;
    } catch (_) {
      return state.account;
    }
    final prev = state.account?.email.toLowerCase() ?? '';
    final next = current?.email.toLowerCase() ?? '';
    if (prev == next) return state.account;
    _keys = null;
    _faceId = null;
    _restoredRoll = null;
    if (current == null) {
      state = const EnrollmentState(
          phase: EnrollPhase.error,
          message: 'Signed out — sign in again to enroll this device.');
    } else {
      state = EnrollmentState(
          phase: EnrollPhase.error,
          account: current,
          message: 'Signed-in account changed to ${current.email} — '
              'restart enrollment as the new account '
              '(previous progress was cleared).');
    }
    return null;
  }

  Future<void> _tryRestore(SignedAccount acct) async {
    final email = acct.email.toLowerCase();
    final stored = await _store.readEnrollment();
    if (stored == null || stored.email.toLowerCase() != email) return;
    try {
      // Sealed path (production): unwrap needs THIS device's DKey — a
      // backup-restore clone carrying ciphertext fails here with
      // 'restore detected — re-enroll' and must re-enroll, never match.
      // Sealed-only (security §2): unwrap needs THIS device's HW DKey — a
      // backup-restore clone carrying ciphertext fails here with
      // 'restore detected — re-enroll' and must re-enroll, never match.
      // Unsealed docs (sealedKeyHex empty) never restore — the key
      // step re-runs on secure hardware (re-enroll via the MoveIntent
      // fast path; no silent downgrade).
      if (stored.sealedKeyHex.isEmpty) {
        BleLog.log('SEC',
            'enroll restore: unsealed legacy doc — re-enroll on hardware');
        return;
      }
      ed.KeyPair keys;
      try {
        await _deviceKey.ensure();
      } catch (e) {
        // Records-only device holding a phone-bound enrollment: the key
        // stays locked; the holder continues on their phone. Logged:
        // pkHex is recovered but `_keys` stays null, so a later Save
        // without a retrying refresh would hit the key gate.
        BleLog.log('SEC',
            'enroll restore: DKey unavailable, key locked (pk known)');
        state = state.copyWith(
          phase: EnrollPhase.signedIn,
          pkHex: stored.pkHex,
          roll: stored.roll,
          restored: false,
          faceScore: 0,
          message:
              'This enrollment is bound to your phone — continue enrollment there.',
        );
        return;
      }
      try {
        // AAD-only open (full-fresh): envelopes are AAD-bound
        // (email/installId/pkS/pkD); legacy pre-M7 envelopes fail closed
        // here as restore-detected (re-enroll). Non-HW keys keep the
        // empty-AAD open for tests only.
        final sealedBytes = hexDecode(stored.sealedKeyHex);
        final dk = _deviceKey;
        final Uint8List seed;
        if (dk is HwDeviceKey) {
          seed = await dk.unsealEnrollment(
            sealed: sealedBytes,
            email: stored.email,
            installId: await getOrCreateInstallId(_store),
            pkS: Uint8List.fromList(hexDecode(stored.pkHex)),
          );
        } else {
          seed = await _deviceKey.unseal(sealedBytes);
        }
        final sk = ed.newKeyFromSeed(seed);
        keys = ed.KeyPair(sk, ed.public(sk));
      } on StateError catch (e) {
        if ('$e'.contains('restore detected')) {
          BleLog.log('SEC',
              'enroll restore detected (clone) — re-enroll required');
          state = state.copyWith(
            phase: EnrollPhase.signedIn,
            message: 'restore detected — re-enroll',
          );
          return;
        }
        rethrow;
      }
      _keys = keys;
      _restoredRoll = stored.roll;
      // Stale pipeline (pre-plugin templates or older plugin builds): the
      // key is still valid, but the face record is incomparable — keep the
      // key, drop the face, land on the key step for a fresh capture.
      if (stored.isFaceStale(_verifier.verifierVer)) {
        _faceId = null;
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
      // Local-only restore: a valid key + current-pipeline faceId links
      // immediately — no server round-trip needed to keep attending.
      // The score is NOT a fresh match (nothing was scanned just now), so
      // it stays 0 with an honest message instead of a synthetic 1.00.
      _faceId = stored.faceId;
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
      // Corrupt store entry: ignore, proceed as fresh enrollment. Logged:
      // without this, a later Save fails with the misleading key-gate
      // prompt while the log drawer stays silent.
      BleLog.log('SEC', 'enroll restore failed, proceeding fresh');
    }
  }

  /// ID number (compulsory, unverified). Stored as-is.
  void setRoll(String roll) {
    state = state.copyWith(roll: roll.trim());
  }

  /// Step 2: generate Ed25519 keypair (SKey) + bind the HW device key
  /// (DKey) it seals to, embedding the M1-gap challenge
  /// `SHA256(email || installId || pkS)` at HW key creation. Software is
  /// not enrollable (`level == none` → `Software-no-enroll`); desktop/web
  /// fail closed before anything generates. A fresh key simply replaces
  /// any previous one on this device; cross-device duplicates are refused
  /// by the online claim at Save (one device per Gmail).
  Future<void> generateKey() async {
    final acct = state.account;
    if (acct == null) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Sign in first.');
      return;
    }
    try {
      requireMobileFace();
    } on StateError catch (e) {
      state = state.copyWith(phase: EnrollPhase.error, message: '$e');
      return;
    }
    // Security §5 pre-enroll gate (key ceremony): privileged / hooked /
    // tampered / emulator devices cannot create HW keys. StateError
    // carries the actionable copy; debug alone passes.
    try {
      await entryRequireEnrollIntegrity();
    } on StateError catch (e) {
      state = state.copyWith(phase: EnrollPhase.error, message: '$e');
      return;
    }
    try {
      final kp = ProxCrypto.generateEdKeypair();
      final pkS = Uint8List.fromList(kp.publicKey.bytes.sublist(0, 32));
      final pkHex = hexEncode(pkS);
      // Budgets: every post-probe await below has a deadline so a hung
      // Keystore/TEE op fails visible (tap again) instead of stranding
      // the button with no prompt and no error. FSS touches stay
      // prompt-tolerant (60s); the HW bind is programmatic (45s).
      const installIdBudget = Duration(seconds: 60);
      const bindBudget = Duration(seconds: 45);
      // Keypair log (public half ONLY — the seed never logs): the SKey
      // public key + install identity + HW bind each log under CRYPTO so
      // the key ceremony is traceable in the log drawer (the private seed
      // lives only in the sealed envelope, never in a log line).
      BleLog.log('CRYPTO',
          'SKey keypair generated pkS=${pkHex.substring(0, 12)}… (public half only)');
      late final String installId;
      try {
        installId =
            await getOrCreateInstallId(_store).timeout(installIdBudget);
      } on TimeoutException {
        state = state.copyWith(
            phase: EnrollPhase.error,
            message:
                'Secure storage timed out — tap Generate device key again.');
        return;
      }
      BleLog.log('CRYPTO',
          'SKey install identity ready install=${installId.substring(0, 8)}…');
      // iOS assertion path: same-install re-enroll yields an assertion, not
      // an object — carry the previous enrollment credential key forward
      // (same account only; anything else starts clean).
      var prevAppAttestCred = '';
      try {
        final prevStored = await _store.readEnrollment();
        if (prevStored != null &&
            prevStored.email.trim().toLowerCase() ==
                acct.email.toLowerCase()) {
          prevAppAttestCred = prevStored.appAttestCredKeyHex;
        }
      } catch (_) {}
      try {
        await _deviceKey
            .bindEnrollment(
                email: acct.email.toLowerCase(),
                installId: installId,
                pkS: pkS,
                prevAppAttestCredKeyHex: prevAppAttestCred)
            .timeout(bindBudget);
      } on TimeoutException {
        state = state.copyWith(
            phase: EnrollPhase.error,
            message:
                'Secure hardware timed out — tap Generate device key again.');
        BleLog.log('CRYPTO', 'DKey bind timed out (keypair kept, bind first)');
        return;
      } on StateError catch (e) {
        state = state.copyWith(phase: EnrollPhase.error, message: '$e');
        BleLog.log('CRYPTO', 'DKey bind refused: $e');
        return;
      }
      if (_deviceKey.level == AttestationLevel.none) {
        state = state.copyWith(
            phase: EnrollPhase.error,
            message:
                'Software-no-enroll: software device keys cannot enroll — use a mobile device with StrongBox/TEE or Secure Enclave.');
        return;
      }
      // Re-enroll purge: the new HW key already replaced the old under the
      // same alias (the plugin deletes first — Android deleteEntry, iOS
      // deleteBlob), the SKey below replaces `_keys`, and the sealed doc is
      // overwritten at upload. Drop the previous gallery template for this
      // faceId too, so an aborted re-enroll never leaves a stale template
      // behind. Best-effort (a missing entry is a no-op), after the bind
      // so a bind failure keeps the old working set intact.
      try {
        await _verifier.remove(
            faceIdOf(acct.email.toLowerCase(), installId));
      } catch (_) {}
      _keys = kp;
      _faceId = null;
      _restoredRoll = null;
      state = state.copyWith(
          phase: EnrollPhase.keyReady, pkHex: pkHex, restored: false);
      BleLog.log('CRYPTO',
          'DKey bound pkS=${pkHex.substring(0, 12)}… level=${attestationLevelName(_deviceKey.level)} — key ceremony complete');
    } catch (e) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Key generation failed: $e');
      BleLog.log('CRYPTO', 'SKey/DKey generate failed: $e');
    }
  }

  /// Step 3: on-device face enrollment from 5 stills
  /// (centre/left/right/up/down image paths from the continuous capture
  /// session). Each still's angle was already pose-gated at capture (ML Kit
  /// euler windows via the PoseGate — real gates, never instruction-only);
  /// ALL 5 stills are re-scored HERE before the gallery write (fail-closed,
  /// same copy idiom as RealStudentDriver.checkFace): each still must pass
  /// its Euler window (when a PoseGate is wired) + face-present AND the
  /// passive liveness gate — any failure aborts the enroll with a
  /// slot-naming error and the gallery stays untouched, so the claimed
  /// livenessVer is MEASURED on every enrolled still, never asserted. The
  /// plugin owns detection + matching passively (embeddings/sealed blobs
  /// treated as opaque — presence/shape/scores plumbing only, never
  /// decrypted or interpreted). A self-check verify of EVERY enrolled
  /// still must match before advancing (fail-closed with faceScore 0).
  /// Mobile-only: records-only devices fail closed via the verifier
  /// (never a mock pass).
  ///
  /// [challengeOrder] is the session's shuffled liveness walk order (for
  /// the decision log only — presence/order record, never a vitality
  /// verdict); when provided it is logged per enroll.
  Future<void> enrollFace(List<String> imagePaths,
      {List<LivenessAction>? challengeOrder}) async {
    // Binding point (faceId derives from the account): refuse a draft the
    // session moved under — a stale-account faceId must never enroll.
    if (_requireLiveAccount() == null) return;
    // Key gate on genuine absence, never on phase: a recapture from
    // faceDone/uploaded reuses the completed key (no repeated key
    // ceremony). Fail closed only when the key is truly missing.
    final acct = state.account;
    if (acct == null) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Sign in first.');
      return;
    }
    if (_keys == null || state.pkHex.isEmpty) {
      // Locked-key honesty: when this account HAS a stored enrollment,
      // the key exists but could not be unlocked (DKey/restore failure) —
      // saying "generate first" misleads (it was generated). Point at the
      // recovery instead. Genuinely keyless drafts keep the original
      // prompt (pinned by test).
      var locked = false;
      try {
        final stored = await _store.readEnrollment();
        locked = stored != null &&
            stored.email.trim().toLowerCase() ==
                acct.email.trim().toLowerCase();
      } catch (_) {}
      state = state.copyWith(
          phase: EnrollPhase.error,
          message: locked
              ? 'Couldn\u2019t unlock this device\u2019s key — tap Generate device key to make a new one, then scan.'
              : 'Generate the device key first, then scan.');
      return;
    }
    if (imagePaths.length != faceEnrollSlots.length) {
      state = state.copyWith(
          phase: EnrollPhase.error,
          message:
              'Capture ${faceEnrollSlots.length} stills (centre, left, right, up, down) to enroll.');
      return;
    }
    // Blank-frame guard (enrollment crash): a still that came out empty
    // never reaches the native plugin (empty bytes crash it below the Dart
    // catch) — error naming the angle, nothing stored, Save stays blocked.
    for (var i = 0; i < imagePaths.length; i++) {
      if (imagePaths[i].trim().isEmpty) {
        state = state.copyWith(
            phase: EnrollPhase.error,
            faceScore: 0,
            message:
                'The ${faceEnrollSlots[i]} still came out blank — recapture just that angle in good light, holding still.');
        return;
      }
    }
    // Security §4 passive + Euler gates on ALL 5 stills BEFORE the
    // gallery write (same copy idiom as RealStudentDriver.checkFace): a
    // photo or screen that would match the template must still fail here,
    // so the livenessVer claimed at Save names a real measurement on every
    // enrolled still. Per still, in slot order: (1) Euler window + face
    // presence via the PoseGate when wired (null reading = unreadable or
    // anything but exactly one face → slot-naming abort, never a pass);
    // (2) passive liveness via detectPassive (throw/unreadable → error,
    // rescan, nothing stored; below the per-slot bar → error as a readable
    // non-live still / spoof). Gallery untouched on any failure either way.
    // Opaque-bytes rule: embeddings/sealed blobs are never decrypted or
    // interpreted here — only presence (face present), shape (5 slots) and
    // score plumbing (liveness >= bar: Tl for centre,
    // [kEnrollSideLivenessThreshold] for the diversity slots) gate the enroll.
    // Scoring order + challenge order ride the decision log (BleLog FACE)
    // plus a debugPrint of the per-still box-vs-fallback path note: the
    // liveness gate crops the face box with a legacy centre-square
    // fallback (same scorer + Tl) — the plugin returns identity only, so
    // the per-still score below is the vitality gate output, never a
    // distance; the crop path itself is chosen inside the gate.
    if (challengeOrder != null && challengeOrder.isNotEmpty) {
      final order = challengeOrder.map((a) => a.name).join(' → ');
      BleLog.log('FACE', 'enroll challenge order: $order');
      debugPrint('enroll challenge order: $order');
    }
    BleLog.log('FACE',
        'enroll scoring ${imagePaths.length} stills in slot order: ${faceEnrollSlots.join(', ')}');
    _lastFailedSlot = null;
    for (var i = 0; i < imagePaths.length; i++) {
      final slot = faceEnrollSlots[i];
      final path = imagePaths[i];
      // (1) Euler window + face presence (wired gate only; capture already
      // gated, so a null gate skips — liveness + plugin checks still run).
      final poseGate = _poseGate;
      if (poseGate != null) {
        try {
          final reading = await poseGate.readPose(path);
          if (reading == null) {
            _slotFail(slot,
                'The $slot still did not read clearly (no face found) — recapture just that angle in good light, holding still.');
            return;
          }
          final decision = EnrollPoseWindows.check(
              slot, reading.yaw, reading.pitch, reading.roll);
          if (!decision.ok) {
            _slotFail(slot,
                'The $slot still missed its angle — ${decision.hint}');
            return;
          }
        } catch (e) {
          _slotFail(slot,
              'The $slot still did not read clearly — recapture just that angle in good light, holding still ($e)');
          return;
        }
      }
      // (2) Passive liveness on THIS still (fail-closed per still).
      LivenessResult live;
      try {
        live = await _liveness.detectPassive(path);
      } on StateError catch (e) {
        _slotFail(slot, '$e');
        return;
      } catch (e) {
        _slotFail(slot, 'Liveness check failed on the $slot still: $e');
        return;
      }
      // Gate contract: face-box crop only (no-box / too-blurry throws
      // unreadable → slot-naming recapture above, never a scored
      // background). Bar is per-slot: centre holds the strict protocol Tl
      // (the vitality decider), diversity slots hold [kEnrollSideLivenessThreshold].
      final bar = slot == 'centre'
          ? kLivenessThreshold
          : kEnrollSideLivenessThreshold;
      debugPrint(
          'enroll liveness scored slot=$slot score=${live.score.toStringAsFixed(2)} bar=${bar.toStringAsFixed(2)} ver=${live.ver}');
      if (live.score < bar) {
        BleLog.log('SEC',
            'enroll liveness FAIL slot=$slot score=${live.score.toStringAsFixed(2)} bar=${bar.toStringAsFixed(2)}');
        _slotFail(slot,
            'The $slot capture did not look live (possible photo or screen) — hold still in good light and recapture just that angle.');
        return;
      }
      BleLog.log('FACE',
          'enroll liveness pass slot=$slot score=${live.score.toStringAsFixed(2)}');
    }
    // All 5 stills gated above (each >= Tl) — gallery write next.
    try {
      final installId = await getOrCreateInstallId(_store);
      final faceId = faceIdOf(acct.email.toLowerCase(), installId);
      try {
        await _verifier.enroll(faceId, imagePaths);
      } catch (e) {
        // Mid-loop throw (e.g. slot 2 has no detectable face) leaves the
        // earlier slots orphaned in the plugin gallery — clear them so a
        // retry starts clean (best-effort; a delete miss just re-clears
        // on the next enroll).
        try {
          await _verifier.remove(faceId);
        } catch (_) {}
        rethrow;
      }
      // Self-check: EVERY enrolled still must match what was just
      // enrolled — a failed capture leaves no face behind, so a bad scan
      // can never advance to upload. Scores only presence/shape plumbing
      // (match bit + boundary score); embeddings stay opaque, never
      // interpreted. First failure names its slot and clears the gallery.
      FaceVerifyResult? firstCheck;
      for (var i = 0; i < imagePaths.length; i++) {
        final slot = faceEnrollSlots[i];
        final check = await _verifier.verify(faceId, imagePaths[i]);
        if (i == 0) firstCheck = check;
        debugPrint(
            'enroll self-check slot=$slot match=${check.match} score=${check.score.toStringAsFixed(2)}');
        if (!check.match) {
          try {
            await _verifier.remove(faceId);
          } catch (_) {}
          _faceId = null;
          state = state.copyWith(
              phase: EnrollPhase.error,
              faceScore: 0,
              message:
                  'The $slot capture did not match clearly — recapture just that angle in good light, holding still.');
          return;
        }
        BleLog.log('FACE',
            'enroll self-check match slot=$slot (boundary ${check.score.toStringAsFixed(2)})');
      }
      final check = firstCheck!;
      _faceId = faceId;
      // Numeric internals stay in the debug log only: the plugin returns
      // identity (match vs non-match), so check.score carries the decision
      // boundary, never a measured similarity — honest UI never shows it.
      BleLog.log('FACE',
          'enroll self-check match (boundary ${check.score.toStringAsFixed(2)})');
      // Clearing message is load-bearing: a prior attempt's slot refusal
      // (e.g. "the right capture did not look live") otherwise survives
      // into faceDone via copyWith, and the result screen's refusal
      // classifier (message non-empty → refusal card) renders the STALE
      // error above the Save button after a successful recapture.
      state = state.copyWith(
          phase: EnrollPhase.faceDone, faceScore: check.score, message: '');
      _lastFailedSlot = null;
    } on StateError catch (e) {
      // Fail-closed (records-only device, missing model, unreadable
      // still): no face stored, score stays 0.
      _faceId = null;
      state = state.copyWith(
          phase: EnrollPhase.error, faceScore: 0, message: '$e');
    } catch (e) {
      _faceId = null;
      state = state.copyWith(
          phase: EnrollPhase.error,
          faceScore: 0,
          message: 'Face capture failed: $e');
    }
  }

  /// Step 4: persist key + identity on this device AND claim the Gmail's
  /// single student-device slot online (one enrolled student device per
  /// Gmail, one Gmail per app install — see cloud_sync claim logic).
  /// Enrollment stays 100% on-device (nothing leaves the phone); same-face
  /// duplicates are caught later, in memory, on the professor's phone
  /// during the live local session.
  /// Fail-closed: requires a validated face (faceDone) — the Save button
  /// is disabled until then, and this validates again for programmatic
  /// callers. Online-only: the claim needs internet, which stops students
  /// from enrolling anywhere offline for false attendance. A Gmail held by
  /// a different device refuses here (30-day move cooldown with an exact
  /// re-enroll date; manual attendance covers the gap), as does an install
  /// enrolled as another Gmail. Racing devices lose atomically: exactly
  Future<LinkedIdentity?> upload() async {
    // Binding point (claim email + org derive from the account): refuse a
    // draft the session moved under — a stale-account claim must never
    // file, even if the UI raced the switch.
    final live = _requireLiveAccount();
    if (live == null) return null;
    final acct = state.account;
    final kp = _keys;
    final faceId = _faceId;
    if (faceId == null || state.phase != EnrollPhase.faceDone) {
      state = state.copyWith(
          phase: EnrollPhase.error,
          message:
              'Scan your face first — the capture must validate before saving.');
      return null;
    }
    if (acct == null || kp == null) {
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
      final org = acct.org.isNotEmpty ? acct.org : orgOf(email);
      final now = DateTime.now().toUtc();
      final nowMillis = now.millisecondsSinceEpoch;
      // 30-day face rescan quota (per-account, SAVE path only): replacing
      // an existing template is a rescan; first enrollment (no stored doc,
      // different Gmail, or empty faceId) is never gated. Started-but-
      // unsaved rescans never stamp (restartFace/enrollFace touch memory +
      // plugin only). Zero stamps (never rescanned, incl. pre-upgrade docs)
      // are always allowed once, then stamp. Durations derive from
      // kFaceRescanCooldown, never literals.
      StoredEnrollment? prevEnrollment;
      try {
        prevEnrollment = await _store.readEnrollment();
      } catch (_) {
        prevEnrollment = null;
      }
      final isFaceRescan = prevEnrollment != null &&
          prevEnrollment.email.toLowerCase() == email &&
          prevEnrollment.faceId.isNotEmpty;
      if (isFaceRescan &&
          faceRescanBlocked(
              stampMillis: prevEnrollment.lastFaceRescanAtMillis, now: now)) {
        final eligible =
            faceRescanEligibleAt(prevEnrollment.lastFaceRescanAtMillis);
        BleLog.log('FACE',
            'face rescan refused (cooldown until ${dateIsoOf(eligible)})');
        state = state.copyWith(
            phase: EnrollPhase.error,
            message: faceRescanCooldownMessage(eligible));
        return null;
      }
      final pk32 = Uint8List.fromList(kp.publicKey.bytes.sublist(0, 32));
      final pkHex = hexEncode(pk32);
      final installId = await getOrCreateInstallId(_store);
      // only at rest), stamp the extended claim. Records-only devices
      // cannot enroll (no HW key) — fail closed before the claim.
      Uint8List sealed;
      Uint8List pkDRaw;
      List<String> chainDERHex;
      // Apple App Attest artifacts (iOS only; '' on Android — stamped into
      // the claim doc + local enrollment for the professor iOS branch).
      String appAttestRawHex = '';
      String appAttestCredKeyHex = '';
      try {
        requireMobileFace();
        await _deviceKey.ensure();
        if (_deviceKey.level == AttestationLevel.none) {
          throw StateError(
              'Software-no-enroll: software device keys cannot enroll — use a mobile device with StrongBox/TEE or Secure Enclave.');
        }
        // Cheap hygiene (best-effort in Dart — GC copies may linger):
        // the transient 32B seed copy is zeroed right after sealing so it
        // never outlives the seal call on the heap.
        // Track A (M7): AAD-bound seal (email/installId/pkS/pkD via
        // buildSealAad) so a transplanted envelope fails the GCM tag.
        // HW path uses sealWithAad; software/fake seal (empty AAD) is
        // test-only. No decryption of sealed bytes beyond this device's
        // own envelope under its DEK.
        final seedCopy = Uint8List.fromList(ed.seed(kp.privateKey));
        try {
          final dk = _deviceKey;
          if (dk is HwDeviceKey) {
            final pkSBytes =
                Uint8List.fromList(hexDecode(pkHex));
            sealed = await dk.sealWithAad(
              seedCopy,
              aad: buildSealAad(
                emailLower: acct.email.toLowerCase(),
                installId: await getOrCreateInstallId(_store),
                pkS: pkSBytes,
                pkD: dk.pkD,
              ),
            );
          } else {
            sealed = await _deviceKey.seal(seedCopy);
          }
        } finally {
          seedCopy.fillRange(0, seedCopy.length, 0);
        }
        pkDRaw = _deviceKey.pkD;
        chainDERHex = _deviceKey.chainDERHex;
        final dkApple = _deviceKey;
        if (dkApple is HwDeviceKey) {
          appAttestRawHex = dkApple.appAttestRawHex;
          appAttestCredKeyHex = dkApple.appAttestCredKeyHex;
        }
      } on StateError catch (e) {
        state = state.copyWith(
            phase: EnrollPhase.error, message: '$e');
        return null;
      }
      // Advisory revocation review for this chain (security §2 residual):
      // offline serial-vs-CRL flags for the professor review screen, log
      // only — never blocks the claim or marking (fail-open; empty chains
      // keep the existing stale-flag behavior).
      unawaited(logChainRevocationReview(chainDERHex, 'enroll'));
      final rolled = await _deviceKey.heartbeat();
      if (rolled) {
        BleLog.log('SEC', 'device attestation heartbeat ok');
      }
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
                  'Student enrollment needs internet (one enrolled device per Gmail is checked online). Connect and tap Save again — your face capture is kept.');
          return null;
        }
        // One-time online CRL snapshot refresh (security §2 residual):
        // Firestore-independent HTTPS, best-effort, never blocks the claim
        // (failure degrades to the `revocation-stale` review flag — see
        // core/security/revocation_cache.dart). Fire-and-forget on purpose:
        // offline marking never waits on it.
        unawaited(RevocationCache.refreshBestEffort(
            hashStore: _store.revocationHashStore));
        // Pre-claim verdict-by-evidence (before the transaction): a
        // cross-org second-account enroll is denied at the install-doc
        // READ, so the transaction could never see the evidence and would
        // surface a deploy hint instead of the friendly refusal. Scope it
        // here: a clean own-doc read + denied install-doc read proves the
        // install holds another Gmail → friendly installConflict copy
        // verbatim (same [studentClaimMessage] source as every other
        // refusal path). Own-doc denied → genuine rules problem → deploy
        // hint verbatim. Unknown read failures skip the pre-claim and the
        // transaction below decides, exactly as before.
        var skipPreclaim = false;
        StudentDeviceDoc? preBinding;
        try {
          preBinding = await cloud.fetchStudentDevice(email);
        } on StateError catch (e) {
          if (isRulesDenialMessage(e.message)) {
            state = state.copyWith(
                phase: EnrollPhase.error, message: e.message);
            return null;
          }
          skipPreclaim = true;
        } catch (_) {
          skipPreclaim = true;
        }
        if (!skipPreclaim) {
          var installDenied = false;
          String? preInstall;
          try {
            preInstall = await cloud.fetchInstallEmail(installId);
          } on StateError catch (e) {
            if (isRulesDenialMessage(e.message)) {
              installDenied = true;
            } else {
              skipPreclaim = true;
            }
          } catch (_) {
            skipPreclaim = true;
          }
          if (!skipPreclaim) {
            final preVerdict = evaluateStudentClaim(
                localInstallId: installId,
                binding: preBinding,
                installEmail: preInstall,
                email: email);
            final effective = installDenied && preVerdict.ok
                ? const StudentClaimResult(StudentClaim.installConflict)
                : preVerdict;
            if (!effective.ok) {
              BleLog.log('SYNC', 'device claim refused (see screen message)');
              state = state.copyWith(
                  phase: EnrollPhase.error,
                  message: studentClaimMessage(effective, preBinding));
              return null;
            }
          }
        }
        // Security §5 pre-enroll gate (claim): re-probed fresh at upload
        // so a device tainted after the key ceremony still cannot claim.
        // The verdict's advisory flag rides the claim (clean '' here —
        // tainted throws above and never reaches the transaction).
        String enrollIntegrityFlag = '';
        try {
          final enrollVerdict = await entryRequireEnrollIntegrity();
          enrollIntegrityFlag = enrollVerdict.flagForMarking;
        } on StateError catch (e) {
          state = state.copyWith(phase: EnrollPhase.error, message: '$e');
          return null;
        }
        // Security §2 self-check (claim): run the professor's chain gate
        // LOCALLY before the binding is written — an unrecognized chain
        // would fail every future marking as `device-unproven`, so refuse
        // the enroll NOW with the named cause instead of stranding the
        // holder later (and instead of filing a useless binding). The
        // server verdict stays final; this mirrors its gate exactly.
        // HW keys only: Fake/Software keys carry synthetic chains with no
        // verifiable HW attestation (tests + blocked paths) — the server
        // stays the authority there.
        if (_deviceKey is HwDeviceKey) {
          final chainCheck = checkAttestationChain(
            chainHex: chainDERHex,
            attestationLevel: attestationLevelName(_deviceKey.level),
            emailLower: email,
            installId: installId,
            pkSHex: pkHex,
            pkDHex: hexEncode(pkDRaw),
            iosBranch: appAttestRawHex.trim().isNotEmpty,
          );
          BleLog.log('CRYPTO',
              'attestation self-check ${chainCheck.ok ? 'ok' : 'FAIL ${chainCheck.reason}'} '
              'chain=${chainCheck.chainLen} root=${chainCheck.rootPrefix.isEmpty ? 'none' : chainCheck.rootPrefix}');
          if (!chainCheck.ok) {
            state = state.copyWith(
                phase: EnrollPhase.error,
                message: attestationSelfCheckCopy(chainCheck));
            return null;
          }
        }
        try {
          // Stable phone id for the same-phone reclaim (fail-soft ''):
          // a same-phone reinstall presents the stored deviceId and skips
          // the 30-day move cooldown — Gmail auth + fresh face + fresh HW
          // key still gate the claim, and the server re-checks the match.
          final hardwareDeviceId = await getStableHardwareDeviceId();
          final outcome = await cloud.claimStudentDevice(
              doc: StudentDeviceDoc(
                  email: email,
                  uid: acct.uid,
                  pkHex: pkHex,
                  name: name,
                  roll: roll,
                  modelVer: _verifier.verifierVer,
                  installId: installId,
                  platform: _platformName(),
                  org: org,
                  deviceId: hardwareDeviceId,
                  pkDHex: hexEncode(pkDRaw),
                  attestationLevel:
                      attestationLevelName(_deviceKey.level),
                  attestedAtMillis: _deviceKey.attestedAt
                      .toUtc()
                      .millisecondsSinceEpoch,
                  attestedUntilMillis: _deviceKey.attestedUntil
                      .toUtc()
                      .millisecondsSinceEpoch,
                  // Security §7: HW chain (leaf-first DER hex) + liveness
                  // pipeline tag. integrityFlag is the advisory
                  // verdict.flagForMarking ('' clean — the fresh
                  // pre-claim gate above throws on tainted, so a filed
                  // claim always carries clean; the host still treats the
                  // flag as advisory, never auto-absent). The livenessVer
                  // tag names the pipeline that MEASURED the centre still
                  // ([enrollFace] gates on it before the gallery write —
                  // fail-closed, same idiom as marking).
                  attestationChain: chainDERHex,
                  livenessVer: kLivenessVer,
                  integrityFlag: enrollIntegrityFlag,
                  appAttestRawHex: appAttestRawHex,
                  appAttestCredKeyHex: appAttestCredKeyHex),
              installId: installId);
          BleLog.log('SYNC',
              'device claim ok (${outcome.isFirst ? 'first bind' : outcome.isMove ? (outcome.isReclaim ? 'same-phone reclaim' : 'device move') : 'same device'})');
        } on StateError catch (e) {
          BleLog.log('SYNC', 'device claim refused (see screen message)');
          state = state.copyWith(
              phase: EnrollPhase.error, message: e.message);
          return null;
        } on FirebaseException catch (e) {
          // No raw Firebase/grpc text past this point (presentation-only
          // mapping, no server semantics): permission-denied is the
          // install-conflict evidence (rules refused the save) → the
          // friendly installConflict copy; any other transport failure →
          // the verbatim offline copy (retry-safe guidance, capture kept).
          BleLog.log('SYNC', 'device claim transport refused (${e.code})');
          if (e.code == 'permission-denied') {
            state = state.copyWith(
                phase: EnrollPhase.error,
                message: studentClaimMessage(
                    const StudentClaimResult(
                        StudentClaim.installConflict),
                    null));
          } else {
            state = state.copyWith(
                phase: EnrollPhase.error,
                message:
                    'Student enrollment needs internet (one enrolled device per Gmail is checked online). Connect and tap Save again — your face capture is kept.');
          }
          return null;
        } catch (e) {
          state = state.copyWith(
              phase: EnrollPhase.error, message: 'Save failed: $e');
          return null;
        }
      }
      // Rescan stamp: a successful template replacement stamps now; a
      // first enrollment preserves any same-account stamp (normally 0) and
      // a different account starts at 0. Failed saves return above, so they
      // never stamp. Old template handling otherwise unchanged.
      final rescanStampMillis = isFaceRescan
          ? nowMillis
          : (prevEnrollment != null &&
                  prevEnrollment.email.toLowerCase() == email
              ? prevEnrollment.lastFaceRescanAtMillis
              : 0);
      // Sealed-only (security §2 F1 fix): `sealedKeyHex + pkDHex +
      // chainDERHex` only — no raw-seed field exists.
      await _store.writeEnrollment(StoredEnrollment(
        email: email,
        name: name,
        roll: roll,
        pkHex: pkHex,
        sealedKeyHex: hexEncode(sealed),
        chainDERHex: chainDERHex,
        appAttestRawHex: appAttestRawHex,
        appAttestCredKeyHex: appAttestCredKeyHex,
        faceId: faceId,
        enrolledAt: now,
        verifierVer: _verifier.verifierVer,
        org: org,
        pkDHex: hexEncode(pkDRaw),
        attestationLevel: attestationLevelName(_deviceKey.level),
        attestedAt: _deviceKey.attestedAt,
        attestedUntil: _deviceKey.attestedUntil,
        lastFaceRescanAtMillis: rescanStampMillis,
      ));
      state = state.copyWith(phase: EnrollPhase.uploaded, message: '');
      return LinkedIdentity(name: name, gmail: email, roll: roll, org: org);
    } catch (e) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Save failed: $e');
      return null;
    }
  }

  /// Next-eligible UTC date for a SAVED face re-scan for the current
  /// account. Null = allowed now (no stored template, different Gmail,
  /// never rescanned, or the [kFaceRescanCooldown] window elapsed).
  ///
  /// Read-only UI accessor for the account-copy follow-up (exact eligible
  /// date via dateIsoOf + manual-attendance pointer): the SAVE path
  /// ([upload]) enforces the same rule — this never stamps, never blocks.
  /// Durations derive from [kFaceRescanCooldown], never literals.
  Future<DateTime?> faceRescanBlockedUntil({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    StoredEnrollment? stored;
    try {
      stored = await _store.readEnrollment();
    } catch (_) {
      return null;
    }
    if (stored == null || stored.faceId.isEmpty) return null;
    final acctEmail = state.account?.email.toLowerCase();
    if (acctEmail != null &&
        acctEmail.isNotEmpty &&
        stored.email.toLowerCase() != acctEmail) {
      return null;
    }
    if (!faceRescanBlocked(
        stampMillis: stored.lastFaceRescanAtMillis, now: at)) {
      return null;
    }
    return faceRescanEligibleAt(stored.lastFaceRescanAtMillis);
  }

  /// explicitly-requested business addition — minimal called-out addition).
  ///
  /// Rewrites ONLY the stored enrollment's roll (+ in-memory draft roll when
  /// it belongs to the same Gmail); keys/face/install/org/stamps untouched.
  /// Historical session rolls/names untouched by design (class history is
  /// immutable — past records keep the roll shown at mark time).
  /// Skew note (advisory, no behavior change): this rewrite preserves the
  /// HW envelope + chain + attestedAt/Until verbatim — no clock read, so
  /// no local-skew trust. Claim-side freshness is
  /// server-gated (rules request.time ±1h); attestedAt/doublePkD/
  /// integrity-flagged/duplicate-confirmed stay professor-review advisories
  /// (never auto-absent offline) — see PROXIMITY_DESIGN.md residuals.
  Future<void> updateLocalRoll(String newRoll) async {
    final want = newRoll.trim();
    if (want.isEmpty) throw StateError('ID Number is required.');
    final stored = await _store.readEnrollment();
    if (stored == null) {
      throw StateError(
          'No enrolled device found for this account — enroll this device first.');
    }
    // Sealed-only: roll rewrite preserves the HW envelope + chain.
    await _store.writeEnrollment(StoredEnrollment(
      email: stored.email,
      name: stored.name,
      roll: want,
      pkHex: stored.pkHex,
      sealedKeyHex: stored.sealedKeyHex,
      chainDERHex: stored.chainDERHex,
      faceId: stored.faceId,
      enrolledAt: stored.enrolledAt,
      verifierVer: stored.verifierVer,
      org: stored.org,
      pkDHex: stored.pkDHex,
      attestationLevel: stored.attestationLevel,
      attestedAt: stored.attestedAt,
      attestedUntil: stored.attestedUntil,
      lastFaceRescanAtMillis: stored.lastFaceRescanAtMillis,
      appAttestRawHex: stored.appAttestRawHex,
      appAttestCredKeyHex: stored.appAttestCredKeyHex,
    ));
    // Keep the draft consistent when it tracks the same Gmail.
    final acctEmail = state.account?.email.toLowerCase() ?? '';
    if (acctEmail.isEmpty ||
        acctEmail == stored.email.trim().toLowerCase()) {
      state = state.copyWith(roll: want);
    }
  }

  /// Explicit re-scan (restored users, changed appearance): keeps the
  /// device key, clears the in-memory face. The stored faceId on disk is
  /// untouched (attendance still works via the linked identity until the
  /// new capture validates), but this screen cannot save the OLD face
  /// after a rescan starts — Save stays blocked until the new capture
  /// validates.
  Future<void> restartFace() async {
    final old = _faceId;
    _faceId = null;
    if (old != null) {
      try {
        await _verifier.remove(old);
      } catch (_) {}
    }
    state = state.copyWith(
        phase: EnrollPhase.keyReady, faceScore: 0, message: '');
  }

  /// Retry from the last good step (error is non-destructive). Invariant:
  /// a failed capture stores no face (see [enrollFace]), so this lands
  /// back on the key step — never on faceDone with score 0.
  void dismissError() {
    final back = _keys != null
        ? (_faceId != null ? EnrollPhase.faceDone : EnrollPhase.keyReady)
        : (state.account != null ? EnrollPhase.signedIn : EnrollPhase.signedOut);
    state = state.copyWith(phase: back, message: '');
  }
}

final enrollmentControllerProvider =
    StateNotifierProvider<EnrollmentController, EnrollmentState>((ref) {
  throw UnimplementedError('Override in main / tests');
});
