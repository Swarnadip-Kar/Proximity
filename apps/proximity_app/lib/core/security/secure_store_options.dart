// Hardened flutter_secure_storage options (PROXIMITY_SECURITY.md §3, F3).
//
// Single source of truth for enrollment-secret storage options. The only
// future wiring is one line in `core/sync/store/secure_store.dart:30`:
//   `FlutterSecureStorage(aOptions: SecureStoreOptions.aOpts, iOptions: SecureStoreOptions.iOpts)`
// (owned outside 1B — this file exposes the API, never edits callers).
//
// Guarantees:
// - Android: Keystore-backed AES-GCM key + AES-GCM storage with enforced
//   Class-3 (strong) biometrics only. `AndroidOptions.biometric` pins both
//   ciphers to `AES_GCM_NoPadding` internally; `strongBiometricOnly` rejects
//   PIN/pattern/password fallback (never `local_auth` bool alone).
// - iOS: Keychain, never synced to iCloud (`synchronizable: false`),
//   `first_unlock_this_device_only` (no migration to a new device via
//   backup/restore — closes the clone-identity path with `allowBackup=false`
//   on Android), `biometryCurrentSet` (a newly enrolled biometric invalidates
//   old access).
// - Desktop/web fail-closed: [newStorage]/[requireSupportedPlatform] throw
//   [StateError] off Android/iOS (mirrors `requireMobileFace`). Records-only
//   targets must never silently persist enrollment secrets in weak storage.
library;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Public API for 1B secure storage (handoff: callers depend on this class,
/// never on its internals).
class SecureStoreOptions {
  SecureStoreOptions._();

  /// Android: biometric-bound AES-GCM (`enforceBiometrics: true`,
  /// [AndroidBiometricType.strongBiometricOnly]).
  ///
  /// The negative button label is required with `strongBiometricOnly`
  /// (no device-credential fallback exists to dismiss the prompt).
  static const aOpts = AndroidOptions.biometric(
    enforceBiometrics: true,
    biometricType: AndroidBiometricType.strongBiometricOnly,
    biometricPromptTitle: 'Authenticate to access Proximity',
    biometricPromptNegativeButton: 'Cancel',
  );

  /// iOS: Keychain, this-device-only, current-biometric-set bound, no sync.
  static const iOpts = IOSOptions(
    synchronizable: false,
    accessibility: KeychainAccessibility.first_unlock_this_device,
    accessControlFlags: [AccessControlFlag.biometryCurrentSet],
  );

  /// Prebuilt hardened instance for callers that already gated on
  /// [isSupportedPlatform]. Prefer [newStorage], which enforces the gate.
  static const storage = FlutterSecureStorage(
    aOptions: aOpts,
    iOptions: iOpts,
  );

  /// True only where HW-backed secure storage exists (Android/iOS).
  static bool get isSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Fail-closed gate for records-only targets (desktop/web).
  static void requireSupportedPlatform() {
    if (!isSupportedPlatform) {
      throw StateError(
        'Secure enrollment storage needs the mobile app (Android/iOS) — '
        'this device is records-only.',
      );
    }
  }

  /// Hardened storage, fail-closed off mobile.
  static FlutterSecureStorage newStorage() {
    requireSupportedPlatform();
    return storage;
  }
}
