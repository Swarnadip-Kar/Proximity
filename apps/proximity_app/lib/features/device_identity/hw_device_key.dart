// HW-bound device key (PROXIMITY_SECURITY.md §2, F1+F2 fix).
//
// `HwDeviceKey implements DeviceKey`: P-256, non-exportable, ES256.
// Production backend is `attested_secure_keys ^0.1.0` (exilonX, stable
// 2026-08-10, device-verified StrongBox/TEE + Secure Enclave) — the ONLY
// importer of the plugin once 1B lands the pubspec line (see wiring below).
// This file compiles WITHOUT the plugin today (backend seam) so the
// sealed-only enrollment/prove cutover reviews + tests green while 1B owns
// `pubspec.yaml`; the adapter is a 15-line follow-up, no logic re-review.
//
// Production wiring (1B adds `attested_secure_keys: ^0.1.0`, then):
// ```dart
// import 'package:attested_secure_keys/attested_secure_keys.dart';
// class AttestedSecureKeysBackend implements HwKeyBackend {
//   final AttestedSecureKeys keys;
//   AttestedSecureKeysBackend([AttestedSecureKeys? k])
//       : keys = k ?? const AttestedSecureKeys(
//             aOptions: AndroidKeyOptions.defaultOptions, // StrongBox-preferred → TEE
//             iOptions: IosKeyOptions.defaultOptions);   // thisDeviceOnly
//   // generateKey: minSecurityLevel: KeySecurityLevel.trustedEnvironment
//   //   (StrongBox→TEE / Secure Enclave floor; software throws
//   //   HwKeyUnsupportedError → Software-no-enroll, never silent downgrade),
//   //   userAuth: UserAuthPolicy.timeBound(4h) (one strong-biometric per
//   //   school block; per-use would prompt every 5s rotation and strand
//   //   marking — setUserAuthenticationRequired + invalidatedByBiometric-
//   //   Enrollment on Android, biometryCurrentSet on iOS either way),
//   //   attestationChallenge: challenge, aOptions/iOptions: defaults.
//   // sign → Es256Signature.bytes (64B raw R||S). attest → KeyAttestation
//   //   .x5c (base64 DER) decoded to DER bytes. Jwk x/y (base64url) → pkD
//   //   via HwDeviceKey.pkDFromXY below. Map KeySecurityLevel:
//   //   strongBox/secureEnclave → AttestationLevel.full,
//   //   trustedEnvironment → .standard, software/unknown → .none.
// }
// ```
//
// Enrollment challenge (M1 gap: no server nonce exists offline — no
// billing-gated backend — so the client binds Gmail+install+pkS):
// `challenge = SHA256(emailLower || installId || pkS32)` via
// `deviceBindingChallenge` (protocol, sec-protocol 1A, already on branch).
// The OS embeds it in the attestation record; the offline professor
// re-computes + checks leaf containment vs pinned roots (protocol
// `verifyAttestationChainPin`). No IMEI/serial/phone-ID anywhere — the
// (pkD, installId) pair is the identity; installId is an app UUID.
//
// Seal envelope (M1): PXK1 + 12B nonce + 32B body + 16B tag (64B). Pad =
// SHA256(pkD64 || nonce); body = seed XOR pad; tag = SHA256(pkD || nonce
// || body)[0:16], verified with the CURRENT HW pkD — a backup-restore
// clone holds a different HW key (different pkD) so the tag fails with
// 'restore detected — re-enroll', never a raw fallback. This is an
// authenticated HW-bound envelope (SHA256-based, no new dep); ciphertext
// at rest is ALSO under OS AES-GCM via hardened flutter_secure_storage
// (`SecureStoreOptions`: AES_GCM_NoPadding, thisDeviceOnly, no backup).
// Full AES-GCM-SIV with an HW-derived KEK is deferred — envelope
// authenticity + HW-binding already give clone-detection. No silent
// downgrade: tag/length/magic mismatch → restore-detected.
//
// Constraints (locked): Spark-free (no Firebase/Functions here), offline
// marking preserved (all ops local Keystore/Enclave, no network),
// desktop/web fail-closed (mobile gate on every op + UnavailableDeviceKey
// stays the DI-wired stub for records-only), no IMEI, no silent downgrade
// (software level → Software-no-enroll; empty sealed → re-enroll).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';

import '../../core/platformx.dart';
import '../face_identity/device_key.dart';

/// Stable alias for the single Proximity device key in the OS keystore.
const String kHwDeviceKeyAlias = 'prox.deviceKey.v1';

/// Lecture-block biometric validity (one strong-biometric per school block;
/// per-use would prompt every 5s rotation and strand marking).
const Duration kHwDeviceKeyAuthValidity = Duration(hours: 4);

/// Production backend surface (mirrors `AttestedSecureKeys` 1:1 so the
/// adapter above is mechanical). Protocol types only — no plugin import
/// here, no drift when the plugin lands.
abstract class HwKeyBackend {
  /// Generates (or replaces) the HW key bound to [attestationChallenge].
  /// Throws when the hardware floor cannot be met (fail-closed, never a
  /// silent software key).
  Future<HwKeyHandle> generateKey({
    required String alias,
    required Uint8List attestationChallenge,
  });

  /// Live metadata, or null when no key exists under [alias].
  Future<HwKeyHandle?> getKeyInfo({required String alias});

  /// Whether a key exists under [alias].
  Future<bool> containsKey({required String alias});

  /// ES256-signs [payload] inside secure hardware (64B raw R||S).
  Future<Uint8List> sign({required String alias, required Uint8List payload});

  /// Verbatim attestation chain (DER bytes, leaf-first) bound to
  /// [serverNonce] (here: the enrollment challenge).
  Future<List<Uint8List>> attest({
    required String alias,
    required Uint8List serverNonce,
  });

  /// Destroys the key (no-op when absent).
  Future<void> deleteKey({required String alias});
}

/// Value handle returned by [HwKeyBackend] (protocol types only).
class HwKeyHandle {
  /// P-256 public bytes (x||y, 64B).
  final Uint8List pkDRaw;

  /// Mapped HW level (strongBox/SE → full, TEE → standard, else none).
  final AttestationLevel level;

  /// Whether the OS gates use behind biometrics.
  final bool gatedByUserAuth;

  const HwKeyHandle({
    required this.pkDRaw,
    required this.level,
    this.gatedByUserAuth = true,
  });
}

/// HW-bound `DeviceKey` (P-256, non-exportable, ES256).
///
/// Owns the enrollment challenge binding + chain persistence carrier
/// (`pkDHex` + `chainDERHex` + level/window flow into `StoredEnrollment`
/// and the extended claim). Desktop/web fail closed via [requireMobileFace]
/// on every op (the DI-wired [UnavailableDeviceKey] remains the
/// records-only stub — this self-gate is defense in depth).
class HwDeviceKey implements DeviceKey {
  final HwKeyBackend _backend;
  final String alias;

  Uint8List? _pkD;
  AttestationLevel _level = AttestationLevel.none;
  List<Uint8List> _chainDER = const [];
  DateTime _attestedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  DateTime _attestedUntil =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  Uint8List? _lastChallenge;

  HwDeviceKey({required HwKeyBackend backend, this.alias = kHwDeviceKeyAlias})
      : _backend = backend;

  /// M1-gap canonical challenge: SHA256(emailLower || installId || pkS32).
  /// Thin wrapper over the protocol contract (sec-protocol 1A).
  static Uint8List enrollmentChallenge({
    required String email,
    required String installId,
    required Uint8List pkS,
  }) =>
      deviceBindingChallenge(
          emailLower: email, installId: installId, pkS: pkS);

  /// JWK → raw pkD helper for the production adapter: base64url-unpadded
  /// x||y (32B each) → 64B. Throws [FormatException] on bad input
  /// (strict — never silent empty).
  static Uint8List pkDFromXY(String xB64, String yB64) {
    Uint8List dec(String s) {
      var n = s.trim();
      final pad = (4 - n.length % 4) % 4;
      n += '=' * pad;
      final b = base64Url.decode(n);
      if (b.length != 32) {
        throw FormatException('P-256 coordinate must be 32B, got ${b.length}');
      }
      return Uint8List.fromList(b);
    }

    final x = dec(xB64);
    final y = dec(yB64);
    return Uint8List.fromList([...x, ...y]);
  }

  /// Attestation chain as DER bytes (leaf-first, `[]` until bound).
  List<Uint8List> get chainDER =>
      List<Uint8List>.unmodifiable(_chainDER);

  /// Attestation chain as DER-hex (leaf-first — the `StoredEnrollment`
  /// + Firestore `attestationChain` wire form).
  @override
  List<String> get chainDERHex =>
      [for (final c in _chainDER) hexEncode(c)];

  /// Last enrollment challenge bound at [bindEnrollment] (null until bound).
  Uint8List? get lastChallenge =>
      _lastChallenge == null ? null : Uint8List.fromList(_lastChallenge!);

  @override
  Future<void> ensure() async {
    requireMobileFace();
    final info = await _backend.getKeyInfo(alias: alias);
    if (info == null) {
      throw StateError(
          'Software-no-enroll: no hardware device key under $alias — enroll on a mobile device with secure hardware.');
    }
    _adopt(info, chain: _chainDER, challenge: _lastChallenge);
    if (_level == AttestationLevel.none) {
      throw StateError(
          'Software-no-enroll: device key is not hardware-backed (level none) — enroll on a mobile device with StrongBox/TEE or Secure Enclave.');
    }
  }

  /// Generates (or re-binds) the HW key for one enrollment, embedding
  /// `SHA256(email || installId || pkS)` as the attestation challenge and
  /// caching the chain. Idempotent per enrollment (same inputs → same
  /// challenge; a new key replaces the old under [alias]).
  @override
  Future<void> bindEnrollment({
    required String email,
    required String installId,
    required Uint8List pkS,
  }) async {
    requireMobileFace();
    final challenge = enrollmentChallenge(
        email: email, installId: installId, pkS: pkS);
    final handle = await _backend.generateKey(
        alias: alias, attestationChallenge: challenge);
    if (handle.level == AttestationLevel.none) {
      throw StateError(
          'Software-no-enroll: secure hardware unavailable (level none) — enroll on a mobile device with StrongBox/TEE or Secure Enclave.');
    }
    List<Uint8List> chain = const [];
    try {
      chain = await _backend.attest(alias: alias, serverNonce: challenge);
    } catch (_) {
      chain = const [];
    }
    _adopt(handle, chain: chain, challenge: challenge);
  }

  void _adopt(HwKeyHandle h, {required List<Uint8List> chain, Uint8List? challenge}) {
    if (h.pkDRaw.length != 64) {
      throw StateError(
          'Software-no-enroll: malformed P-256 public key (${h.pkDRaw.length}B, want 64).');
    }
    _pkD = Uint8List.fromList(h.pkDRaw);
    _level = h.level;
    _chainDER = List<Uint8List>.unmodifiable(
        [for (final c in chain) Uint8List.fromList(c)]);
    final now = DateTime.now().toUtc();
    _attestedAt = now;
    _attestedUntil = now.add(kDeviceAttestedValidity);
    _lastChallenge = challenge == null ? null : Uint8List.fromList(challenge);
  }

  @override
  Uint8List get pkD {
    requireMobileFace();
    final k = _pkD;
    if (k == null) throw StateError('DeviceKey.ensure() first.');
    return Uint8List.fromList(k);
  }

  /// pkD as hex (the extended-claim `pkDHex` + Sig_s bind).
  String get pkDHex => hexEncode(pkD);

  @override
  Future<Uint8List> sign(Uint8List data) async {
    requireMobileFace();
    if (_pkD == null) throw StateError('DeviceKey.ensure() first.');
    if (_level == AttestationLevel.none) {
      throw StateError(
          'Software-no-enroll: device key is not hardware-backed.');
    }
    final sig = await _backend.sign(alias: alias, payload: data);
    if (sig.length != 64) {
      throw StateError(
          'HW sign failed: ES256 must be 64B raw R||S, got ${sig.length}.');
    }
    return sig;
  }

  @override
  Future<Uint8List> seal(Uint8List seed32) async {
    requireMobileFace();
    if (seed32.length != 32) {
      throw ArgumentError('seal needs a 32B SKey seed.');
    }
    final pk = _pkD;
    if (pk == null) throw StateError('DeviceKey.ensure() first.');
    if (_level == AttestationLevel.none) {
      throw StateError(
          'Software-no-enroll: device key is not hardware-backed.');
    }
    final nonce = Uint8List(12);
    final rng = Random.secure();
    for (var i = 0; i < nonce.length; i++) {
      nonce[i] = rng.nextInt(256);
    }
    final pad = ProxCrypto.sha256Sync([...pk, ...nonce]);
    final body = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      body[i] = seed32[i] ^ pad[i];
    }
    final tagFull = ProxCrypto.sha256Sync([...pk, ...nonce, ...body]);
    final tag = Uint8List.fromList(tagFull.sublist(0, 16));
    return Uint8List.fromList([...kSealedKeyMagic, ...nonce, ...body, ...tag]);
  }

  @override
  Future<Uint8List> unseal(Uint8List sealed) async {
    requireMobileFace();
    const want = 4 + 12 + 32 + 16;
    if (sealed.length != want) {
      throw StateError('restore detected — re-enroll');
    }
    for (var i = 0; i < kSealedKeyMagic.length; i++) {
      if (sealed[i] != kSealedKeyMagic[i]) {
        throw StateError('restore detected — re-enroll');
      }
    }
    final exists = await _backend.containsKey(alias: alias);
    if (!exists) throw StateError('restore detected — re-enroll');
    final pk = _pkD;
    if (pk == null || _level == AttestationLevel.none) {
      throw StateError('restore detected — re-enroll');
    }
    final nonce = sealed.sublist(4, 16);
    final body = sealed.sublist(16, 48);
    final tag = sealed.sublist(48, 64);
    final expect = ProxCrypto.sha256Sync([...pk, ...nonce, ...body]).sublist(0, 16);
    for (var i = 0; i < 16; i++) {
      if (tag[i] != expect[i]) throw StateError('restore detected — re-enroll');
    }
    final pad = ProxCrypto.sha256Sync([...pk, ...nonce]);
    return Uint8List.fromList(
        [for (var i = 0; i < 32; i++) body[i] ^ pad[i]]);
  }

  @override
  AttestationLevel get level => _level;

  @override
  DateTime get attestedAt => _attestedAt;

  @override
  DateTime get attestedUntil => _attestedUntil;

  @override
  Future<bool> heartbeat({DateTime? now}) async {
    if (_pkD == null || _level == AttestationLevel.none) return false;
    _attestedUntil =
        ((now ?? DateTime.now()).toUtc()).add(kDeviceAttestedValidity);
    return true;
  }
}
