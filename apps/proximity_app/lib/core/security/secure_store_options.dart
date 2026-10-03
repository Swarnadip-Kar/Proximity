// Keystore-backed enrollment storage options (PROXIMITY_SECURITY.md §3).
//
// Single source of truth for enrollment-secret storage options. The only
// future wiring is one line in `core/sync/store/secure_store.dart`:
//   `FlutterSecureStorage(aOptions: SecureStoreOptions.aOpts, iOptions: SecureStoreOptions.iOpts)`
//
// Posture (long-term, fleet-wide):
// - Prompt-free Keystore/Keychain storage (AES-GCM / RSA-wrapped app
//   key, this-device-only, unsynced, backup-excluded). Reads and writes
//   NEVER pop a system prompt, on any device.
// - Explicit user presence lives one layer up ([UserPresenceGate],
//   local_auth biometric-or-credential), fired only from explicit user
//   actions (enrollment Save) — never on cold start, never on background
//   paths.
// - Signing authority stays hardware-bound: the HW device key
//   (StrongBox→TEE / Secure Enclave, HW-bound + attested +
//   challenge-bound, use-time ungated fleet-wide) + the live face check
//   per marking + the server-side single-device claim. The enrollment doc
//   itself is sealed-only (no raw seeds), so at-rest readability without
//   a prompt confers no signing ability.
//
// Why not Keystore-auth-bound keys (retired DKey grant included)?
// Field crash 2026-10-02: on KeyStore2-strict devices `cipher.init`
// throws `UserNotAuthenticatedException` BEFORE any BiometricPrompt can
// show; FSS v11 misclassifies it as corruption and its recovery path
// wiped all data into a fatal worker-thread crash loop. Auth-bound
// `cipher.init` semantics vary by OEM/keymaster, so the whole fleet can
// never rely on them. The DKey was Signature-based CryptoObject and did
// not share that crash — but ANY auth-bound keygen (CryptoObject grant
// included) fails on the Keystore2 LSKF UNINITIALIZED class
// (Xiaomi/Samsung Android 12+: lock + biometrics set, yet every
// auth-bound variant fails while the identical-challenge no-auth probe
// succeeds; no app-side policy tweak fixes it — see
// docs/hw-device-key-auth-policy-research.md), so the fleet default is
// now `UserAuthPolicy.none`: HW-held + attestable + challenge-bound,
// direct sign, never stranded by OS LSKF state, never invalidated by a
// biometric change.
//
// Guarantees:
// - Android: RSA-wrapped AES-GCM (plain `AndroidOptions`, no auth-bound
//   key), `storageNamespace: 'prox_store'` (fresh namespace — the old
//   `prox_enroll`/`prox_enroll_cred` AES-wrap markers must never be
//   reinterpreted under RSA wrap; testing phase, no migration).
// - iOS: Keychain, never synced (`synchronizable: false`),
//   `first_unlock_this_device` (no migration via backup/restore — closes
//   the clone-identity path with `allowBackup=false` on Android, see
//   AndroidManifest + res/xml/data_extraction_rules.xml). No biometric
//   access-control flag: iOS prompts would otherwise reintroduce the
//   cold-start ambush asymmetrically (Android prompt-free, iOS gated).
// - `resetOnError: false` everywhere (init/op failures surface as
//   errors, never wipe), `migrateOnAlgorithmChange: false`
//   (namespace-per-config is the migration strategy).
// - No `useSecureEnclave` flag here by design: flutter_secure_storage
//   has no such option (iOS security comes from the Keychain
//   accessibility/synchronizable above). Secure Enclave / StrongBox P-256
//   usage comes from `attested_secure_keys` via HwDeviceKey — never FSS.
// - Desktop/web fail-closed by construction: [SecureDeviceStore] is only
//   wired on mobile (see main.dart provider setup); records-only targets
//   get the fail-closed stubs and never persist enrollment secrets.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Public API for secure storage (callers depend on this class, never on
/// its internals).
class SecureStoreOptions {
  SecureStoreOptions._();

  /// Android: prompt-free RSA-wrapped AES-GCM in its own namespace.
  ///
  /// `storageNamespace: 'prox_store'` isolates data prefs, markers,
  /// KeyStore aliases and wrapped-key prefs from the seal store
  /// (`FlutterSealStore`, namespace `'prox_seal'`) — sharing one
  /// namespace flips algorithm markers and wipes the other store's data.
  static const aOpts = AndroidOptions(
    storageNamespace: 'prox_store',
    migrateOnAlgorithmChange: false,
    resetOnError: false,
  );

  /// iOS: Keychain, this-device-only, no sync, no biometric gate.
  static const iOpts = IOSOptions(
    synchronizable: false,
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
}
