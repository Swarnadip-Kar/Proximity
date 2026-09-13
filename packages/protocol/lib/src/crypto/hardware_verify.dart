// Hardware trust crypto: P-256 ES256 verify + AES-GCM sealed envelopes.
//
// Pure Dart (via `pointycastle`) — no platform code, so the offline
// professor path (transport server) and the app HW key share one
// implementation. All three entry points are synchronous and fail closed
// (false / StateError, never throws on attacker input).
//
// P-256 verify: the DKey signs [ProxCrypto.deviceProvePreimage] with ES256
// (ECDSA P-256 + SHA-256 — the same hash the Android Keystore / Secure
// Enclave `attested_secure_keys` plugin applies). The professor recomputes
// the preimage and checks the 64B raw R||S here; the result feeds
// `evaluateDeviceProof` as `dSigValid` (never mere presence).
//
// AES-GCM seal: the SKey seed is wrapped under a random 256-bit DEK that
// lives ONLY in HW-backed secure storage (Android Keystore / iOS Keychain,
// this-device-only — the app layer owns the DEK store). The envelope below
// is ciphertext-only at rest: nonce reuse is impossible (fresh CSPRNG nonce
// per seal), tampering fails the GCM tag, and a backup-restore clone holds
// ciphertext whose DEK never migrated — unseal throws
// 'restore detected — re-enroll', never a raw fallback. No pkD-derived
// keystream anywhere (the old SHA256(pkD) envelope is deleted).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../bytes.dart';

/// Sealed-SKey envelope magic v2 (versioned so a format change fails closed
/// instead of decrypting garbage into a signing key). "PXK2".
const List<int> kHwSealMagic = [0x50, 0x58, 0x4B, 0x32];

/// AES-GCM-256 envelope layout: magic(4) + nonce(12) + ciphertext(32) +
/// tag(16) = 64B. Same length as the retired PXK1 envelope, so stored docs
/// keep their shape (old PXK1 blobs still fail closed on magic).
const int kHwSealEnvelopeBytes = 4 + 12 + 32 + 16;

ECDomainParameters _p256() => ECDomainParameters('prime256v1');

BigInt _beToBigInt(Uint8List bytes) =>
    BigInt.parse(hexEncode(bytes), radix: 16);

/// Verifies a 64B raw R||S ES256 signature over [preimage] with the 64B raw
/// x||y P-256 public key [pkDRaw64]. Returns false (never throws) on any
/// malformed input or crypto failure — callers fail closed.
bool verifyDeviceSignature({
  required Uint8List pkDRaw64,
  required Uint8List preimage,
  required Uint8List sig64,
}) {
  if (pkDRaw64.length != 64 || sig64.length != 64) return false;
  try {
    final domain = _p256();
    final q = domain.curve.decodePoint(
        Uint8List.fromList([0x04, ...pkDRaw64]));
    if (q == null) return false;
    final signer = ECDSASigner(SHA256Digest());
    signer.init(false, PublicKeyParameter(ECPublicKey(q, domain)));
    return signer.verifySignature(
        preimage,
        ECSignature(
          _beToBigInt(sig64.sublist(0, 32)),
          _beToBigInt(sig64.sublist(32, 64)),
        ));
  } catch (_) {
    return false;
  }
}

/// AAD domain tag for [buildSealAad] (M7 cross-protocol separation: this
/// AAD verifies only as a Proximity seal binding, never as a challenge).
const String kHwSealAadDomain = 'PROX-SEAL-AAD/v1';

Uint8List _aadU16be(int v) {
  final b = ByteData(2)..setUint16(0, v & 0xFFFF, Endian.big);
  return b.buffer.asUint8List();
}

/// Builds the AES-GCM AAD binding the seal to one enrollment (M7).
///
/// `domain || u16be(len(email)) || email || u16be(len(installId)) ||
/// installId || u16be(len(pkS)) || pkS || u16be(len(pkD)) || pkD` where
/// `email` is trimmed + lowercased UTF-8. Structure-only bytes (no
/// encryption, no attestation interpretation) passed as `aad` to
/// [sealWithDek]/[unsealWithDek] — a seal transplanted across
/// email/install/key fails the GCM tag as restore-detected. Legacy seals
/// used empty AAD and still verify with empty `aad` (compat); new seals
/// MUST pass this.
Uint8List buildSealAad({
  required String emailLower,
  required String installId,
  required Uint8List pkS,
  required Uint8List pkD,
}) {
  final emailB = utf8.encode(emailLower.trim().toLowerCase());
  final installB = utf8.encode(installId);
  return Uint8List.fromList([
    ...utf8.encode(kHwSealAadDomain),
    ..._aadU16be(emailB.length),
    ...emailB,
    ..._aadU16be(installB.length),
    ...installB,
    ..._aadU16be(pkS.length),
    ...pkS,
    ..._aadU16be(pkD.length),
    ...pkD,
  ]);
}

/// Seals a 32B SKey seed under [dek32] (AES-256-GCM, fresh random nonce).
/// Returns the 64B PXK2 envelope. Throws [ArgumentError] on bad key/seed
/// lengths (programmer error — never silently truncated).
///
/// [aad] binds the envelope to one enrollment (see [buildSealAad]); empty
/// (legacy) verifies only with empty on open. Mismatched AAD fails the GCM
/// tag → restore-detected, never a raw fallback.
Uint8List sealWithDek({
  required Uint8List dek32,
  required Uint8List seed32,
  Uint8List? nonce12,
  Random? rng,
  Uint8List? aad,
}) {
  if (dek32.length != 32) {
    throw ArgumentError('seal needs a 32B DEK.');
  }
  if (seed32.length != 32) {
    throw ArgumentError('seal needs a 32B SKey seed.');
  }
  final nonce = nonce12 ?? randBytes(12, rng ?? Random.secure());
  if (nonce.length != 12) {
    throw ArgumentError('seal needs a 12B nonce.');
  }
  final cipher = GCMBlockCipher(AESEngine());
  cipher.init(true, AEADParameters(KeyParameter(dek32), 128, nonce,
      aad ?? Uint8List(0)));
  final out = Uint8List(cipher.getOutputSize(seed32.length));
  var off = cipher.processBytes(seed32, 0, seed32.length, out, 0);
  off += cipher.doFinal(out, off);
  // GCM output is ciphertext(32) + tag(16) for a 32B input.
  if (off != 48) {
    throw StateError('AES-GCM seal produced an unexpected shape.');
  }
  return Uint8List.fromList([...kHwSealMagic, ...nonce, ...out]);
}

/// Unseals a PXK2 envelope under [dek32]. Any failure — magic, length, GCM
/// tag (including AAD mismatch), missing key — throws
/// StateError('restore detected — re-enroll'):
/// a backup-restore clone carries ciphertext whose DEK never migrated, so
/// it fails exactly like tampering (fail closed, never a raw fallback).
/// [aad] must equal the seal-time value (empty for legacy seals).
Uint8List unsealWithDek({
  required Uint8List dek32,
  required Uint8List sealed,
  Uint8List? aad,
}) {
  if (sealed.length != kHwSealEnvelopeBytes) {
    throw StateError('restore detected — re-enroll');
  }
  for (var i = 0; i < kHwSealMagic.length; i++) {
    if (sealed[i] != kHwSealMagic[i]) {
      throw StateError('restore detected — re-enroll');
    }
  }
  if (dek32.length != 32) {
    throw StateError('restore detected — re-enroll');
  }
  try {
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
        false,
        AEADParameters(KeyParameter(dek32), 128,
            sealed.sublist(4, 16), aad ?? Uint8List(0)));
    final out = Uint8List(cipher.getOutputSize(48));
    var off = cipher.processBytes(sealed, 16, 48, out, 0);
    off += cipher.doFinal(out, off);
    if (off != 32) throw StateError('bad envelope');
    return Uint8List.fromList(out.sublist(0, off));
  } catch (_) {
    throw StateError('restore detected — re-enroll');
  }
}
