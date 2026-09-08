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
// Face data never leaves the phone, full stop: the plugin owns its
// on-device store keyed by faceId=sha256(gmail+installId) — never the raw
// Gmail. The app keeps only {faceId, verifierVer, enrolledAt}; the SKey
// seed is DKey-sealed (ciphertext only at rest).
//
// Key seed lives in secure storage; production uses Keystore/StrongBox
// (Android), Secure Enclave (iOS), OS keychain (desktop).
// Face enrollment: injected [FaceVerifier]. Production injects
// [PluginFaceVerifier] (mobile-only); [FakeFaceVerifier] drives unit
// tests only, never the shipped app. Desktop/web get
// [UnavailableFaceVerifier] and fail closed before anything signs.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';

import '../features/face_identity/device_key.dart';
import '../features/face_identity/face_verifier.dart';
import '../mode.dart';
import 'auth.dart';
import 'cloud_sync.dart';
import 'device_store.dart';
import 'platformx.dart';

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
  // Cloud device binding (null in unit tests → local-only behavior).
  final CloudSync? _cloud;

  /// The face verifier (shared with the live check for the ticket stamp).
  FaceVerifier get verifier => _verifier;

  /// The HW device key (DKey) this enrollment seals to.
  DeviceKey get deviceKey => _deviceKey;

  ed.KeyPair? _keys;
  String? _faceId;
  String? _restoredRoll;

  EnrollmentController({
    required AuthService auth,
    required DeviceStore store,
    required FaceVerifier verifier,
    required DeviceKey deviceKey,
    SignedAccount? preseed,
    CloudSync? cloud,
  })  : _auth = auth,
        _store = store,
        _verifier = verifier,
        _deviceKey = deviceKey,
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
      // Sealed path (production): unwrap needs THIS device's DKey — a
      // backup-restore clone carrying ciphertext fails here with
      // 'restore detected — re-enroll' and must re-enroll, never match.
      ed.KeyPair keys;
      if (stored.sealedKeyHex.isNotEmpty) {
        try {
          await _deviceKey.ensure();
        } catch (e) {
          // Records-only device holding a phone-bound enrollment: the key
          // stays locked; the holder continues on their phone.
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
          final seed =
              await _deviceKey.unseal(hexDecode(stored.sealedKeyHex));
          final sk = ed.newKeyFromSeed(seed);
          keys = ed.KeyPair(sk, ed.public(sk));
        } on StateError catch (e) {
          if ('$e'.contains('restore detected')) {
            state = state.copyWith(
              phase: EnrollPhase.signedIn,
              message: 'restore detected — re-enroll',
            );
            return;
          }
          rethrow;
        }
      } else {
        // Legacy/test path: raw seed hex.
        final seed = hexDecode(stored.seedHex);
        final sk = ed.newKeyFromSeed(seed);
        keys = ed.KeyPair(sk, ed.public(sk));
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

  /// Step 2: generate Ed25519 keypair (SKey) + ensure the HW device key
  /// (DKey) it seals to. A fresh key simply replaces any previous one on
  /// this device; cross-device duplicates are refused by the online claim
  /// at Save (one device per Gmail).
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
      _faceId = null;
      _restoredRoll = null;
      state = state.copyWith(
          phase: EnrollPhase.keyReady, pkHex: pkHex, restored: false);
    } catch (e) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Key generation failed: $e');
    }
  }

  /// Step 3: on-device face enrollment from 3 stills (centre/left/right
  /// image paths from the capture screen). The plugin owns detection +
  /// matching passively — no pose gates, no liveness prompts here. A
  /// self-check verify of the centre still must match before advancing
  /// (fail-closed with faceScore 0). Mobile-only: records-only devices
  /// fail closed via the verifier (never a mock pass).
  Future<void> enrollFace(List<String> imagePaths) async {
    if (state.phase != EnrollPhase.keyReady &&
        state.phase != EnrollPhase.error) {
      state = state.copyWith(
          phase: EnrollPhase.error,
          message: state.account == null
              ? 'Sign in first.'
              : 'Generate the device key first, then scan.');
      return;
    }
    final acct = state.account;
    if (acct == null || _keys == null) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Complete all steps first.');
      return;
    }
    if (imagePaths.length != faceEnrollSlots.length) {
      state = state.copyWith(
          phase: EnrollPhase.error,
          message:
              'Capture ${faceEnrollSlots.length} stills (centre, left, right) to enroll.');
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
      // Self-check: the centre still must match what was just enrolled —
      // a failed capture leaves no face behind, so a bad scan can never
      // advance to upload.
      final check = await _verifier.verify(faceId, imagePaths.first);
      if (!check.match) {
        try {
          await _verifier.remove(faceId);
        } catch (_) {}
        _faceId = null;
        state = state.copyWith(
            phase: EnrollPhase.error,
            faceScore: 0,
            message:
                'Face capture did not match clearly — recapture in good light, holding still.');
        return;
      }
      _faceId = faceId;
      state = state.copyWith(
          phase: EnrollPhase.faceDone, faceScore: check.score);
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
  /// Fail-closed: requires a validated face (faceDone) — the Save button
  /// is disabled until then, and this validates again for programmatic
  /// callers. Online-only: the claim needs internet, which stops students
  /// from enrolling anywhere offline for false attendance. A Gmail held by
  /// a different device refuses here (weekly cooldown with an exact
  /// re-enroll date; manual attendance covers the gap), as does an install
  /// enrolled as another Gmail. Racing devices lose atomically: exactly
  /// one claim wins. Carries `org` into every new record (Track 1).
  Future<LinkedIdentity?> upload() async {
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
      final installId = await getOrCreateInstallId(_store);
      // Device binding (Track 3): ensure DKey, seal SKey (ciphertext
      // only at rest), stamp the extended claim. Records-only devices
      // cannot enroll (no HW key) — fail closed before the claim.
      Uint8List sealed;
      Uint8List pkDRaw;
      try {
        requireMobileFace();
        await _deviceKey.ensure();
        sealed = await _deviceKey.seal(
            Uint8List.fromList(ed.seed(kp.privateKey)));
        pkDRaw = _deviceKey.pkD;
      } on StateError catch (e) {
        state = state.copyWith(
            phase: EnrollPhase.error, message: '$e');
        return null;
      }
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
        try {
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
                  pkDHex: hexEncode(pkDRaw),
                  attestationLevel:
                      attestationLevelName(_deviceKey.level),
                  attestedAtMillis: _deviceKey.attestedAt
                      .toUtc()
                      .millisecondsSinceEpoch,
                  attestedUntilMillis: _deviceKey.attestedUntil
                      .toUtc()
                      .millisecondsSinceEpoch),
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
        sealedKeyHex: hexEncode(sealed),
        faceId: faceId,
        enrolledAt: DateTime.now().toUtc(),
        verifierVer: _verifier.verifierVer,
        org: org,
        pkDHex: hexEncode(pkDRaw),
        attestationLevel: attestationLevelName(_deviceKey.level),
        attestedAt: _deviceKey.attestedAt,
        attestedUntil: _deviceKey.attestedUntil,
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
