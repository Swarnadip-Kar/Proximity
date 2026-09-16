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
//   Sig_s    = Sign(SK_s, sessionID || windowID || j || C_j || ID_utf8 ||
//                     faceMilliBE16 || faceValidAtMsBE64 || verifierVerHash8 ||
//                     pkD32 || faceTicketHash8)
//              (Tracks 2+3: plugin reality wins — no images/embeddings leave
//              the device; the host verifies PK_s sig, C_j/single-use/
//              freshness (unchanged), score>=T + faceValid window +
//              verifierVer allowlist, BLE sighting (unchanged), signed ACK
//              (unchanged) + attestation anomaly flags. Sig_p/ACK layouts
//              and all crypto primitives are untouched.)
//   faceTicketHash8 (security §4, sec-protocol 1A):
//              SHA-256(scoreMilliBE16 || faceValidAtBE64 || verifierVerHash8
//                      || livenessMilliBE16 || livenessVerHash8)[0:8].
//              Sig_s AND dSig bind this hash, so the liveness classifier
//              output (score + pipeline version) is transplant-proof. The
//              preimage is LONGER than the pre-liveness 3-field form, so old
//              tickets/sigs never verify against it and vice versa — the
//              host fails them as `bad-sig`/`liveness-unbound`, never as a
//              silent downgrade.
//   Sig_ack  = Sign(SK_p, sessionID || windowID || j || ID_utf8 || decision_u8 || serverTimeMs_BE64)
//   Sig_d    = Sign(DKey_P256, sessionID || windowID || j || C_j ||
//                     faceTicketHash8 || pkS32 || integrityHashUtf8)
//              (security §5: the 8-hex verdict hash rides the SIGNED dSig
//              preimage, so a clean-device dSig can never be transplanted
//              onto a tainted prove, nor a pre-binding dSig onto a bound
//              proof — old preimages omit the trailing field and fail.)
//
// class stays contiguous here on purpose — Dart cannot split one class's
// statics across files without delegation indirection, which would add
// drift risk to the security-critical preimages. The member preimages
// (prof/student/ack) therefore live here, not in preimages.dart; that
// file holds only the top-level channel-binding preimage.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto_sync;
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import '../bytes.dart';
import '../constants.dart';

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

  /// faceValidAt canonical: UTC epoch millis u64 BE. Binds WHEN the
  /// on-device match happened (host enforces the faceValid window + flags
  /// future/reused stamps — see verify.dart anomaly flags).
  static Uint8List faceValidAtBe(int faceValidAtMs) {
    final b = ByteData(8)..setUint64(0, faceValidAtMs, Endian.big);
    return b.buffer.asUint8List();
  }

  /// verifierVer binding: SHA-256(utf8(verifierVer))[0:8]. Binds WHICH
  /// pipeline produced the score (host checks the allowlist; flapping
  /// across proves is flagged post-hoc). 8 bytes keep Sig_s compact.
  static Uint8List verifierVerHash8(String verifierVer) =>
      Uint8List.fromList(sha256Sync(utf8.encode(verifierVer)).sublist(0, 8));

  /// Liveness score canonical: milli-units u16 BE (0..1000), same scale
  /// as [faceMilliBe]. Keeps the ticket deterministic. The classifier
  /// (security §4 `LivenessGate.detect`) emits 0..1; the host gates
  /// `>= kLivenessThreshold` (see crypto/verify.dart).
  static Uint8List livenessMilliBe(double livenessScore) {
    final m = (livenessScore.clamp(0.0, 1.0) * 1000).round().clamp(0, 1000);
    final b = ByteData(2)..setUint16(0, m, Endian.big);
    return b.buffer.asUint8List();
  }

  /// Liveness pipeline binding: SHA-256(utf8(livenessVer))[0:8]. Binds
  /// WHICH anti-spoof pipeline produced the score (host checks the
  /// liveness allowlist; unknown versions fail closed). 8 bytes keep the
  /// ticket compact. Empty string = unbound (legacy / pre-liveness).
  static Uint8List livenessVerHash8(String livenessVer) =>
      Uint8List.fromList(sha256Sync(utf8.encode(livenessVer)).sublist(0, 8));

  /// Face+liveness ticket hash (security §4):
  /// SHA-256(scoreMilliBE16 || faceValidAtBE64 || verifierVerHash8 ||
  /// livenessMilliBE16 || livenessVerHash8)[0:8].
  ///
  /// The ticket (score, faceValidAt, verifierVer, livenessScore,
  /// livenessVer) travels in POST /prove `face:{...}` (+ `liveness:{...}`;
  /// no images/embeddings leave the device); its hash binds into Sig_s AND
  /// into dSig so neither signature can be transplanted across tickets or
  /// across liveness outputs.
  ///
  /// No-silent-downgrade: the preimage is LONGER than the pre-liveness
  /// 3-field form (score||faceValidAt||verifierVerHash8), so a ticket hash
  /// computed without liveness NEVER equals one computed with liveness,
  /// and old signatures never verify against the extended preimage (host
  /// fails them `bad-sig` / `liveness-unbound`).
  ///
  /// Migration: [livenessScore]/[livenessVer] default to neutral (0.0/'')
  /// so pre-liveness call sites still compile — but the PREIMAGE itself is
  /// extended, and the host (verify.dart bound path) requires a non-zero
  /// liveness score + allowlisted livenessVer. Defaults exist only to keep
  /// the migration compilable, never to accept legacy proofs at runtime.
  static Uint8List faceTicketHash({
    required double faceScore,
    required int faceValidAtMs,
    required String verifierVer,
    double livenessScore = 0.0,
    String livenessVer = '',
  }) =>
      Uint8List.fromList(sha256Sync(concat([
        faceMilliBe(faceScore),
        faceValidAtBe(faceValidAtMs),
        verifierVerHash8(verifierVer),
        livenessMilliBe(livenessScore),
        livenessVerHash8(livenessVer),
      ])).sublist(0, 8));

  /// Sig_s preimage (Tracks 2+3 extended + security §4 liveness):
  /// sessionID || windowID || j32 || C_j || ID || faceMilliBE ||
  /// faceValidAtBE || verifierVerHash8 || pkD32 || faceTicketHash8,
  /// where faceTicketHash8 already binds
  /// (score||faceValidAt||verifierVerHash8||livenessMilli||livenessVerHash8).
  ///
  /// Backward-compatible call shape: the new fields default to neutral
  /// (epoch 0, empty verifier, empty pkD/ticket, liveness 0.0/'') so
  /// pre-existing call sites still compile — but the PREIMAGE itself is
  /// extended (longer than the old 6-field form AND longer than the
  /// pre-liveness ticket form), so old signatures never verify against
  /// the new preimage and vice versa. Legacy/liveness-less defaults exist
  /// only to keep the migration compilable, never to accept legacy proofs
  /// at runtime (the host requires a non-zero faceValidAt + allowlisted
  /// verifierVer + livenessScore >= Tl + allowlisted livenessVer).
  static Uint8List studentProvePreimage({
    required Uint8List sessionId,
    required Uint8List windowId,
    required int j,
    required Uint8List challenge,
    required String studentId,
    required double faceScore,
    int faceValidAtMs = 0,
    String verifierVer = '',
    Uint8List? pkD,
    Uint8List? faceTicketHashBytes,
    double livenessScore = 0.0,
    String livenessVer = '',
  }) {
    final d = pkD ?? Uint8List(0);
    final t = faceTicketHashBytes ??
        faceTicketHash(
            faceScore: faceScore,
            faceValidAtMs: faceValidAtMs,
            verifierVer: verifierVer,
            livenessScore: livenessScore,
            livenessVer: livenessVer);
    return concat([
      sessionId,
      windowId,
      j32(j),
      challenge,
      utf8.encode(studentId),
      faceMilliBe(faceScore),
      faceValidAtBe(faceValidAtMs),
      verifierVerHash8(verifierVer),
      d,
      t,
    ]);
  }

  static Uint8List signStudentProve({
    required ed.PrivateKey studentSk,
    required Uint8List sessionId,
    required Uint8List windowId,
    required int j,
    required Uint8List challenge,
    required String studentId,
    required double faceScore,
    int faceValidAtMs = 0,
    String verifierVer = '',
    Uint8List? pkD,
    Uint8List? faceTicketHashBytes,
    double livenessScore = 0.0,
    String livenessVer = '',
  }) =>
      sign(
          studentSk,
          studentProvePreimage(
              sessionId: sessionId,
              windowId: windowId,
              j: j,
              challenge: challenge,
              studentId: studentId,
              faceScore: faceScore,
              faceValidAtMs: faceValidAtMs,
              verifierVer: verifierVer,
              pkD: pkD,
              faceTicketHashBytes: faceTicketHashBytes,
              livenessScore: livenessScore,
              livenessVer: livenessVer));

  static bool verifyStudentProve({
    required ed.PublicKey studentPk,
    required Uint8List sessionId,
    required Uint8List windowId,
    required int j,
    required Uint8List challenge,
    required String studentId,
    required double faceScore,
    required List<int> sig,
    int faceValidAtMs = 0,
    String verifierVer = '',
    Uint8List? pkD,
    Uint8List? faceTicketHashBytes,
    double livenessScore = 0.0,
    String livenessVer = '',
  }) =>
      verify(
          studentPk,
          studentProvePreimage(
              sessionId: sessionId,
              windowId: windowId,
              j: j,
              challenge: challenge,
              studentId: studentId,
              faceScore: faceScore,
              faceValidAtMs: faceValidAtMs,
              verifierVer: verifierVer,
              pkD: pkD,
              faceTicketHashBytes: faceTicketHashBytes,
              livenessScore: livenessScore,
              livenessVer: livenessVer),
          sig);

  /// Sig_d (device-key) preimage: sessionID || windowID || j32 || C_j ||
  /// faceTicketHash8 || pkS32 || integrityHashUtf8. Signed by DKey (P-256
  /// HW: StrongBox→TEE / Secure Enclave; `none` stub on desktop/web). The
  /// P-256 verify itself lives in the platform adapter (app layer) — this
  /// canonical preimage is the shared contract both sides sign/verify
  /// against.
  ///
  /// Security §4: [faceTicketHashBytes] MUST be the extended 5-field ticket
  /// (score||faceValidAt||verifierVerHash8||livenessMilli||livenessVerHash8).
  /// Changing the liveness score/ver changes the ticket, which changes this
  /// preimage — dSig is transplant-proof across liveness outputs. Old
  /// 3-field tickets produce a different preimage and fail dSig verify
  /// (no silent downgrade).
  ///
  /// Security §5: [integrityHash] is the 8-hex verdict hash
  /// (`IntegrityGate.verdictHashOf`, app layer) bound into dSig, so the
  /// device-integrity verdict a prove CLAIMED is the one the HW key
  /// SIGNED — a clean-device dSig can never be transplanted onto a
  /// tainted prove. The trailing field defaults to '' only so pre-binding
  /// call sites still compile; the transport server requires a non-empty
  /// hash on every dSig-gated (FULL/STD) proof, and a pre-binding dSig
  /// (no trailing field) never equals a bound preimage — it fails dSig
  /// verify, never a silent downgrade.
  static Uint8List deviceProvePreimage({
    required Uint8List sessionId,
    required Uint8List windowId,
    required int j,
    required Uint8List challenge,
    required Uint8List faceTicketHashBytes,
    required Uint8List pkS,
    String integrityHash = '',
  }) {
    // Fixed-size fields keep the concat unambiguous (P-256 contract:
    // the HW DKey signs exactly these bytes with ES256 — see
    // crypto/hardware_verify.dart verifyDeviceSignature).
    assert(faceTicketHashBytes.length == 8);
    assert(pkS.length == 32);
    return concat([
      sessionId,
      windowId,
      j32(j),
      challenge,
      faceTicketHashBytes,
      pkS,
      utf8.encode(integrityHash),
    ]);
  }

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
  /// DEPRECATED (Tracks 2+3): the plugin path is PASSIVE-only — no
  /// blink/turn-head prompts are ever shown. Kept (not deleted) so the
  /// historical crypto_test vector still compiles; no production caller
  /// may use it (FaceVerifier.verify takes no prompt).
  @Deprecated('Tracks 2+3 passive-only: no liveness prompts. Do not call.')
  static String livenessPrompt(Uint8List challenge) =>
      (challenge[0] & 1) == 1 ? 'blink' : 'turn-head';
}
