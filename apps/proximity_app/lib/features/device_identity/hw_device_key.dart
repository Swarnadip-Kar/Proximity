// HW-bound device key (PROXIMITY_SECURITY.md §2, F1+F2 fix).
//
// `HwDeviceKey implements DeviceKey`: P-256, non-exportable, ES256, backed
// by `attested_secure_keys ^0.1.1` (StrongBox→TEE / Secure Enclave) via
// [AttestedSecureKeysBackend] below — the ONLY importer of the plugin.
//
// Backend contract (see the plugin facade
// `AttestedSecureKeys.generateKey/sign/attest/getKeyInfo`):
// - generateKey: minSecurityLevel `trustedEnvironment` (the CORRECT floor:
//   StrongBox is opportunistic — the plugin tries StrongBox first and falls
//   back to TEE where StrongBox is absent, so requiring StrongBox would
//   brick TEE-only phones; `trustedEnvironment` accepts StrongBox→TEE /
//   Secure Enclave and anything lower throws `HwKeyUnsupportedError` →
//   `Software-no-enroll`, never a silent software key), userAuth
//   `UserAuthPolicy.timeBound(4h)` (= [kHwDeviceKeyAuthValidity]: one
//   strong-biometric per school block; per-use would prompt every 10s
//   rotation and strand marking),
//   attestationChallenge = the enrollment challenge
//   (`SHA256(emailLower || installId || pkS32)` via [enrollmentChallenge]).
// - pkD wire form: HW 64B P-256 x||y (JWK x/y 32B each via
//   `HwDeviceKey.pkDFromXY`) vs Software 32B Ed25519 — callers treat pkD as
//   opaque variable-length (hexEncode + hash fingerprint only, never a
//   fixed slice/length gate).
// - sign → `Es256Signature.bytes` (64B raw R||S).
// - attest → `KeyAttestation.x5c` (base64 DER, leaf-first) decoded to DER
//   bytes. JWK x/y (base64url) → pkD via [HwDeviceKey.pkDFromXY].
// - Level map: strongBox/secureEnclave → `AttestationLevel.full`,
//   trustedEnvironment → `.standard`, software/unknown → `.none` (and
//   `.none` throws `Software-no-enroll`, never enrolls).
// - Attest failure MUST throw (never an empty-chain proceed): enrollment
//   catches `StateError`, so every attest error is wrapped as one.
//
// Enrollment challenge (M1 gap: no server nonce exists offline — no
// billing-gated backend — so the client binds Gmail+install+pkS):
// `challenge = SHA256(emailLower || installId || pkS32)` via
// `deviceBindingChallenge` (protocol). The OS embeds it in the attestation
// record; the offline professor re-computes + checks leaf containment vs
// pinned roots (protocol `verifyAttestationChainPin`). No IMEI/serial/
// phone-ID anywhere — the (pkD, installId) pair is the identity; installId
// is an app UUID.
//
// Seal envelope (PXK2): AES-256-GCM under a random per-device DEK that
// lives ONLY in HW-backed secure storage ([HwSealStore] — Android Keystore
// / iOS Keychain, this-device-only). Layout magic(4) + nonce(12) +
// ciphertext(32) + tag(16) = 64B (protocol `sealWithDek`/`unsealWithDek`).
// No pkD-derived keystream anywhere: the retired SHA256(pkD) envelope is
// deleted. A backup-restore clone holds ciphertext whose DEK never
// migrated (Keystore/Keychain keys are non-exportable and this-device-only)
// so unseal fails the GCM tag with 'restore detected — re-enroll', never a
// raw fallback. Tag/length/magic mismatch → restore-detected.
//
// Constraints (locked): offline marking preserved (all ops local
// Keystore/Enclave, no network), desktop/web fail-closed (mobile gate on
// every op + UnavailableDeviceKey stays the DI-wired stub for
// records-only), no IMEI, no silent downgrade (software level →
// Software-no-enroll; empty sealed → re-enroll).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:attested_secure_keys/attested_secure_keys.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:proximity_protocol/protocol.dart';

import '../../core/platformx.dart';
import '../face_identity/device_key.dart';

/// Stable alias for the single Proximity device key in the OS keystore.
const String kHwDeviceKeyAlias = 'prox.deviceKey.v1';

/// DEK storage version (M7): the seal DEK is keyed `$alias.dek.$version`
/// so a future DEK format rolls to a new versioned entry instead of
/// silently reusing one DEK forever. Rotation = generate under the next
/// version + re-seal the live SKey (unseal old, seal new) or full
/// re-enroll; the old versioned entry is deleted after the re-seal
/// commits. Never auto-rotate without a re-seal — an unsealable envelope
/// is worse than an old DEK.
const String kHwSealDekVersion = 'v1';

/// Lecture-block biometric validity (one strong-biometric per school block;
/// per-use would prompt every 10s rotation and strand marking).
const Duration kHwDeviceKeyAuthValidity = Duration(hours: 4);

/// Production backend surface (mirrors `AttestedSecureKeys` 1:1 so the
/// adapter stays mechanical). Protocol types only — no plugin import
/// here, no drift when the plugin revs.
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

  /// Verbatim attestation artifact bound to [serverNonce] (here: the
  /// enrollment challenge). MUST throw when no artifact can be produced
  /// (never an empty proceed — see [HwAttestation]).
  Future<HwAttestation> attest({
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

  /// Mapped HW level (strongBox → full, TEE → standard, Secure Enclave →
  /// standard on iOS (App Attest standard assertion — see the iOS note on
  /// [AttestedSecureKeysBackend]), else none).
  final AttestationLevel level;

  /// Whether the OS gates use behind biometrics.
  final bool gatedByUserAuth;

  const HwKeyHandle({
    required this.pkDRaw,
    required this.level,
    this.gatedByUserAuth = true,
  });
}

/// Verbatim attestation artifact returned by [HwKeyBackend.attest].
///
/// Android carries an X.509 chain ([chainDER] from x5c, Apple fields null).
/// iOS carries the App Attest CBOR ([appAttestRaw]) whose x5c (first
/// registration per install) is decoded into [chainDER]; later calls on
/// the same install yield assertion CBOR ([chainDER] empty —
/// [HwDeviceKey.bindEnrollment] carries the enrollment credential key
/// forward for that path). Sealed bytes are never decrypted — structure
/// and bindings only.
class HwAttestation {
  /// Chain DER bytes, leaf-first ([] until bound / assertion path).
  final List<Uint8List> chainDER;

  /// Apple CBOR raw (attestation object or assertion), null on Android.
  final Uint8List? appAttestRaw;

  /// authData parsed from [appAttestRaw] (Apple only, null on Android).
  final Uint8List? appAttestAuthData;

  /// Credential public key x‖y (64B) from the attestation object
  /// (Apple first-registration path; null on Android + assertion path).
  final Uint8List? appAttestCredKey;

  /// True when the artifact is Apple App Attest CBOR (either shape).
  final bool isApple;

  const HwAttestation({
    this.chainDER = const [],
    this.appAttestRaw,
    this.appAttestAuthData,
    this.appAttestCredKey,
    this.isApple = false,
  });
}

/// Maps a plugin [KeySecurityLevel] to the protocol [AttestationLevel]:
/// strongBox/secureEnclave → full, trustedEnvironment → standard,
/// software/unknown → none (callers throw `Software-no-enroll` on none).
/// iOS callers pass the result through [_iosTier] (SE + App Attest proves
/// at the standard tier — the backend applies it centrally).
AttestationLevel mapKeySecurityLevel(KeySecurityLevel level) =>
    switch (level) {
      KeySecurityLevel.strongBox => AttestationLevel.full,
      KeySecurityLevel.secureEnclave => AttestationLevel.full,
      KeySecurityLevel.trustedEnvironment => AttestationLevel.standard,
      KeySecurityLevel.software => AttestationLevel.none,
      KeySecurityLevel.unknown => AttestationLevel.none,
    };

/// iOS tier rule: a Secure Enclave key proves via App Attest (standard
/// assertion — see the `AttestationLevel.standard` docs), so SE tiers STD
/// on iOS; Android keeps StrongBox→FULL / TEE→STD. Centralized so
/// generateKey/getKeyInfo/ensure agree on every path (the professor iOS
/// branch requires STD — see protocol `verifyAppAttestChainPin`).
AttestationLevel _iosTier(AttestationLevel level) =>
    (isIOS && level == AttestationLevel.full)
        ? AttestationLevel.standard
        : level;

/// Production [HwKeyBackend] over `attested_secure_keys` (StrongBox→TEE /
/// Secure Enclave, ES256, challenge-bound). The ONLY importer of the
/// plugin: every op throws its native errors through (no swallowing) —
/// [HwDeviceKey] maps the fail-closed cases to `StateError`.
class AttestedSecureKeysBackend implements HwKeyBackend {
  final AttestedSecureKeys keys;

  AttestedSecureKeysBackend([AttestedSecureKeys? keys])
      : keys = keys ??
            const AttestedSecureKeys(
              aOptions: AndroidKeyOptions.defaultOptions,
              iOptions: IosKeyOptions.defaultOptions,
            );

  @override
  Future<HwKeyHandle> generateKey({
    required String alias,
    required Uint8List attestationChallenge,
  }) async {
    if (attestationChallenge.isEmpty) {
      throw ArgumentError('attestationChallenge must not be empty.');
    }
    late final HwKey key;
    try {
      key = await keys.generateKey(
        alias: alias,
        minSecurityLevel: KeySecurityLevel.trustedEnvironment,
        userAuth:
            const UserAuthPolicy.timeBound(kHwDeviceKeyAuthValidity),
        attestationChallenge: attestationChallenge,
      );
    } on HwKeyUnsupportedError catch (e) {
      throw StateError(
          'Software-no-enroll: secure hardware unavailable (${e.bestAvailable ?? 'none'}) — enroll on a mobile device with StrongBox/TEE or Secure Enclave.');
    }
    final level = _iosTier(mapKeySecurityLevel(key.effectiveLevel));
    if (level == AttestationLevel.none || !key.isHardwareBacked) {
      throw StateError(
          'Software-no-enroll: device key is not hardware-backed (level ${key.effectiveLevel.name}) — enroll on a mobile device with StrongBox/TEE or Secure Enclave.');
    }
    return HwKeyHandle(
      pkDRaw: HwDeviceKey.pkDFromXY(
          key.publicJwk.x, key.publicJwk.y),
      level: level,
      gatedByUserAuth: key.gatedByUserAuth,
    );
  }

  @override
  Future<HwKeyHandle?> getKeyInfo({required String alias}) async {
    final info = await keys.getKeyInfo(alias: alias);
    if (info == null) return null;
    return HwKeyHandle(
      pkDRaw: HwDeviceKey.pkDFromXY(
          info.publicJwk.x, info.publicJwk.y),
      level: _iosTier(mapKeySecurityLevel(info.securityLevel)),
      gatedByUserAuth: info.gatedByUserAuth,
    );
  }

  @override
  Future<bool> containsKey({required String alias}) =>
      keys.containsKey(alias: alias);

  @override
  Future<Uint8List> sign({
    required String alias,
    required Uint8List payload,
  }) async {
    // Biometric-gated keys throw UserNotAuthenticatedError here when the
    // 4h grant lapsed — propagates so the UI re-prompts (never swallowed).
    final sig = await keys.sign(alias: alias, payload: payload);
    return Uint8List.fromList(sig.bytes);
  }

  /// Pure x5c decoder (test seam for the DER-shape guard): standard
  /// base64 → DER bytes. Rejects empty bodies and non-DER (must open with
  /// the ASN.1 SEQUENCE tag 0x30) as [StateError] fail-closed — a
  /// successful decode of garbage must never flow into chain verification
  /// with a misleading reason. Decode failures surface as [FormatException]
  /// (fail-closed via the [bindEnrollment] wrap, same as before).
  static List<Uint8List> decodeX5c(List<String> x5c) {
    final out = <Uint8List>[];
    for (final b64 in x5c) {
      final b = base64.decode(b64.trim());
      if (b.isEmpty || b[0] != 0x30) {
        throw StateError('bad attestation DER (fail-closed).');
      }
      out.add(Uint8List.fromList(b));
    }
    if (out.isEmpty) {
      throw StateError('empty attestation chain (fail-closed).');
    }
    return out;
  }

  @override
  Future<HwAttestation> attest({
    required String alias,
    required Uint8List serverNonce,
  }) async {
    // AttestationUnavailableError (and any platform failure) propagates —
    // [HwDeviceKey.bindEnrollment] wraps it as StateError (fail-closed).
    final attestation =
        await keys.attest(alias: alias, serverNonce: serverNonce);
    final t = attestation.type;
    if (t == KeyAttestationType.appleAppAttest ||
        t == KeyAttestationType.appleAppAssert) {
      return attestApple(attestation.raw);
    }
    return HwAttestation(chainDER: decodeX5c(attestation.x5c));
  }

  /// Apple CBOR branch (test seam: pure parse over plugin `raw` bytes).
  /// Attestation objects yield the x5c chain + authData + credential key;
  /// assertions yield authData with an empty chain (the credential key
  /// rides forward from the previous enrollment — see
  /// [HwDeviceKey.bindEnrollment]). Throws [StateError] on missing or
  /// malformed CBOR (fail-closed, same as the Android empty-chain path).
  static HwAttestation attestApple(Uint8List? raw) {
    if (raw == null || raw.isEmpty) {
      throw StateError('empty App Attest artifact (fail-closed).');
    }
    late final ParsedAppAttestRaw parsed;
    try {
      parsed = ParsedAppAttestRaw.parse(raw);
    } catch (e) {
      throw StateError('bad App Attest CBOR (fail-closed).');
    }
    if (parsed.kind == AppAttestRawKind.attestationObject) {
      for (final c in parsed.x5c) {
        if (c.isEmpty || c[0] != 0x30) {
          throw StateError('bad App Attest DER (fail-closed).');
        }
      }
      late final Uint8List credKey;
      try {
        credKey = extractAppAttestCredentialKey(parsed.authData);
      } catch (_) {
        throw StateError('bad App Attest authData (fail-closed).');
      }
      return HwAttestation(
        chainDER: [
          for (final c in parsed.x5c) Uint8List.fromList(c),
        ],
        appAttestRaw: Uint8List.fromList(raw),
        appAttestAuthData: Uint8List.fromList(parsed.authData),
        appAttestCredKey: credKey,
        isApple: true,
      );
    }
    return HwAttestation(
      appAttestRaw: Uint8List.fromList(raw),
      appAttestAuthData: Uint8List.fromList(parsed.authData),
      isApple: true,
    );
  }

  @override
  Future<void> deleteKey({required String alias}) =>
      keys.deleteKey(alias: alias);
}

/// HW-bound DEK store for the AES-GCM seal envelope.
///
/// The 32B DEK lives ONLY here (never in Firestore, never in the sealed
/// blob): Android Keystore-backed AES-GCM storage / iOS Keychain
/// this-device-only, with NO per-use biometric prompt (use is already gated
/// by the 4h HW-key grant + the face check; a per-read prompt would strand
/// every 10s prove rotation). A backup-restore clone loses the DEK
/// (Keystore/Keychain keys never migrate) so unseal fails closed.
abstract class HwSealStore {
  /// Stored DEK, or null when absent (fresh install / wiped storage).
  /// Malformed entries read as null (never a half key).
  Future<Uint8List?> readDek({required String alias});

  /// Persists [dek32] (must be 32B).
  Future<void> writeDek(
      {required String alias, required Uint8List dek32});

  /// Drops the DEK (re-enroll flows).
  Future<void> deleteDek({required String alias});
}

/// Production [HwSealStore] over `flutter_secure_storage` (already a direct
/// app dep; prompt-free hardened options — NOT the biometric-gated
/// `SecureStoreOptions.storage`, which would prompt on every prove).
class FlutterSealStore implements HwSealStore {
  final FlutterSecureStorage storage;

  const FlutterSealStore(
      [this.storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(),
        iOptions: IOSOptions(
          synchronizable: false,
          accessibility:
              KeychainAccessibility.first_unlock_this_device,
        ),
      )]);

  /// FSS key for the DEK of [alias] (versioned — see [kHwSealDekVersion]).
  static String keyFor(String alias) => '$alias.dek.$kHwSealDekVersion';

  /// Legacy (unversioned) FSS key, read-only migration source: installs
  /// sealed before versioning carry `$alias.dek`. [readDek] migrates a
  /// legacy hit to the versioned key on first read (write-through), so at
  /// most one envelope generation ever reuses the pre-version DEK.
  @visibleForTesting
  static String legacyKeyFor(String alias) => '$alias.dek';

  @override
  Future<Uint8List?> readDek({required String alias}) async {
    final cur = await storage.read(key: keyFor(alias));
    if (cur != null && cur.trim().isNotEmpty) {
      try {
        final dek = hexDecode(cur.trim());
        if (dek.length == 32) return dek;
      } catch (_) {}
    }
    // One-shot legacy migration (M7): unversioned → versioned.
    String? legacy;
    try {
      legacy = await storage.read(key: legacyKeyFor(alias));
    } catch (_) {
      legacy = null;
    }
    if (legacy == null || legacy.trim().isEmpty) return null;
    try {
      final dek = hexDecode(legacy.trim());
      if (dek.length != 32) return null;
      try {
        await storage.write(key: keyFor(alias), value: hexEncode(dek));
      } catch (_) {}
      return dek;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeDek(
      {required String alias, required Uint8List dek32}) async {
    if (dek32.length != 32) {
      throw ArgumentError('DEK must be 32B.');
    }
    await storage.write(key: keyFor(alias), value: hexEncode(dek32));
  }

  @override
  Future<void> deleteDek({required String alias}) async {
    await storage.delete(key: keyFor(alias));
  }
}

/// True when [e] reports OS-level key invalidation (biometric/credential
/// set changed): Android `KeyPermanentlyInvalidatedException` / plugin
/// `KeyInvalidatedError`, iOS repeated-auth-failure-after-change.
/// Message-based so this file stays decoupled from plugin error classes.
/// `UserNotAuthenticatedError` (cancelled/locked prompt — key intact,
/// retry the prompt) never matches and keeps propagating for re-prompt.
bool _isKeyInvalidated(Object e) =>
    '$e'.toLowerCase().contains('invalidat');

/// Maps an invalidation thrown by the backend/DEK store to the canonical
/// clone/invalidation failure (fail-closed re-enroll); rethrows anything
/// else untouched (notably user-auth cancellations).
StateError _restoreDetected([String detail = '']) => StateError(
    'restore detected — re-enroll${detail.isEmpty ? '' : ' ($detail)'}');

/// HW-bound `DeviceKey` (P-256, non-exportable, ES256).
///
/// Owns the enrollment challenge binding + chain persistence carrier
/// (`pkDHex` + `chainDERHex` + level/window flow into `StoredEnrollment`
/// and the extended claim). Desktop/web fail closed via [requireMobileFace]
/// on every op (the DI-wired [UnavailableDeviceKey] remains the
/// records-only stub — this self-gate is defense in depth).
class HwDeviceKey implements DeviceKey {
  final HwKeyBackend _backend;
  final HwSealStore _sealStore;
  final String alias;

  Uint8List? _pkD;
  AttestationLevel _level = AttestationLevel.none;
  List<Uint8List> _chainDER = const [];
  DateTime _attestedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  DateTime _attestedUntil =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  Uint8List? _lastChallenge;
  // Apple App Attest stash (iOS only; null on Android): the enrollment
  // CBOR raw + parsed authData + credential key ride into StoredEnrollment
  // and the claim/prove bodies for the professor iOS branch.
  Uint8List? _appAttestRaw;
  Uint8List? _appAttestAuthData;
  Uint8List? _appAttestCredKey;

  /// Heartbeat roll budget (M7): at most this many `heartbeat()` rolls per
  /// enrollment before a fresh attestation is required. 8 × 90d ≈ 2y of
  /// silent rolls; past that `heartbeat()` returns false and
  /// [needsReattest] flips — the caller must `bindEnrollment` again (new
  /// key + chain + challenge, persisted atomically via the single
  /// `writeEnrollment` in enrollment). Bounds infinite-refresh of a stale
  /// binding; never auto-extends past the budget.
  static const int kMaxHeartbeatRolls = 8;
  int _heartbeatRolls = 0;

  /// True once the roll budget is spent — re-attest (re-enroll), don't roll.
  bool get needsReattest => _heartbeatRolls >= kMaxHeartbeatRolls;

  /// Test seam: roll count (lets tests assert the cap without 8×90d waits).
  @visibleForTesting
  int get debugHeartbeatRollsForTest => _heartbeatRolls;

  HwDeviceKey(
      {required HwKeyBackend backend,
      HwSealStore? sealStore,
      this.alias = kHwDeviceKeyAlias})
      : _backend = backend,
        _sealStore = sealStore ?? const FlutterSealStore();

  /// M1-gap canonical challenge: SHA256 over (emailLower || installId ||
  /// pkS32), domain-separated + length-prefixed (see
  /// [deviceBindingChallengeV2]). Thin wrapper over the protocol contract
  /// (sec-protocol 1A). The professor verifies exactly this challenge —
  /// no alternates, no migration accepts.
  static Uint8List enrollmentChallenge({
    required String email,
    required String installId,
    required Uint8List pkS,
  }) =>
      deviceBindingChallengeV2(
          emailLower: email, installId: installId, pkS: pkS);

  /// P-256 field prime + curve constant (y² ≡ x³ − 3x + b).
  static final BigInt _p256p = BigInt.parse(
      'FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF',
      radix: 16);
  // Pinned against NIST SP 800-186 §3.2.1.3 / SEC2 secp256r1
  // (b = 41058363725152142129326129780047268409114441015993725554835256314039467401291;
  // G membership pinned by the pkDFromXY generator test below).
  static final BigInt _p256b = BigInt.parse(
      '5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B',
      radix: 16);

  static BigInt _beToBig(Uint8List b) {
    var v = BigInt.zero;
    for (final byte in b) {
      v = (v << 8) | BigInt.from(byte);
    }
    return v;
  }

  /// True when 32B (x, y) lies on NIST P-256 (1 ≤ x,y < p and the curve
  /// equation holds). Pure-BigInt, no deps. Genuine StrongBox/TEE /
  /// Secure Enclave keys always satisfy this; an off-curve point means a
  /// broken plugin read or a substituted JWK — reject at bind, not at
  /// verify (downstream ES256 would fail there anyway, but with a
  /// misleading reason).
  static bool isOnP256Curve(Uint8List x, Uint8List y) {
    if (x.length != 32 || y.length != 32) return false;
    final bx = _beToBig(x);
    final by = _beToBig(y);
    if (bx <= BigInt.zero ||
        bx >= _p256p ||
        by <= BigInt.zero ||
        by >= _p256p) {
      return false;
    }
    final lhs = (by * by) % _p256p;
    final rhs = (((bx * bx) % _p256p * bx) % _p256p -
            (BigInt.from(3) * bx) % _p256p +
            _p256b) %
        _p256p;
    return lhs == rhs;
  }

  /// JWK → raw pkD helper for the production adapter: base64url-unpadded
  /// x||y (32B each) → 64B. Throws [FormatException] on bad input
  /// (strict — never silent empty) and when the point is not on P-256.
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
    if (!isOnP256Curve(x, y)) {
      throw FormatException('P-256 point not on curve (bind rejected).');
    }
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
  /// the canonical enrollment challenge (domain-separated +
  /// length-prefixed — see [enrollmentChallenge]) as the attestation
  /// challenge and caching the chain. Idempotent per enrollment (same
  /// inputs → same challenge; a new key replaces the old under [alias]).
  /// The professor verifies exactly this challenge — no alternates.
  /// Structure/length/challenge bytes only — sealed bytes
  /// are never decrypted or interpreted here.
  ///
  /// Attestation MUST succeed: any attest failure (or empty chain) throws
  /// `StateError` — enrollment never proceeds with an unbound key.
  ///
  /// [prevAppAttestCredKeyHex] carries the enrollment credential key
  /// forward on the iOS assertion path (same-install re-enroll yields an
  /// assertion, not an object — the plugin caches the App Attest keyId per
  /// install). Empty there fails closed with a reinstall pointer.
  @override
  Future<void> bindEnrollment({
    required String email,
    required String installId,
    required Uint8List pkS,
    String prevAppAttestCredKeyHex = '',
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
    late final HwAttestation att;
    try {
      att = await _backend.attest(alias: alias, serverNonce: challenge);
    } catch (e) {
      throw StateError(
          'attestation failed — re-enroll on a device with secure hardware (${e.runtimeType}).');
    }
    late final List<Uint8List> chain;
    if (!att.isApple) {
      chain = att.chainDER;
      if (chain.isEmpty || chain.any((c) => c.isEmpty)) {
        throw StateError(
            'attestation failed — empty attestation chain (no hardware proof).');
      }
      _appAttestRaw = null;
      _appAttestAuthData = null;
      _appAttestCredKey = null;
    } else {
      // Apple CBOR (see attestApple): object path carries the x5c chain +
      // credential key; assertion path carries authData with an empty
      // chain and the credential key rides forward from the previous
      // enrollment.
      if (att.appAttestRaw == null ||
          att.appAttestRaw!.isEmpty ||
          att.appAttestAuthData == null ||
          att.appAttestAuthData!.isEmpty) {
        throw StateError(
            'attestation failed — empty App Attest artifact (no hardware proof).');
      }
      if (att.chainDER.isNotEmpty) {
        if (att.chainDER.any((c) => c.isEmpty)) {
          throw StateError(
              'attestation failed — empty App Attest certificate (no hardware proof).');
        }
        if (att.appAttestCredKey == null ||
            att.appAttestCredKey!.length != 64) {
          throw StateError(
              'attestation failed — App Attest credential key missing.');
        }
        chain = att.chainDER;
        _appAttestCredKey = Uint8List.fromList(att.appAttestCredKey!);
      } else {
        final prev = prevAppAttestCredKeyHex.trim().toLowerCase();
        if (prev.length != 128) {
          throw StateError(
              're-enroll needs the previous App Attest credential — reinstall the app to re-attest, then enroll again.');
        }
        late final Uint8List prevKey;
        try {
          prevKey = hexDecode(prev);
        } catch (_) {
          throw StateError(
              're-enroll needs the previous App Attest credential — reinstall the app to re-attest, then enroll again.');
        }
        chain = const [];
        _appAttestCredKey = prevKey;
      }
      _appAttestRaw = Uint8List.fromList(att.appAttestRaw!);
      _appAttestAuthData = Uint8List.fromList(att.appAttestAuthData!);
    }
    _adopt(handle, chain: chain, challenge: challenge);
  }

  /// Apple App Attest CBOR raw hex ('' on Android / until bound).
  String get appAttestRawHex =>
      _appAttestRaw == null ? '' : hexEncode(_appAttestRaw!);

  /// Apple authData hex ('' on Android / until bound).
  String get appAttestAuthDataHex =>
      _appAttestAuthData == null ? '' : hexEncode(_appAttestAuthData!);

  /// Apple credential-key hex, 128 chars ('' on Android / until bound).
  String get appAttestCredKeyHex =>
      _appAttestCredKey == null ? '' : hexEncode(_appAttestCredKey!);

  void _adopt(HwKeyHandle h,
      {required List<Uint8List> chain, Uint8List? challenge}) {
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
    // Fresh attestation resets the heartbeat budget (M7): the new chain +
    // challenge commit atomically with the window at the single
    // `writeEnrollment` call site in enrollment (chain+pkD+window in one
    // doc write — never chain-without-window or vice versa).
    _heartbeatRolls = 0;
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
    // Biometric/credential-set invalidation destroys the HW key
    // (deliberate OS behavior): surface it as restore-detected re-enroll,
    // never a raw plugin error. Auth cancellations propagate for re-prompt.
    late final Uint8List sig;
    try {
      sig = await _backend.sign(alias: alias, payload: data);
    } catch (e) {
      if (_isKeyInvalidated(e)) throw _restoreDetected('key invalidated');
      rethrow;
    }
    if (sig.length != 64) {
      throw StateError(
          'HW sign failed: ES256 must be 64B raw R||S, got ${sig.length}.');
    }
    return sig;
  }

  /// Seals the 32B SKey seed under the device DEK (AES-256-GCM, PXK2
  /// envelope, empty AAD). Only ciphertext is ever persisted — the DEK never
  /// leaves HW-backed secure storage. Test/interface-only: fresh enrollments
  /// always use [sealWithAad] binding email/installId/pkS/pkD so a
  /// transplanted envelope fails the tag; no production caller seals here.
  @override
  Future<Uint8List> seal(Uint8List seed32) async {
    requireMobileFace();
    if (seed32.length != 32) {
      throw ArgumentError('seal needs a 32B SKey seed.');
    }
    if (_pkD == null) throw StateError('DeviceKey.ensure() first.');
    if (_level == AttestationLevel.none) {
      throw StateError(
          'Software-no-enroll: device key is not hardware-backed.');
    }
    late final bool exists;
    try {
      exists = await _backend.containsKey(alias: alias);
    } catch (e) {
      if (_isKeyInvalidated(e)) throw _restoreDetected('key invalidated');
      rethrow;
    }
    if (!exists) throw StateError('restore detected — re-enroll');
    var dek = await _sealStore.readDek(alias: alias);
    if (dek == null) {
      dek = randBytes(32);
      await _sealStore.writeDek(alias: alias, dek32: dek);
    }
    return sealWithDek(dek32: dek, seed32: seed32);
  }

  /// Unseals an empty-AAD PXK2 envelope (test/interface-only — fresh
  /// enrollment envelopes are AAD-bound and open via [unsealEnrollment] /
  /// [unsealWithAad]). Any failure — missing HW key (biometric
  /// invalidation), missing DEK, tampered envelope, AAD mismatch — throws
  /// StateError('restore detected — re-enroll').
  @override
  Future<Uint8List> unseal(Uint8List sealed) async {
    requireMobileFace();
    late final bool exists;
    try {
      exists = await _backend.containsKey(alias: alias);
    } catch (e) {
      if (_isKeyInvalidated(e)) throw _restoreDetected('key invalidated');
      rethrow;
    }
    if (!exists) throw StateError('restore detected — re-enroll');
    if (_pkD == null || _level == AttestationLevel.none) {
      throw StateError('restore detected — re-enroll');
    }
    // A DEK-store read failure fails closed the same way a missing DEK
    // does (clone / wiped storage / keychain unavailable): re-enroll,
    // never a raw fallback or raw platform error.
    Uint8List? dek;
    try {
      dek = await _sealStore.readDek(alias: alias);
    } catch (_) {
      throw StateError('restore detected — re-enroll');
    }
    if (dek == null) throw StateError('restore detected — re-enroll');
    return unsealWithDek(dek32: dek, sealed: sealed);
  }

  /// AAD-bound seal (M7, preferred): wraps [seed32] with AAD binding
  /// email/installId/pkS/pkD (see `buildSealAad`) so a transplanted
  /// envelope fails the GCM tag. Structure/length/tag checks only — never
  /// decrypts anything but the caller's own envelope under this DEK.
  Future<Uint8List> sealWithAad(
    Uint8List seed32, {
    required Uint8List aad,
  }) async {
    requireMobileFace();
    if (seed32.length != 32) {
      throw ArgumentError('seal needs a 32B SKey seed.');
    }
    if (_pkD == null) throw StateError('DeviceKey.ensure() first.');
    if (_level == AttestationLevel.none) {
      throw StateError(
          'Software-no-enroll: device key is not hardware-backed.');
    }
    late final bool exists;
    try {
      exists = await _backend.containsKey(alias: alias);
    } catch (e) {
      if (_isKeyInvalidated(e)) throw _restoreDetected('key invalidated');
      rethrow;
    }
    if (!exists) throw StateError('restore detected — re-enroll');
    var dek = await _sealStore.readDek(alias: alias);
    if (dek == null) {
      dek = randBytes(32);
      await _sealStore.writeDek(alias: alias, dek32: dek);
    }
    return sealWithDek(dek32: dek, seed32: seed32, aad: aad);
  }

  /// Opens an AAD-bound envelope; [aad] must equal the seal-time value.
  /// Any failure throws StateError('restore detected — re-enroll').
  Future<Uint8List> unsealWithAad(
    Uint8List sealed, {
    required Uint8List aad,
  }) async {
    requireMobileFace();
    late final bool exists;
    try {
      exists = await _backend.containsKey(alias: alias);
    } catch (e) {
      if (_isKeyInvalidated(e)) throw _restoreDetected('key invalidated');
      rethrow;
    }
    if (!exists) throw StateError('restore detected — re-enroll');
    if (_pkD == null || _level == AttestationLevel.none) {
      throw StateError('restore detected — re-enroll');
    }
    Uint8List? dek;
    try {
      dek = await _sealStore.readDek(alias: alias);
    } catch (_) {
      throw StateError('restore detected — re-enroll');
    }
    if (dek == null) throw StateError('restore detected — re-enroll');
    return unsealWithDek(dek32: dek, sealed: sealed, aad: aad);
  }

  /// Opens an AAD-bound enrollment envelope ([sealWithAad] only, full-fresh:
  /// no empty-AAD legacy open). AAD is rebuilt from [email]/[installId]/[pkS]
  /// + the live pkD — the same inputs [EnrollmentController.upload] sealed
  /// with. Any failure (legacy pre-M7 envelope, transplant, corruption,
  /// clone) throws the standard restore-detected StateError — re-enroll,
  /// never a fallback open. Only this device's own envelope under its DEK
  /// is ever opened.
  Future<Uint8List> unsealEnrollment({
    required Uint8List sealed,
    required String email,
    required String installId,
    required Uint8List pkS,
  }) async {
    final livePkD = _pkD != null ? Uint8List.fromList(_pkD!) : Uint8List(0);
    if (livePkD.isEmpty ||
        pkS.isEmpty ||
        installId.isEmpty ||
        email.trim().isEmpty) {
      throw StateError('restore detected — re-enroll');
    }
    return unsealWithAad(
      sealed,
      aad: buildSealAad(
        emailLower: email,
        installId: installId,
        pkS: pkS,
        pkD: livePkD,
      ),
    );
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
    // M7 budget: past the roll cap the binding must re-attest (new key +
    // chain + challenge) — silent infinite refresh would keep a stale
    // binding alive forever. Returns false so the caller surfaces
    // re-enroll instead of a fresh window.
    if (needsReattest) return false;
    // The HW key may have died under us (biometric/credential-set
    // invalidation destroys it): never roll the window on a dead key —
    // the next seal/unseal/sign fails closed to re-enroll instead.
    try {
      if (!await _backend.containsKey(alias: alias)) return false;
    } catch (e) {
      if (_isKeyInvalidated(e)) return false;
      rethrow;
    }
    _attestedUntil =
        ((now ?? DateTime.now()).toUtc()).add(kDeviceAttestedValidity);
    _heartbeatRolls += 1;
    return true;
  }
}
