// Explicit user-presence confirmation for high-value writes.
//
// Long-term auth posture (field crash 2026-10-02): the old design bound
// the whole enrollment store to Keystore user-auth keys
// (flutter_secure_storage `enforceBiometrics`, auth required at
// `cipher.init`). On KeyStore2-strict devices init throws BEFORE any
// prompt can show, the plugin misclassifies it as corruption, and the
// recovery path wiped everything into a fatal crash loop. Storage
// itself is therefore prompt-free Keystore-encrypted (see
// [SecureStoreOptions]); THIS gate is the explicit biometric/PIN
// touchpoint, fired only from explicit user actions (enrollment Save),
// never on cold start, never on background paths (prove rebinding,
// roll edits stay silent).
//
// What still gates USE (unchanged): the HW device key (StrongBox/TEE,
// HW-bound + attested + challenge-bound, use-time ungated fleet-wide —
// the retired 4h biometric-grant/CryptoObject pattern is gone; see
// docs/hw-device-key-auth-policy-research.md) + the live face check per
// marking + the server-side single-device claim. Presence here is
// explicit consent at identity creation, not the signing authority.
library;

import 'package:local_auth/local_auth.dart';

/// Explicit user-presence confirmation. [confirm] completes silently on
/// success and throws [StateError] with actionable copy otherwise
/// (unsupported device, cancelled/failed prompt) — callers surface
/// `message` the same way they surface every other save refusal.
abstract class UserPresenceGate {
  Future<void> confirm({required String reason});
}

/// Production gate over `local_auth` (biometrics fall back to device
/// credential, so PIN/pattern-only phones confirm too — matching the old
/// credential-fallback tier, never silently biometric-only).
class LocalAuthPresenceGate implements UserPresenceGate {
  final LocalAuthentication _auth;

  LocalAuthPresenceGate([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();

  @override
  Future<void> confirm({required String reason}) async {
    var supported = false;
    try {
      supported = await _auth.isDeviceSupported();
    } catch (_) {
      supported = false;
    }
    if (!supported) {
      throw StateError(
          'Could not confirm it\'s you — this device has no screen lock '
          'or biometric set up. Set one in Settings, then save again.');
    }
    late final bool ok;
    try {
      ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
      );
    } catch (_) {
      // Plugin throws on cancel/failure modes (LocalAuthException):
      // never a raw leak, always the actionable save copy.
      throw StateError(
          'Save cancelled — approve the phone prompt to save enrollment.');
    }
    if (!ok) {
      throw StateError(
          'Save cancelled — approve the phone prompt to save enrollment.');
    }
  }
}

/// Test / preview gate: scripted outcome, records confirm calls.
class FakePresenceGate implements UserPresenceGate {
  final List<String> confirmReasons = [];

  /// When false, [confirm] throws the cancelled copy (default true).
  bool willConfirm = true;

  /// When true, [confirm] throws the unsupported-device copy instead.
  bool unsupportedDevice = false;

  @override
  Future<void> confirm({required String reason}) async {
    confirmReasons.add(reason);
    if (unsupportedDevice) {
      throw StateError(
          'Could not confirm it\'s you — this device has no screen lock '
          'or biometric set up. Set one in Settings, then save again.');
    }
    if (!willConfirm) {
      throw StateError(
          'Save cancelled — approve the phone prompt to save enrollment.');
    }
  }
}
