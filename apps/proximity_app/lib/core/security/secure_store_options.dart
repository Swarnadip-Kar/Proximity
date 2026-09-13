// Hardened flutter_secure_storage options (PROXIMITY_SECURITY.md §3, F3).
//
// Single source of truth for enrollment-secret storage options. The only
// future wiring is one line in `core/sync/store/secure_store.dart:30`:
//   `FlutterSecureStorage(aOptions: SecureStoreOptions.aOpts, iOptions: SecureStoreOptions.iOpts)`
// (owned outside 1B — this file exposes the API, never edits callers).
//
// Guarantees:
// - Android: Keystore-backed AES-GCM key + AES-GCM storage with enforced
//   Class-3 (strong) biometrics only (`enforceBiometrics: true`,
//   `strongBiometricOnly`). `AndroidOptions.biometric` pins both ciphers to
//   `AES_GCM_NoPadding` internally; `strongBiometricOnly` rejects
//   PIN/pattern/password fallback (never `local_auth` bool alone).
// - iOS: Keychain, never synced to iCloud (`synchronizable: false`),
//   `first_unlock_this_device` (no migration to a new device via
//   backup/restore — closes the clone-identity path with `allowBackup=false`
//   on Android, see AndroidManifest + res/xml/data_extraction_rules.xml which
//   excludes sharedpref/FlutterSecureStorage.xml from cloud-backup and
//   device-transfer on API 31+), `biometryCurrentSet` (a newly enrolled
//   biometric invalidates old access).
// - No `useSecureEnclave` flag here by design: flutter_secure_storage
//   ^11.1.1 has no such option (iOS security comes from the Keychain
//   accessibility/synchronizable/accessControlFlags above). Secure Enclave /
//   StrongBox P-256 usage comes from `attested_secure_keys ^0.1.1` via
//   HwDeviceKey (StrongBox→TEE / Secure Enclave, ES256, challenge-bound) —
//   never from FSS.
// - Enrollment doc (this file) IS biometric-gated; the HW seal DEK store
//   (`FlutterSealStore` in features/device_identity/hw_device_key.dart) is
//   deliberately prompt-free (plain AES-GCM FSS, unsynced this-device-only
//   iOS) — use is already gated by the 4h HW-key grant
//   (`UserAuthPolicy.timeBound(4h)`) + the face check, and a per-read prompt
//   would strand every 10s prove rotation.
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
  ///
  /// `storageNamespace: 'prox_enroll'` isolates this instance's data prefs,
  /// config/algorithm markers, KeyStore aliases and wrapped-key prefs from
  /// the prompt-free seal store (`FlutterSealStore`, namespace
  /// `'prox_seal'`), which uses a DIFFERENT key cipher (RSA wrap vs AES
  /// wrap here). Without isolation the two instances flip each other's
  /// algorithm markers and trigger migrate/reset wipes (FSS v11
  /// `FlutterSecureStorageConfig`: namespace suffixes KeyStore aliases and
  /// scopes all prefs). `migrateWithBackup: true` makes any future
  /// algorithm migration crash-resistant (backup before migrate).
  static const aOpts = AndroidOptions.biometric(
    enforceBiometrics: true,
    biometricType: AndroidBiometricType.strongBiometricOnly,
    biometricPromptTitle: 'Authenticate to access Proximity',
    biometricPromptNegativeButton: 'Cancel',
    storageNamespace: 'prox_enroll',
    migrateWithBackup: true,
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
