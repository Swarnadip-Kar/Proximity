// Enrollment flow: Google sign-in → device Ed25519 keypair → on-device
// face enrollment → upload {email, name, PK, faceHash, modelVer} + Sign(SK)
// to `rosterKeys/{email}`.
//
// Identity is the Gmail account itself: display name is imported directly,
// no institute-ID entry or roster matching. Students type nothing —
// attendance auto-attaches the linked identity.
//
// Face templates never leave the phone: only faceHash = H(template) uploads.
// Key storage: in-memory here; production uses Keystore/StrongBox (Android),
// Secure Enclave (iOS), OS keychain (desktop) — see TODO in [_keys].
// Face capture: injected [FaceEmbedder]; camera + EdgeFace-XS model lands in
// P1-face (TODO) — [MockFaceEmbedder] drives tests/demos.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_face/face.dart';
import 'package:proximity_protocol/protocol.dart';

import '../mode.dart';
import 'auth.dart';
import 'roster_repo.dart';

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
  const EnrollmentState({
    this.phase = EnrollPhase.signedOut,
    this.account,
    this.roll = '',
    this.pkHex = '',
    this.faceScore = 0,
    this.message = '',
  });

  EnrollmentState copyWith({
    EnrollPhase? phase,
    SignedAccount? account,
    String? roll,
    String? pkHex,
    double? faceScore,
    String? message,
  }) =>
      EnrollmentState(
        phase: phase ?? this.phase,
        account: account ?? this.account,
        roll: roll ?? this.roll,
        pkHex: pkHex ?? this.pkHex,
        faceScore: faceScore ?? this.faceScore,
        message: message ?? this.message,
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

class EnrollmentController extends StateNotifier<EnrollmentState> {
  final AuthService _auth;
  final RosterRepository _repo;
  final FaceEmbedder _embedder;

  ed.KeyPair? _keys; // TODO: secure-hardware storage per platform (§3.2.3)
  List<double>? _template;

  EnrollmentController({
    required AuthService auth,
    required RosterRepository repo,
    required FaceEmbedder embedder,
    SignedAccount? preseed,
  })  : _auth = auth,
        _repo = repo,
        _embedder = embedder,
        super(EnrollmentState(
            phase: preseed == null
                ? EnrollPhase.signedOut
                : EnrollPhase.signedIn,
            account: preseed));

  /// Step 1: Google sign-in. Name + email import directly — nothing to type.
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
    } catch (e) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Sign-in failed: $e');
    }
  }

  /// ID number (institute ID). Required before upload; stored as-is and
  /// never verified — it is display metadata, authentication is the Gmail
  /// account + device key.
  void setRoll(String roll) {
    state = state.copyWith(roll: roll.trim());
  }

  /// Step 2: generate Ed25519 keypair. One device per email: rejects when
  /// `rosterKeys[email]` already carries a different PK.
  Future<void> generateKey() async {
    final acct = state.account;
    if (acct == null) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Sign in first.');
      return;
    }
    try {
      final existing = await _repo.fetchKey(acct.email);
      final kp = ProxCrypto.generateEdKeypair();
      final pkHex =
          hexEncode(Uint8List.fromList(kp.publicKey.bytes.sublist(0, 32)));
      if (existing != null && existing.pkHex.toLowerCase() != pkHex) {
        state = state.copyWith(
          phase: EnrollPhase.error,
          message: '${acct.email} is already enrolled on another '
              'device. Contact your admin to revoke it first.',
        );
        return;
      }
      _keys = kp;
      state = state.copyWith(phase: EnrollPhase.keyReady, pkHex: pkHex);
    } catch (e) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Key generation failed: $e');
    }
  }

  /// Step 3: on-device face enrollment (template stays on phone).
  Future<void> captureFace(List<int> frameBytes) async {
    if (state.phase != EnrollPhase.keyReady) return;
    try {
      final session = FaceSession(embedder: _embedder);
      final probe = await _embedder.embed(frameBytes);
      session.enroll(probe);
      _template = probe;
      final res = await session.verify(frameBytes,
          challenge: Uint8List.fromList(const [0, 0, 0, 0, 0, 0, 0, 0]),
          now: DateTime.now().toUtc());
      if (res.decision == FaceDecision.pass) {
        state = state.copyWith(
            phase: EnrollPhase.faceDone, faceScore: res.score);
      } else {
        state = state.copyWith(
          phase: EnrollPhase.error,
          message: 'Face not recognized clearly. Try again in good light.',
        );
      }
    } catch (e) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Face capture failed: $e');
    }
  }

  /// Step 4: upload {email, name, PK, faceHash, modelVer} +
  /// Sign(SK, email||PK||name).
  Future<LinkedIdentity?> upload() async {
    final acct = state.account;
    final kp = _keys;
    final template = _template;
    if (acct == null || kp == null || template == null) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Complete all steps first.');
      return null;
    }
    if (state.roll.isEmpty) {
      state = state.copyWith(
          phase: EnrollPhase.error,
          message: 'Enter your ID number to continue.');
      return null;
    }
    try {
      final email = acct.email.toLowerCase();
      final pk32 = Uint8List.fromList(kp.publicKey.bytes.sublist(0, 32));
      final preimage = Uint8List.fromList([
        ...utf8.encode(email),
        ...pk32,
        ...utf8.encode(acct.displayName),
      ]);
      final sig = ProxCrypto.sign(kp.privateKey, preimage);
      final record = RosterKeyRecord(
        pkHex: hexEncode(pk32),
        name: acct.displayName,
        email: email,
        roll: state.roll,
        faceHashHex: faceTemplateHash(template),
        modelVer: 'edgeface-xs-mock-0',
        sigHex: hexEncode(sig),
        updatedAt: DateTime.now().toUtc(),
      );
      await _repo.uploadKey(email, record);
      state = state.copyWith(phase: EnrollPhase.uploaded);
      return LinkedIdentity(
          name: acct.displayName, gmail: email, roll: state.roll);
    } catch (e) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Upload failed: $e');
      return null;
    }
  }

  /// Retry from the last good step (error is non-destructive: keys/template
  /// are kept for the session).
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
