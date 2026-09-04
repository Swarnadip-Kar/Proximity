// Enrollment flow: Google sign-in → device Ed25519 keypair → on-device
// face enrollment → upload {email, name, roll, PK, faceHash, modelVer} +
// Sign(SK) to `rosterKeys/{email}`.
//
// Identity is the Gmail account itself: display name is imported directly,
// ID number is user-entered (compulsory, unverified). Students type nothing
// in class — attendance auto-attaches the linked identity.
//
// Re-login policy: one device key per email per 24h. Same device restores
// its key from secure storage (no new key); a new device inside the window
// is rejected client-side AND by Firestore rules. Timestamps come from the
// server doc (`updatedAt`), so the limit holds across devices.
//
// Face templates never leave the phone: only faceHash = H(template) uploads.
// Key seed lives in secure storage; production uses Keystore/StrongBox
// (Android), Secure Enclave (iOS), OS keychain (desktop).
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
import 'device_store.dart';
import 'roster_repo.dart';

/// Minimum age of a server enrollment before the same email may enroll a
/// different device key. Mirrors firestore.rules.
const kReenrollCooldown = Duration(hours: 24);

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
  final DeviceStore _store;
  final FaceEmbedder _embedder;

  ed.KeyPair? _keys;
  List<double>? _template;
  String? _restoredRoll;

  EnrollmentController({
    required AuthService auth,
    required RosterRepository repo,
    required DeviceStore store,
    required FaceEmbedder embedder,
    SignedAccount? preseed,
  })  : _auth = auth,
        _repo = repo,
        _store = store,
        _embedder = embedder,
        super(EnrollmentState(
            phase: preseed == null
                ? EnrollPhase.signedOut
                : EnrollPhase.signedIn,
            account: preseed));

  /// Step 1: Google sign-in (persists via Firebase Auth), then same-device
  /// restore when this phone already holds a key for the account.
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
      _template = stored.template;
      _restoredRoll = stored.roll;
      final server = await _repo.fetchKey(email);
      if (server == null) {
        // Server doc gone (admin reset): keep key, re-upload when ready.
        state = state.copyWith(
          phase: EnrollPhase.faceDone,
          pkHex: stored.pkHex,
          roll: stored.roll,
          restored: true,
          faceScore: 1.0,
        );
        return;
      }
      if (server.pkHex.toLowerCase() == stored.pkHex.toLowerCase()) {
        state = state.copyWith(
          phase: EnrollPhase.uploaded,
          pkHex: stored.pkHex,
          roll: stored.roll,
          restored: true,
          faceScore: 1.0,
        );
      }
      // Else: server moved on (re-enrolled elsewhere) — stay signed in;
      // generateKey() applies the 24h rule for a fresh key.
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
    );
  }

  /// ID number (compulsory, unverified). Stored as-is.
  void setRoll(String roll) {
    state = state.copyWith(roll: roll.trim());
  }

  /// Step 2: generate Ed25519 keypair. A different key for the same email
  /// is allowed at most once per 24h (server `updatedAt` is the clock).
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
      if (existing != null &&
          existing.pkHex.toLowerCase() != pkHex.toLowerCase()) {
        final next = existing.updatedAt.add(kReenrollCooldown);
        final wait = next.difference(DateTime.now().toUtc());
        if (wait > Duration.zero) {
          final h = wait.inHours;
          final m = wait.inMinutes.remainder(60);
          state = state.copyWith(
            phase: EnrollPhase.error,
            message:
                '${acct.email} enrolled another device recently. Re-login allowed once a day — try again in ${h}h ${m}m.',
          );
          return;
        }
      }
      _keys = kp;
      _restoredRoll = null;
      state = state.copyWith(
          phase: EnrollPhase.keyReady, pkHex: pkHex, restored: false);
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

  /// Step 4: upload {email, name, roll, PK, faceHash, modelVer} +
  /// Sign(SK, email||PK||name), then persist key + identity on device.
  Future<LinkedIdentity?> upload() async {
    final acct = state.account;
    final kp = _keys;
    final template = _template;
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
      final pk32 = Uint8List.fromList(kp.publicKey.bytes.sublist(0, 32));
      final preimage = Uint8List.fromList([
        ...utf8.encode(email),
        ...pk32,
        ...utf8.encode(name),
      ]);
      final sig = ProxCrypto.sign(kp.privateKey, preimage);
      final record = RosterKeyRecord(
        pkHex: hexEncode(pk32),
        name: name,
        email: email,
        roll: roll,
        faceHashHex: faceTemplateHash(template),
        modelVer: 'edgeface-xs-mock-0',
        sigHex: hexEncode(sig),
        updatedAt: DateTime.now().toUtc(),
      );
      await _repo.uploadKey(email, record);
      await _store.writeEnrollment(StoredEnrollment(
        email: email,
        name: name,
        roll: roll,
        seedHex: hexEncode(ed.seed(kp.privateKey)),
        pkHex: hexEncode(pk32),
        templateCsv: StoredEnrollment.csvOf(template),
        enrolledAt: DateTime.now().toUtc(),
      ));
      state = state.copyWith(phase: EnrollPhase.uploaded);
      return LinkedIdentity(name: name, gmail: email, roll: roll);
    } catch (e) {
      state = state.copyWith(
          phase: EnrollPhase.error, message: 'Upload failed: $e');
      return null;
    }
  }

  /// Retry from the last good step (error is non-destructive).
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
