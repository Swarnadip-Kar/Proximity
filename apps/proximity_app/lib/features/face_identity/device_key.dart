//
// Production mapping: Android StrongBox→TEE / iOS Secure Enclave via
// [HwDeviceKey] (attested_secure_keys backend — the provider default on
// mobile below). SKey Ed25519 is KEPT (protocol untouched) but sealed to DKey (AES-GCM on HW, envelope here —
// ciphertext only at rest). Extended claim carries
// {pkS,pkD,installId,attestationLevel,self-asserted,attestedAt,
// attestedUntil=+90d}; /prove adds pkD + dSig=Sign(DKey, session||
// window||j||C_j||faceTicketHash||pkS); the professor verifies the fresh
// signature offline (dSig + Sig_s + ticket + existing checks) and reads
// the claimed level for tiering — chain→root verification exists
// nowhere in this system (see the caveat below).
// Tiers FULL/STD→confirmed, STALE (14d grace)→confirmed+banner;
// NONE claims no tier — until HW keys ship, the host applies the graceful
// `device-none-fallback` (same ticket/Sig_s/face/sighting checks, flagged
// confirm) so software-key students mark normally. Heartbeat rolls
// attestedUntil; old-DKey-signed MoveIntent = instant move else 30-day
// cooldown kept; backup-restore clone fails unwrap→'restore detected —
// re-enroll' (on HW keys; software keys copy with their files —
// SoftwareDeviceKey below is level `none` for exactly this reason, which
// is why its proofs carry the fallback flag rather than a tier).
//
// What this file IS: the narrow Dart interface + [UnavailableDeviceKey]
// (desktop/web fail-closed) + test-only [SoftwareDeviceKey]/[FakeDeviceKey]
// (level `none`) + the [deviceKeyProvider] default (HW on mobile,
// fail-closed stub otherwise). Production HW lives in
// `features/device_identity/hw_device_key.dart` ([HwDeviceKey]: P-256,
// StrongBox→TEE / Secure Enclave, ES256, challenge-bound, sealed-only).
// Deliberately absent: any server re-check — the project carries
// no billing-gated backend, so attestation levels are client-presented and
// checked offline (chain-vs-pinned-roots + challenge match, never trust on
// claim alone) by verifiers. See PROXIMITY_DESIGN.md §3.4 for the trust
// model this implies.
library;

import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_protocol/protocol.dart';

import '../../core/platformx.dart';
import '../device_identity/hw_device_key.dart';

/// Sealed-SKey envelope magic (versioned so a format change fails closed
/// instead of decrypting garbage into a signing key).
const List<int> kSealedKeyMagic = [0x50, 0x58, 0x4B, 0x31]; // "PXK1"

/// Narrow device-key interface.
///
/// pkD length contract (callers must NOT assume a fixed length — treat pkD
/// as opaque variable-length bytes, hexEncode/fingerprint only, never a
/// fixed slice or length assert):
/// - HW ([HwDeviceKey]): 64B P-256 x||y (JWK x/y 32B each via
///   `HwDeviceKey.pkDFromXY`).
/// - Software ([SoftwareDeviceKey]): 32B Ed25519 public key (test-only,
///   level `none`).
/// - Fake ([FakeDeviceKey]): scripted bytes, 32B by default (tests may pass
///   64B to mirror HW — both shapes must prove).
abstract class DeviceKey {
  /// Generates (or loads) the device key. Idempotent.
  Future<void> ensure();

  /// Raw DKey public bytes (throws until [ensure]/[bindEnrollment]).
  /// Bound into Sig_s and the extended claim as pkD (pkDHex). Length is
  /// backend-defined (HW 64B P-256 x||y vs Software 32B Ed25519) — callers
  /// must not branch on length.
  Uint8List get pkD;

  /// Signs [data] (canonically the deviceProvePreimage) with DKey.
  Future<Uint8List> sign(Uint8List data);

  /// Seals the Ed25519 SKey seed to DKey (AES-GCM on HW; envelope here).
  /// Only ciphertext is ever persisted.
  Future<Uint8List> seal(Uint8List seed32);

  /// Unseals a sealed SKey seed. Throws StateError('restore detected —
  /// re-enroll') when the envelope cannot be opened with THIS device key
  /// (backup-restore clone carrying ciphertext to a new key).
  Future<Uint8List> unseal(Uint8List sealed);

  /// HW attestation level of this key.
  AttestationLevel get level;

  /// Attestation window (claimed at enrollment, rolled by heartbeat).
  DateTime get attestedAt;
  DateTime get attestedUntil;

  /// Best-effort online heartbeat: rolls [attestedUntil] to now+90d when
  /// this device still holds the binding. Returns true when rolled.
  Future<bool> heartbeat({DateTime? now});

  /// HW attestation chain as DER-hex (leaf-first, security §2 + §7 wire
  /// form). Default `[]` (unbound legacy/test path) — [HwDeviceKey]
  /// overrides with the OS attestation chain cached at bind time.
  List<String> get chainDERHex => const [];

  /// Binds one enrollment to HW (embeds the M1-gap challenge at key
  /// creation). Default calls [ensure] (software/fake path) — HW
  /// backends override to generate with the challenge.
  Future<void> bindEnrollment({
    required String email,
    required String installId,
    required Uint8List pkS,
  }) =>
      ensure();
}

/// Fail-closed stub for desktop/web (L3 DI wires this wherever
/// [canUseFace] is false): no key, no signatures — every op throws before
/// anything signs, so nothing from here can ever prove (fallback needs a
/// real ticket-bound Sig_s first).
class UnavailableDeviceKey implements DeviceKey {
  const UnavailableDeviceKey();

  static StateError _blocked([String op = 'Device binding']) => StateError(
      '$op needs the mobile app (Android/iOS) — this device is records-only.');

  @override
  Future<void> ensure() async => throw _blocked();

  @override
  Uint8List get pkD => throw _blocked();

  @override
  Future<Uint8List> sign(Uint8List data) async => throw _blocked('Signing');

  @override
  Future<Uint8List> seal(Uint8List seed32) async => throw _blocked('Sealing');

  @override
  Future<Uint8List> unseal(Uint8List sealed) async => throw _blocked();

  @override
  AttestationLevel get level => AttestationLevel.none;

  @override
  DateTime get attestedAt =>
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  @override
  DateTime get attestedUntil =>
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  @override
  Future<bool> heartbeat({DateTime? now}) async => false;

  @override
  List<String> get chainDERHex => const [];

  @override
  Future<void> bindEnrollment({
    required String email,
    required String installId,
    required Uint8List pkS,
  }) async =>
      throw _blocked();
}

/// TEST-ONLY software stand-in (security §2: never production).
///
/// Ed25519 keypair + XOR envelope (NOT AES-GCM — documented, never
/// HW-grade), level `none` (no tier claimed). Production enroll/prove
/// fail closed on it (`Software-no-enroll` / sealed-only re-enroll);
/// unit/widget tests use it (or [FakeDeviceKey]) to drive the
/// enroll→seal→prove→verify loop without secure hardware. The constructor
/// asserts `kDebugMode`; [ensure] additionally throws outside debug so a
/// release build can never silently enroll software.
class SoftwareDeviceKey implements DeviceKey {
  SoftwareDeviceKey() {
    assert(kDebugMode,
        'SoftwareDeviceKey is test-only — production uses HwDeviceKey.');
  }

  ed.KeyPair? _keys;
  DateTime _attestedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  DateTime _attestedUntil =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  @override
  Future<void> ensure() async {
    if (!kDebugMode) {
      throw StateError(
          'Software-no-enroll: software device keys cannot enroll — use a mobile device with StrongBox/TEE or Secure Enclave (HwDeviceKey).');
    }
    if (_keys != null) return;
    _keys = ProxCrypto.generateEdKeypair();
    final now = DateTime.now().toUtc();
    _attestedAt = now;
    _attestedUntil = now.add(kDeviceAttestedValidity);
  }

  @override
  Uint8List get pkD {
    final k = _keys;
    if (k == null) throw StateError('DeviceKey.ensure() first.');
    return Uint8List.fromList(k.publicKey.bytes.sublist(0, 32));
  }

  @override
  Future<Uint8List> sign(Uint8List data) async {
    final k = _keys;
    if (k == null) throw StateError('DeviceKey.ensure() first.');
    return ProxCrypto.sign(k.privateKey, data);
  }

  @override
  Future<Uint8List> seal(Uint8List seed32) async {
    final k = _keys;
    if (k == null) throw StateError('DeviceKey.ensure() first.');
    final pad = Uint8List.fromList(k.publicKey.bytes.sublist(0, 32));
    final body = Uint8List(seed32.length);
    for (var i = 0; i < seed32.length; i++) {
      body[i] = seed32[i] ^ pad[i % pad.length];
    }
    return Uint8List.fromList([...kSealedKeyMagic, ...body]);
  }

  @override
  Future<Uint8List> unseal(Uint8List sealed) async {
    final k = _keys;
    if (k == null) throw StateError('restore detected — re-enroll');
    if (sealed.length < kSealedKeyMagic.length + 32) {
      throw StateError('restore detected — re-enroll');
    }
    for (var i = 0; i < kSealedKeyMagic.length; i++) {
      if (sealed[i] != kSealedKeyMagic[i]) {
        throw StateError('restore detected — re-enroll');
      }
    }
    final pad = Uint8List.fromList(k.publicKey.bytes.sublist(0, 32));
    final body = sealed.sublist(kSealedKeyMagic.length);
    if (body.length != 32) throw StateError('restore detected — re-enroll');
    return Uint8List.fromList(
        [for (var i = 0; i < 32; i++) body[i] ^ pad[i % pad.length]]);
  }

  @override
  AttestationLevel get level => AttestationLevel.none;

  @override
  DateTime get attestedAt => _attestedAt;

  @override
  DateTime get attestedUntil => _attestedUntil;

  @override
  Future<bool> heartbeat({DateTime? now}) async {
    if (_keys == null) return false;
    _attestedUntil =
        ((now ?? DateTime.now()).toUtc()).add(kDeviceAttestedValidity);
    return true;
  }

  @override
  List<String> get chainDERHex => const [];

  @override
  Future<void> bindEnrollment({
    required String email,
    required String installId,
    required Uint8List pkS,
  }) async =>
      ensure();
}

/// Test fake: scripted pkD/level/window, clone simulation via [dropKey]
/// (unseal then throws 'restore detected — re-enroll', modelling a
/// backup-restore clone that carried ciphertext to a new install).
class FakeDeviceKey implements DeviceKey {
  Uint8List pkDBytes;
  AttestationLevel attestLevel;
  DateTime attestedAtValue;
  DateTime attestedUntilValue;
  bool _dropped = false;
  final List<Uint8List> signed = [];

  FakeDeviceKey({
    Uint8List? pkD,
    this.attestLevel = AttestationLevel.full,
    DateTime? attestedAt,
    DateTime? attestedUntil,
    List<String>? chainDERHex,
  })  : pkDBytes = pkD ?? Uint8List.fromList(List.filled(32, 7)),
        attestedAtValue =
            attestedAt ?? DateTime.utc(2026, 9, 1),
        attestedUntilValue =
            attestedUntil ?? DateTime.utc(2026, 12, 1),
        chainDERHexValue = List<String>.unmodifiable(chainDERHex ?? const []);

  /// Simulates a backup-restore clone: the new install holds ciphertext
  /// its fresh key cannot open.
  void dropKey() => _dropped = true;

  @override
  Future<void> ensure() async {}

  @override
  Uint8List get pkD => Uint8List.fromList(pkDBytes);

  @override
  Future<Uint8List> sign(Uint8List data) async {
    signed.add(Uint8List.fromList(data));
    // Test stand-in bytes (the host checks the platform P-256 dSig in
    // production; tests assert [dSigValid] plumbing + preimage content).
    final h1 = ProxCrypto.sha256Sync([...data, ...pkDBytes]);
    final h2 = ProxCrypto.sha256Sync([...pkDBytes, ...data]);
    return Uint8List.fromList([...h1, ...h2]);
  }

  @override
  Future<Uint8List> seal(Uint8List seed32) async =>
      Uint8List.fromList([...kSealedKeyMagic, ...seed32]);

  @override
  Future<Uint8List> unseal(Uint8List sealed) async {
    if (_dropped) throw StateError('restore detected — re-enroll');
    if (sealed.length < kSealedKeyMagic.length + 32) {
      throw StateError('restore detected — re-enroll');
    }
    return Uint8List.fromList(sealed.sublist(kSealedKeyMagic.length));
  }

  @override
  AttestationLevel get level => attestLevel;

  @override
  DateTime get attestedAt => attestedAtValue;

  @override
  DateTime get attestedUntil => attestedUntilValue;

  @override
  Future<bool> heartbeat({DateTime? now}) async {
    attestedUntilValue =
        ((now ?? DateTime.now()).toUtc()).add(kDeviceAttestedValidity);
    return true;
  }

  /// Scripted attestation chain (DER-hex, leaf-first). `[]` by default —
  /// tests proving chain persistence pass a chain here.
  List<String> chainDERHexValue = const [];

  @override
  List<String> get chainDERHex => List<String>.unmodifiable(chainDERHexValue);

  @override
  Future<void> bindEnrollment({
    required String email,
    required String installId,
    required Uint8List pkS,
  }) async =>
      ensure();
}

final deviceKeyProvider = Provider<DeviceKey>((ref) {
  // Production default (main.dart still overrides explicitly per launch;
  // tests inject SoftwareDeviceKey/FakeDeviceKey): the HW device key on
  // mobile (StrongBox→TEE / Secure Enclave via [AttestedSecureKeysBackend]),
  // fail-closed stub on records-only targets. Constructing the backend is
  // side-effect-free (no keystore touch until ensure/bind); desktop/web
  // never reach it (records-only branch below, plus the mobile gate inside
  // [HwDeviceKey] itself).
  if (canUseFace()) {
    return HwDeviceKey(
      backend: AttestedSecureKeysBackend(),
      sealStore: const FlutterSealStore(),
    );
  }
  return const UnavailableDeviceKey();
});
