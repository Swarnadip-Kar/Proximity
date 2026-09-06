// Cryptographic core per §5.1, §3.3.
//
// Primitives via `crypto` (HMAC-SHA256, SHA-256, sync hot path) +
// `ed25519_edwards` (Ed25519 sign/verify, sync + RFC8032 testable).
//
// Layouts (big-endian, canonical):
//   C_j      = HMAC-SHA256(S_w, windowID || j)[0:8]
//   R_IDj    = HMAC-SHA256(C_j, ID_utf8)[0:8]
//   peerW    = HMAC-SHA256(PK_s_raw32, windowID)[0:8]
//   Sig_p(j) = Sign(SK_p, sessionID || windowID || j || C_j)
//   Sig_s    = Sign(SK_s, sessionID || windowID || j || C_j || ID_utf8 || faceMilliBE16)
//   Sig_ack  = Sign(SK_p, sessionID || windowID || j || ID_utf8 || decision_u8 || serverTimeMs_BE64)
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto_sync;
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import 'bytes.dart';
import 'constants.dart';

class ProxCrypto {
  ProxCrypto._();

  // ---------------------------------------------------------------- HMAC ---

  /// Sync 64-bit truncation (hot path: 500 HMACs per sighting batch).
  static Uint8List _hmacSha256Sync(List<int> key, List<int> msg) {
    final h = crypto_sync.Hmac(crypto_sync.sha256, key);
    return Uint8List.fromList(h.convert(msg).bytes);
  }

  /// Sub-epoch index canonical: u32 BE. Rotation is unbounded (the window
  /// closes only when the professor stops it), so the old single-byte j
  /// (wraps at 256 ≈ 21 min) would alias challenges mid-lecture.
  static Uint8List j32(int j) {
    assert(j >= 0);
    final b = ByteData(4)..setUint32(0, j, Endian.big);
    return b.buffer.asUint8List();
  }

  /// C_j = HMAC-SHA256(S_w, windowID || j32)[0:8]. Sync hot path.
  static Uint8List challengeForSubEpoch(
      Uint8List windowSecret, Uint8List windowId, int j) {
    assert(windowSecret.length == kWindowSecretBytes);
    assert(windowId.length == kWindowIdBytes);
    final mac = _hmacSha256Sync(windowSecret, concat([windowId, j32(j)]));
    return Uint8List.fromList(mac.sublist(0, 8));
  }

  /// R_IDj = HMAC-SHA256(C_j, ID)[0:8].
  static Uint8List responseToken(Uint8List challenge, String studentId) {
    assert(challenge.length == kChallengeBytes);
    final mac = _hmacSha256Sync(challenge, utf8.encode(studentId));
    return Uint8List.fromList(mac.sublist(0, 8));
  }

  /// peerW(ID) = HMAC-SHA256(PK_s, windowID)[0:8] — rotating over-air alias.
  static Uint8List peerAlias(Uint8List studentPub32, Uint8List windowId) {
    assert(studentPub32.length == 32);
    assert(windowId.length == kWindowIdBytes);
    final mac = _hmacSha256Sync(studentPub32, windowId);
    return Uint8List.fromList(mac.sublist(0, 8));
  }

  /// SHA-256 via sync package.
  static Uint8List sha256Sync(List<int> data) =>
      Uint8List.fromList(crypto_sync.sha256.convert(data).bytes);

  // ------------------------------------------------------------- Ed25519 ---

  static ed.KeyPair generateEdKeypair() => ed.generateKey();

  static Uint8List sign(ed.PrivateKey sk, List<int> message) =>
      Uint8List.fromList(ed.sign(sk, Uint8List.fromList(message)));

  static bool verify(ed.PublicKey pk, List<int> message, List<int> sig64) {
    if (sig64.length != 64) return false;
    try {
      return ed.verify(pk, Uint8List.fromList(message), Uint8List.fromList(sig64));
    } catch (_) {
      return false;
    }
  }

  /// Sig_p(j) preimage: sessionID || windowID || j32 || C_j.
  static Uint8List profChallengePreimage({
    required Uint8List sessionId,
    required Uint8List windowId,
    required int j,
    required Uint8List challenge,
  }) =>
      concat([sessionId, windowId, j32(j), challenge]);

  static Uint8List signProfChallenge({
    required ed.PrivateKey profSk,
    required Uint8List sessionId,
    required Uint8List windowId,
    required int j,
    required Uint8List challenge,
  }) =>
      sign(
          profSk,
          profChallengePreimage(
              sessionId: sessionId,
              windowId: windowId,
              j: j,
              challenge: challenge));

  static bool verifyProfChallenge({
    required ed.PublicKey profPk,
    required Uint8List sessionId,
    required Uint8List windowId,
    required int j,
    required Uint8List challenge,
    required List<int> sig,
  }) =>
      verify(
          profPk,
          profChallengePreimage(
              sessionId: sessionId,
              windowId: windowId,
              j: j,
              challenge: challenge),
          sig);

  /// faceScore canonical: milli-units u16 BE (0..1000). Keeps Sig_s deterministic.
  static Uint8List faceMilliBe(double faceScore) {
    final m = (faceScore.clamp(0.0, 1.0) * 1000).round().clamp(0, 1000);
    final b = ByteData(2)..setUint16(0, m, Endian.big);
    return b.buffer.asUint8List();
  }

  /// Sig_s preimage: sessionID || windowID || j32 || C_j || ID || faceMilliBE.
  static Uint8List studentProvePreimage({
    required Uint8List sessionId,
    required Uint8List windowId,
    required int j,
    required Uint8List challenge,
    required String studentId,
    required double faceScore,
  }) =>
      concat([
        sessionId,
        windowId,
        j32(j),
        challenge,
        utf8.encode(studentId),
        faceMilliBe(faceScore),
      ]);

  static Uint8List signStudentProve({
    required ed.PrivateKey studentSk,
    required Uint8List sessionId,
    required Uint8List windowId,
    required int j,
    required Uint8List challenge,
    required String studentId,
    required double faceScore,
  }) =>
      sign(
          studentSk,
          studentProvePreimage(
              sessionId: sessionId,
              windowId: windowId,
              j: j,
              challenge: challenge,
              studentId: studentId,
              faceScore: faceScore));

  static bool verifyStudentProve({
    required ed.PublicKey studentPk,
    required Uint8List sessionId,
    required Uint8List windowId,
    required int j,
    required Uint8List challenge,
    required String studentId,
    required double faceScore,
    required List<int> sig,
  }) =>
      verify(
          studentPk,
          studentProvePreimage(
              sessionId: sessionId,
              windowId: windowId,
              j: j,
              challenge: challenge,
              studentId: studentId,
              faceScore: faceScore),
          sig);

  /// Sig_ack preimage: sessionID || windowID || j32 || ID || decision || serverMsBE64.
  /// decision: 0=confirmed, 1=late, 2=invalid.
  static Uint8List ackPreimage({
    required Uint8List sessionId,
    required Uint8List windowId,
    required int j,
    required String studentId,
    required int decision,
    required int serverTimeMs,
  }) {
    final t = ByteData(8)..setUint64(0, serverTimeMs, Endian.big);
    return concat([
      sessionId,
      windowId,
      j32(j),
      utf8.encode(studentId),
      [decision],
      t.buffer.asUint8List(),
    ]);
  }

  /// 3-char display code derived from windowID (Crockford base32, 15 bits).
  static String displayCode(Uint8List windowId) {
    assert(windowId.length == kWindowIdBytes);
    var acc = (windowId[0] << 8) | windowId[1];
    acc &= 0x7FFF; // 15 bits
    final a = kDisplayAlphabet.codeUnits;
    return String.fromCharCodes([
      a[(acc >> 10) & 31],
      a[(acc >> 5) & 31],
      a[acc & 31],
    ]);
  }

  /// Liveness prompt bound to challenge: C_j[0] & 1 ? blink : turn-head. §4.
  static String livenessPrompt(Uint8List challenge) =>
      (challenge[0] & 1) == 1 ? 'blink' : 'turn-head';
}
