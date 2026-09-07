// Device key (Track 3 adopted): DKey abstraction over HW-backed P-256.
//
// Production mapping (platform shell, one implementer with the trust
// interface): Android StrongBox→TEE / iOS Secure Enclave, attested at
// enrollment (Android Key Attestation chain / iOS App Attest with
// challenge=SHA256(serverNonce||emailLower||installId||pkS) — see
// attestationChallenge in the protocol). SKey Ed25519 is KEPT (protocol
// untouched) but sealed to DKey (AES-GCM, ciphertext only at rest).
// Extended claim {pkS,pkD,installId,attestationLevel,attestedAt,
// attestedUntil=+90d}; /prove adds pkD + dSig=Sign(DKey, session||window||
// j||C_j||faceTicketHash||pkS); professor verifies offline (chain→baked
// roots + dSig + Sig_s + ticket + existing checks). Tiers FULL/STD→
// confirmed, STALE (14d grace)→confirmed+banner, NONE→invalid:
// device-unproven→manual path; heartbeat rolls attestedUntil;
// old-DKey-signed MoveIntent = instant move else 7d cooldown kept;
// backup-restore clone fails unwrap→'restore detected — re-enroll';
// double-pkD audit flag on sync.
//
// What this file IS: the narrow Dart interface + sealed-SKey envelope
// bookkeeping + software/fake backends (level `none`, dev/test only —
// they can never confirm at a real host since NONE→device-unproven).
// What it is NOT (deferred, noted as residual risk): the Kotlin/Swift HW
// keystore + X.509 chain verify. Firestore X.509 caveat accepted: client
// verify + offline re-verify + post-hoc flag; Cloud Function verifier =
// deferred.
library;

import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_protocol/protocol.dart';

import '../../core/platformx.dart';

/// Sealed-SKey envelope magic (versioned so a format change fails closed
/// instead of decrypting garbage into a signing key).
const List<int> kSealedKeyMagic = [0x50, 0x58, 0x4B, 0x31]; // "PXK1"

/// Narrow device-key interface.
abstract class DeviceKey {
  /// Generates (or loads) the device key. Idempotent.
  Future<void> ensure();

  /// Raw DKey public bytes (empty until [ensure]). Bound into Sig_s and
  /// the extended claim as pkD.
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
}

/// Fail-closed stub for desktop/web (L3 DI wires this wherever
/// [canUseFace] is false): no key, no signatures, level `none` — every
/// proof from here verifies as device-unproven → manual path.
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
}

/// Software fallback (dev/test + no-HW phones): Ed25519 stand-in keypair,
/// XOR envelope (NOT AES-GCM — documented, never HW-grade), level `none`
/// so a real host always verdicts device-unproven. Lets the full
/// enroll→seal→prove→verify loop run in tests without secure hardware.
class SoftwareDeviceKey implements DeviceKey {
  ed.KeyPair? _keys;
  DateTime _attestedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  DateTime _attestedUntil =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  @override
  Future<void> ensure() async {
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
  })  : pkDBytes = pkD ?? Uint8List.fromList(List.filled(32, 7)),
        attestedAtValue =
            attestedAt ?? DateTime.utc(2026, 9, 1),
        attestedUntilValue =
            attestedUntil ?? DateTime.utc(2026, 12, 1);

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
    return Uint8List.fromList(
        ProxCrypto.sha256Sync([...data, ...pkDBytes]).sublist(0, 64));
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
}

/// Mobile-only guard for HW key use (mirrors the face L1 gate).
void requireMobileDeviceKey() => requireMobileFace();

final deviceKeyProvider = Provider<DeviceKey>((ref) {
  throw UnimplementedError('Override in main / tests');
});
