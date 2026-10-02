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
// - Desktop/web fail-closed by construction: [SecureDeviceStore] is only
//   wired on mobile (see main.dart provider setup); records-only targets
//   get the fail-closed stubs and never persist enrollment secrets.
library;

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
  /// scopes all prefs).
  ///
  /// `migrateOnAlgorithmChange: false` (with `resetOnError: false`):
  /// namespace-per-config IS the migration strategy — a config change
  /// ships a NEW namespace, never a marker flip — because the plugin's
  /// backup-migration crashes on fresh biometric namespaces
  /// (`IllegalStateException: Cipher not initialized` initializing the
  /// current cipher without a biometric CryptoObject, observed in field
  /// logcat) and then `resetOnError` wipes the Keystore key anyway. Off
  /// goes straight to delete+clean-reinit on mismatch: crash-free, and
  /// the only data at risk is already unrecoverable.
  ///
  /// `resetOnError: false` is load-bearing (field crash 2026-10-02): on
  /// KeyStore2-strict devices `cipher.init` throws
  /// `UserNotAuthenticatedException` (an InvalidKeyException) BEFORE any
  /// BiometricPrompt shows, and the plugin misclassifies it as a key
  /// mismatch. With reset enabled it deletes ALL data + keys, re-inits,
  /// fails again, and recurses on its worker HandlerThread until
  /// StackOverflowError kills the process — wiping the enrollment to
  /// boot. With reset off the failure surfaces as a PlatformException,
  /// which secure_store.dart maps to dismissed/unavailable (park +
  /// retry, data preserved, no crash).
  static const aOpts = AndroidOptions.biometric(
    enforceBiometrics: true,
    biometricType: AndroidBiometricType.strongBiometricOnly,
    biometricPromptTitle: 'Authenticate to access Proximity',
    biometricPromptNegativeButton: 'Cancel',
    storageNamespace: 'prox_enroll',
    migrateOnAlgorithmChange: false,
    resetOnError: false,
    migrateWithBackup: true,
  );

  /// Android fallback for devices WITHOUT Class-3 strong biometrics
  /// (PIN/pattern/password-only phones). Honest tier: the enrollment
  /// stamps [AttestationLevel.standard] instead of `.full`, and the
  /// professor sees a banner. Never silent — a credential-only device
  /// cannot claim biometric-tier security.
  ///
  /// `storageNamespace: 'prox_enroll_cred'` (DISTINCT from [aOpts]'s
  /// `'prox_enroll'`): the two instances MUST NOT share a namespace. FSS
  /// v11 derives the KeyStore alias (`.<namespace>`), the IV pref
  /// (`KeyStoreIV1`) and the wrapped app-key blob from the namespace, so
  /// two configs with different `biometricType` (different
  /// `UserAuthenticationParameters`) sharing one namespace clobber each
  /// other's IV/blob — the loser's post-auth `cipher.doFinal` then throws
  /// `javax.crypto.IllegalBlockSizeException` inside
  /// `BiometricPrompt.onAuthenticationSucceeded` (the field
  /// "Save failed: PlatformException(...IllegalBlockSizeException...)").
  /// Separate namespaces = separate keys/blobs = no clobber.
  /// `migrateOnAlgorithmChange: false` like [aOpts] (namespace-per-config
  /// is the migration strategy; the plugin backup path crashes on fresh
  /// biometric namespaces — see above).
  /// `resetOnError: false` like [aOpts] (the same KeyStore2-strict
  /// `UserNotAuthenticatedException`-as-mismatch wipe + worker-thread
  /// StackOverflow crash applies to this slot too — surface errors, never
  /// wipe).
  static const aOptsFallback = AndroidOptions.biometric(
    enforceBiometrics: true,
    biometricType: AndroidBiometricType.biometricOrDeviceCredential,
    biometricPromptTitle: 'Authenticate to access Proximity',
    storageNamespace: 'prox_enroll_cred',
    migrateOnAlgorithmChange: false,
    resetOnError: false,
    migrateWithBackup: true,
  );

  /// iOS: Keychain, this-device-only, current-biometric-set bound, no sync.
  static const iOpts = IOSOptions(
    synchronizable: false,
    accessibility: KeychainAccessibility.first_unlock_this_device,
    accessControlFlags: [AccessControlFlag.biometryCurrentSet],
  );

  /// iOS fallback for devices WITHOUT Face ID / Touch ID (passcode-only
  /// iPods, misconfigured phones). No biometryCurrentSet → uses passcode.
  static const iOptsFallback = IOSOptions(
    synchronizable: false,
    accessibility: KeychainAccessibility.first_unlock_this_device,
    // No biometric flag → iOS falls back to device passcode.
  );
}

