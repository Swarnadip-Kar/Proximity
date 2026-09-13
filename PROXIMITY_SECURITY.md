# Proximity — Security Hardening Master Document

**Version:** 1.0 (2026-09-12)
**Scope:** Flutter monorepo `apps/proximity_app + packages/protocol/ble/transport/storage`, Firebase Spark free, no custom backend, offline-first marking.
**Companions:** `PROXIMITY_DESIGN.md` (product truth), `apps/proximity_app/firestore.rules` (server truth), this file (security truth).
**Constraints (locked):** Spark-free only (no Blaze Functions, no TTL policy). Marking 100% offline after one-time online setup. Android+iOS mobile-only for keys/face; desktop/web fail-closed. No IMEI/serial/phone-ID. No raw seeds at rest. No silent downgrades.

---

## 1. Audit — flaws in the original system (all fixed; kept as history)

> Status 2026-09-13 (sec-legacy series, full-fresh): F1 sealed-only
> (`seedHex` field deleted, AAD-bound HW envelopes, raw branches deleted);
> F2 closed (offline chain-vs-pinned-roots + leaf-pkD bind, NONE/unbound
> never confirm). Findings below describe the pre-hardening system.

### F1 — Raw `seedHex` at rest + XOR seal (CRITICAL, FIXED)
- `packages/.../store_base.dart:22 StoredEnrollment.seedHex`, `core/enrollment.dart:741` writes `seedHex:hexEncode(seed)` **always**, even when `sealedKeyHex` exists.
- `core/enrollment.dart:308 _tryRestore` legacy raw branch; `core/student_driver.dart:753 _prove` raw fallback.
- `features/face_identity/device_key.dart:156 SoftwareDeviceKey.seal()` is XOR-with-pubkey, not AES-GCM. `SoftwareDeviceKey` is production, `level==none`.
- Effect: copy `prox.enrollment.v1` + prefs → full clone. Backup/restore clones identity. Fix: §2 + §3.

### F2 — Self-asserted attestation (HIGH, FIXED)
- Design §3.4 honest: no chain verification anywhere. `attestationLevel` written by client in `firestore_sync.dart:claimStudentDevice:426`, trusted by `protocol/device_binding.dart:evaluateDeviceProof` + `crypto/verify.dart:verifyProve`.
- Patched client claims `FULL` with software key. Only mitigations today: `device-none-fallback` flag + `audit-double-pkD` + ticket binding. Fix: §2 (HW keys + offline chain-vs-pinned-roots).

### F3 — Default secure storage (HIGH, fixed — historical)
- Was: `core/sync/store/secure_store.dart:30 const FlutterSecureStorage()` — no `AndroidOptions.biometric`, no `IOSOptions(synchronizable:false, thisDeviceOnly, biometryCurrentSet)`, `allowBackup` not disabled.
- Now: `SecureStoreOptions` (`aOpts` biometric Class-3 only + `iOpts`
  `first_unlock_this_device_only`/`synchronizable:false`/`biometryCurrentSet`)
  + `allowBackup=false`/`fullBackupContent=false`/`data_extraction_rules.xml`
  + `Info.plist` `NSFaceIDUsageDescription` ship. History/outbox in plaintext
  `SharedPreferences` remains (rooted read residual — HW seal DEK never lives
  there). Fix: §3.

### F4 — No liveness classifier (HIGH)
- `features/face_identity/face_verifier.dart`: passive FaceNet matcher only. 5 pose gates raise cost but photo-at-each-angle still passes (design §4 residual).
- `student_driver.dart:308,536 livenessPass:true` hardcoded. Score is decision-boundary constant (`score==threshold` on match) — host cannot grade strength. Fix: §4.

### F5 — No root/hook/emulator/tamper/AppCheck (HIGH)
- No `firebase_app_check`, no root/jailbreak/Frida/Xposed/debugger/emulator/tamper package. `AndroidManifest.xml` lacks `allowBackup=false`, screenshots not blanked.
- Frida hook on `verify()`→`true` or `seedHex` read undetected. Fix: §5.
- Status (2026-09-13 docs close-out): FIXED in code — `allowBackup=false` +
  `fullBackupContent=false` + `data_extraction_rules.xml` ship;
  `FLAG_SECURE` set in `MainActivity.kt` (window blanked in screenshots —
  manifest never holds it, so "manifest lacks FLAG_SECURE" notes are stale);
  `IntegrityGate` + `IntegrityAppCheck` (`firebase_app_check ^0.4.7`,
  `flutter_security_suite ^1.1.1`) ship with console runbook in
  `integrity.dart`. Residual: Magisk/Zygisk hiding (see §5 + DESIGN §13.5).

### F6 — No force-update (MEDIUM)
- No `app_config/min_version`, no `package_info_plus` gate. Ticket/rules/verifier breaks fail as cryptic `bad-sig`/`face-unbound`; attacker pins old APK to bypass new gates. Fix: §6.

### F7 — Over-permissive trust assumptions (MEDIUM)
- `firestore.rules:callerIsProf()` reads self-writable `users/{uid}.roles` → any Gmail self-registers `prof`, enumerates `studentDirectory` (emails/names/rolls). `classSessions` create is self-asserted (by design — no institute PKI — but must stay documented).
- No field-type locks for future `attestationChain/livenessVer/integrityFlag`. In-memory `RateLimiter` resets on restart. TLS per-session cert is first-connect TOFU (mitigated by `Sig_p` + channel binding, residual stated). History JSON unsigned locally. Fix: §5 + §6 + §7.

---

## 2. HW-bound device keys (`HwDeviceKey`)

**Research:** Android Keystore StrongBox→TEE + key attestation (`developer.android.com/privacy-and-security/security-key-attestation`, AOSP `source.android.com/docs/security/features/keystore/attestation`, KeyMint/StrongBox CDD 9.11.2); `KeyGenParameterSpec.setUserAuthenticationRequired(true)+setInvalidatedByBiometricEnrollment(true)` + `BiometricPrompt.CryptoObject` (`developer.android.com/identity/sign-in/biometric-auth`); iOS Secure Enclave + App Attest/DeviceCheck; Flutter plugin `attested_secure_keys ^0.1.1` (StrongBox→TEE / Secure Enclave, P-256 ES256, challenge-bound, chain passthrough — pubspec pins `^0.1.1`; `^0.1.0` references elsewhere in older notes are stale). M1 gap (in-app biometric CryptoObject prompt + server-nonce-as-challenge) → bind `challenge=SHA256(emailLower||installId||pkS32)` client-side for now.

**New file (only importer of the plugin):**
- `apps/proximity_app/lib/features/device_identity/hw_device_key.dart` — `class HwDeviceKey implements DeviceKey` (P-256, non-exportable, ES256; Android StrongBox→TEE with `setUserAuthenticationRequired`, iOS Secure Enclave `biometryCurrentSet`; exposes `pkDHex+chainDER+level/window`; `Software=no enroll`).

**Diffs:**
- `features/face_identity/device_key.dart`: delete prod `SoftwareDeviceKey` (keep test-only behind `kDebugMode` assert); keep `UnavailableDeviceKey` (desktop/web fail-closed); `deviceKeyProvider` wired to `HwDeviceKey` on mobile.
- `core/enrollment.dart:generateKey/upload/_tryRestore`: `generateKey` → `ensure()` + `if(level==none) throw Software-no-enroll`; `upload` seals via HW (AES-GCM), persists `sealedKeyHex+pkDHex+chainDER`, never writes `seedHex`; `_tryRestore` deletes raw branch, only `unseal(sealedKeyHex)`.
- `core/student_driver.dart:_prove:747`: delete `else fromSeed(seedHex)`; `sealedKeyHex.isEmpty → error('re-enroll')`.
- `core/sync/store/store_base.dart:StoredEnrollment`: deprecate `seedHex` (parse-compat, write `''`), add `chainDERHex, level, window`.
- `packages/protocol/src/device_binding.dart + crypto/verify.dart + crypto/primitives.dart + chain_verify.dart`: `deviceProvePreimage` unchanged (already P-256 contract); professor pre-fetches pinned binding when online, offline runs full X.509 chain verification in pure Dart (`chain_verify.dart:verifyChainSignaturesLeafFirst` — each TBS signature vs issuer SPKI, RSA PKCS#1 v1.5 + ECDSA P-256/P-384, root self-signed + SHA-256 hash-pin pre-gate; fail-closed `bad-chain-signature`/`bad-root-signature`/`bad-chain-der`/`unsupported-sigalg`/`unsupported-key`/`issuer-mismatch`) as step 6 of `verifyAttestationChainPin` (`verifySignatures:true` in production — never the platform adapter), plus the pin gates (Android Key Attestation `OID 1.3.6.1.4.1.11129.2.1.17`, `level>=TEE`, challenge match; iOS via App Check with `requireKeyOid:false`), TOFU→pin-check. Revocation is a snapshot side-channel only: `RevocationCache` (`core/security/revocation_cache.dart`, TTL 7d) refreshed best-effort at one-time online setup (`core/enrollment.dart:724`, `core/host_driver.dart:412`); `revocation-stale`/`revocation-revoked` are professor-review flags, never blocks.

## 3. Secure storage

**Research:** `flutter_secure_storage ^11.0.0` (Aug 2026): `AndroidOptions.biometric(enforceBiometrics:true, biometricType:strongBiometricOnly)` (Class-3 only, PIN rejected), `AES_GCM_NoPadding` Keystore-based; `IOSOptions(synchronizable:false, accessibility:first_unlock_this_device_only, accessControlFlags:[biometryCurrentSet])`; never `local_auth bool` alone (forgeable — `biometric_security` analysis).

**New file:** `lib/core/security/secure_store_options.dart` (`aOpts/iOpts` constants above).

**Diffs:** `secure_store.dart:30` → `FlutterSecureStorage(aOptions:aOpts,iOptions:iOpts)`; `AndroidManifest.xml: application android:allowBackup="false" android:fullBackupContent="false"`; iOS `Info.plist: NSFaceIDUsageDescription + kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Migration (completed one-time): SE-read → if old-default hit, SE-write → old-delete; log `SEC migrate ok`; never dual-retain.

## 4. Face liveness (`LivenessGate`)

**Research:** vendored MiniFASNetV2 (`2.7_80x80`, Apache-2.0 Silent-Face-Anti-Spoofing, TFLite via `tflite_flutter ^0.12.1`, 1.85MB at `assets/models/silentface-minifasnetv2-27-80x80.tflite`) + ML Kit face-box crop; active enroll walk (blink+smile shuffled order binds presence, NOT measured vitality). Rejected: commercial license-key SDKs; `flutter_face_liveness` / `face_anti_spoofing_detector` plugin references in older notes are stale — no such deps ship (pubspec has neither).

**Shipped API (not the `detect(File,box)` sketch in older notes):** `lib/features/face_identity/liveness_gate.dart` — `LivenessGate.detectPassive(imagePath)→LivenessResult{score,ver}` fail-closed + `HeuristicLivenessGate` fallback + `EnrollLivenessPlan` shuffle; tag `kLivenessVer = liveness/minifasnet-v2-27-80x80+<weightsHash8>`; input `[1,3,80,80]` float32 NCHW BGR/255, output `[1,3]` LIVE index 1.

**Diffs:** gate in `face_verifier.dart / student_driver.dart:checkFace` before `verify()`; enroll = active blink+smile shuffled + passive centre-still; marking = passive only (~1s). Extend `ProxCrypto.faceTicketHash` → `SHA256(scoreMilli||faceValidAt||verifierVerHash8||livenessMilli||livenessVerHash8)[0:8]`; `Sig_s+dSig` bind it; `VerifyRequest` adds `livenessScore/livenessVer`; host gates `>=T_l` + allowlist. Old tickets fail `bad-sig` (no silent downgrade).

## 5. Root/tamper + integrity (App Check)

**Research:** `firebase_app_check ^0.4.7` (firebase.google.com, Aug 2026: 0.4.x provider-class API — `AndroidPlayIntegrityProvider` + `AppleAppAttestWithDeviceCheckFallbackProvider` via `IntegrityAppCheck.ensureActivated()` / `activate(providerAndroid:/providerApple:)`; the 0.3.x enum params are deprecated; Spark-compatible, console enforcement); `flutter_security_suite` (MIT: RootBeer/su + IOSSecuritySuite + emulator + Frida port/maps + Xposed/debugger + tamper SHA-256 + `FLAG_SECURE`) superset of `jailbreak_root_detection ^1.2.3` / `trust_fall` / `security_plus`. Console: SHA-256/bundleID → Play Integrity `DEVICE→STRONG` + App Attest → App Check Monitor→Enforce → `min_version` bump (requires console access; ordered runbook in `integrity.dart` `IntegrityAppCheck` docs).

**New file:** `lib/core/security/integrity.dart` — `performCheck()` (startup) + `verifyBeforeSensitiveOp(op)` (enroll/host/prove) → `IntegrityVerdict{rooted,hooked,tampered,emulator,debug,hash}`. Probe is `PlatformIntegrityProbe` over `flutter_security_suite ^1.1.1` (`SecureBankKit.runSecurityCheck` → `SecurityStatus`; 8s `probeBudget`; per-signal mapping in file docs; `com.securebankkit/security` `feature#action` channel pinned by `integrity_gate_test:291-322`; debug-alone never blocks enroll — `isAppIntegrityValid` gated `&& !kDebugMode` so dev/sideloaded builds don't false-taint).

**Diffs:** `main/entry_flow`: `activate(AppCheck)` before Firestore, `performCheck()` at startup; enroll hard-blocks `privileged/hooked/tampered/emulator`; marking binds `verdictHash` into `dSig`, professor flags `integrity-flagged` (never auto-absent offline).

## 6. Force update

**New:** `lib/core/app_config/force_update.dart` + Firestore `app_config/min_version {minVersion,latest,force,msg,storeAndroid,storeIos}` (`allow get:true`).

**Diffs:** check in `entry_flow/host/enroll` via `package_info_plus`; `force && current<minVersion` → non-dismissible barrier (`barrierDismissible:false` + `PopScope(canPop:false)`) with copyable store links (copy-to-clipboard text, no `url_launcher` — "store buttons" in older notes = copy-link + Recheck actions, never auto-launch). Bump on any ticket/rules/verifier break. Remote Config rejected (extra dep, same guarantee, extra quota). `force` is strict bool (strings incl. `"true"` never gate); `compareVersions` currently strips pre/build for migration leniency (`1.2.3-beta == 1.2.3` pinned by test) — strict pre<release ships with the golden update + `min_version` bump.

## 7. Schema / offline (additive only)

Keep `studentDevices/directory/{emailLower}, users/{uid}, deviceInstalls/{uuid}, classSessions/{randomId}`. Only adds: `attestationChain (list<string> DER hex), livenessVer (string), integrityFlag (string)`. Marking stays `BLE Cj(5s)+Sig_s+dSig(HW)+face/liveness+pin+sighting→ACK`; sync later `PRESENT/ABSENT/FLAGGED` only. Zero face vectors/images to cloud.

**Rules diff (append, existing gates untouched — matches `firestore.rules:234-242 + 395-397`):**
```
match /app_config/{id} { allow get: if true; allow list,write: if false; }
match /studentDevices/{id} { // create/update: + pkDHex is string
  && (!('attestationChain' in request.resource.data) || request.resource.data.attestationChain is list)
  && (!('livenessVer' in request.resource.data) || request.resource.data.livenessVer is string)
  && (!('integrityFlag' in request.resource.data) || request.resource.data.integrityFlag == '' || request.resource.data.integrityFlag == 'integrity-flagged')
  && (!('pkDHex' in request.resource.data) || request.resource.data.pkDHex is string) }
```
App Check enforcement is console toggle (no rules syntax on Spark).
Opaque handling: chain/pkD bytes are type-checked only here — never
decrypted/interpreted server-side (no backend exists to do so).

**Pubspec (app — as-built, `apps/proximity_app/pubspec.yaml`):**
```yaml
attested_secure_keys: ^0.1.1 # HW DKey (StrongBox→TEE / Secure Enclave)
flutter_secure_storage: ^11.0.0
firebase_app_check: ^0.4.7 # 0.4.x provider-class API
flutter_security_suite: ^1.1.1 # PINNED (not ^latest)
tflite_flutter: ^0.12.1 # vendored MiniFASNetV2 only (no flutter_face_liveness / face_anti_spoofing_detector — older notes naming them are stale)
package_info_plus: ^10.2.1 # (was ^8: win32 ^5→^6 split with fss ^11)
share_plus: ^13.3.0 # (was ^12: same win32 split)
file_picker: ^12.0.0 # (was ^11: same win32 split; Darwin floor → iOS 14)
```

**Migration order (completed; full-fresh since 2026-09-13):** (1) deploy rules + `app_config` doc; (2) ship dual-read build (new fields default `''/NONE`); (3) first online open: SE migration + `seedHex` field deletion + heartbeat rolls `attestedUntil`; (4) stale-pipeline → re-face only (key kept); (5) software enrollments → `Software=no enroll` + re-enroll via `MoveIntent` fast path. No wipe, no cloud face backfill. The sec-legacy series then deleted every grace (org/backfill/NONE-fallback/empty-AAD/pk-fallback/single-role-mirror/seedHex-field): org-less, tier-less, AAD-less, and mirror artifacts deny fail-closed, never migrate.

**Tests:** protocol goldens (old sigs must fail on extended preimage); `evaluateDeviceProof` chain-pinning units; SE migration test; `LivenessGate` fake (spoof→`faceFailed`); `IntegrityGate` fake (rooted enroll blocks, marking flags); `force_update` fake (stale→barrier); `rules-drill` emulator for new fields; 2-phone relay + adversarial drill (forwarded code, VPN, lent phone, photo spoof, wormhole).

**Verification log (2026-09-12, `Security-Enhancement`):** suites green — protocol 138, transport 51, storage 12, ble 35, app 983 (`flutter test`, incl. new `liveness_attestation`, `secure_store_options`, `force_update`, `integrity_gate`, `liveness_gate` cases). Live rules drill 8/8 vs Firestore emulator (`apps/proximity_app/rules-drill/sec-drill.mjs`, `@firebase/rules-unit-testing`): valid claim allows; `attestationChain:string`, `integrityFlag:'evil'`, `livenessVer:number` deny; same-device `integrity-flagged` update allows; minimal field-less claim allows (security fields optional-with-type-lock; org/installId/stamps always required); `app_config` unauth get allows, list denies. Drill needs JDK 21 for firebase-tools (system Temurin 17 rejected — portable JDK via `api.adoptium.net/v3/binary/latest/21/ga/mac/aarch64/jdk/hotspot/normal/eclipse`, point `JAVA_HOME` at it; 200 MB, deleted after the run, re-fetch to re-drill).

**`requireLiveness` (always enforced, no opt-out):** the bound path requires a non-zero liveness score + allowlisted `livenessVer` (`server requireLivenessEnforced=true`); pre-liveness proofs fail `liveness-unbound`, never a silent downgrade. Pre-fresh history: shipped default `false` during rollout, flipped with the liveness-required `min_version` bump; closed behavior pinned by tests. Full-fresh 2026-09-13: no legacy path remains.

**Verification log (2026-09-13, `sec-docs` close-out):** code landed by sibling tracks, docs closed here — (a) X.509 full verify (`chain_verify.dart` + `verifyAttestationChainPin` step 6, pure-Dart, no platform adapter); (b) App Check 0.4.x provider-class migration (`IntegrityAppCheck` provider constants + `ensureActivated()` call shape, `firebase_app_check ^0.4.7`); STRONG enforce runbook verified present in `integrity.dart` `IntegrityAppCheck` docs (commit `7de0d2e`); (c) CRL snapshot wired (`RevocationCache`, `core/enrollment.dart:724` + `core/host_driver.dart:412`, TTL 7d). Open work is field/console-only: Tl uncalibrated, CRL snapshot-only, Magisk console steps — see residual risks. No thresholds changed, no FAR/FRR numbers claimed.

**Residual risks:** rooted live-hook can observe plaintext at use time (HW raises to live-hook cost); integrity heuristics bypassable by Magisk/Zygisk (never sole gate — HW `dSig` still required; hide-resistance close-out is console-side: Play Console SHA-256/bundleID → Play Integrity `DEVICE→STRONG` + App Attest → App Check Monitor→Enforce → `min_version` bump, requires console access); twins flag dup (1-tap override); wormhole with real-time accomplice + live face needs UWB to close; first-join TLS TOFU relies on `Sig_p` + channel binding; in-memory rate limits reset on prof restart; liveness is always gated (no opt-out window remains — a photo-spoof must beat the live gate plus face/ticket/radio gates); `Tl=0.70` uncalibrated (FAR/FRR unmeasured — calibration needs field captures: live + print/replay, varied light/phones, ROC sweep via `sweepTl`/`recommendTl`/`formatCalibrationTable` in `apps/proximity_app/test/liveness_calibration_test.dart`; ships only as threshold + `kLivenessVer` + `min_version` bump); CRL is snapshot-only offline (true push revocation needs a backend, excluded by Spark-free — stale/revoked stay review flags).

---

## 8. Subagent implementation schedule

Phases are dependency-ordered. Phase 0 (this doc) done. Phases 1–2 run parallel; Phase 3 integrates; Phase 4 verifies.

| Phase | Subagent | Owns (exclusive files) | Depends | Done when |
|---|---|---|---|---|
| 1A | `sec-protocol` | `packages/protocol/src/crypto/primitives.dart, crypto/verify.dart, device_binding.dart` + protocol tests | — | extended ticket goldens green, old sigs fail |
| 1B | `sec-store-config` | `apps/.../core/security/secure_store_options.dart, core/app_config/force_update.dart, AndroidManifest.xml, Info.plist, pubspec.yaml` (options + `package_info_plus` only) | — | options compile, force-update fake test green |
| 2A | `sec-hwkey` | `features/device_identity/hw_device_key.dart, features/face_identity/device_key.dart, core/enrollment.dart, core/student_driver.dart:_prove, core/sync/store/store_base.dart` | 1A (preimage contract) | `seedHex` writers deleted, `Software=no enroll`, restore test green |
| 2B | `sec-liveness` | `features/face_identity/liveness_gate.dart, face_verifier.dart, student_driver.dart:checkFace, faceTicketHash wiring` | 1A | spoof→fail-closed, ticket binds `livenessVer` |
| 2C | `sec-integrity` | `core/security/integrity.dart, main.dart, features/entry/entry_flow.dart, firestore.rules:app_config, console AppCheck` | 1B | enroll blocks rooted, marking flags, AppCheck enforced |
| 3 | `sec-sync` | `core/sync/firestore_sync.dart:claimStudentDevice, firestore.rules:studentDevices validation, host_driver verify wiring` | 2A+2B+2C | claim carries `chain/liveness/integrity`, offline verify green |
| 4 | `sec-verify` | `rules-drill/`, full `flutter test`, `analyze`, adversarial checklist | 3 | all suites + drill green, residual log updated |

Handoff rule: each agent exports its public API (`HwDeviceKey`, `LivenessGate.detect`, `IntegrityGate.verifyBeforeSensitiveOp`, `SecureStoreOptions`, `ForceUpdate.check`) — callers depend on the API, never on internals. No two agents edit the same file concurrently (see exclusive owns above); `pubspec.yaml` edits via 1B only (others request versions through 1B).
