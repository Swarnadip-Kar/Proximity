# HW device key (DKey) fleet policy research — auth-bound → non-auth-bound

Decision: change Proximity's HW device key fleet default from auth-bound
(`UserAuthPolicy.timeBound(kHwDeviceKeyAuthValidity)` = 4h
biometric-or-credential) to non-auth-bound (`UserAuthPolicy.none`), one
policy for the whole fleet (NOT a per-device fallback).

This note records the pre-implementation research required by the task.
If any finding below contradicted the brief, implementation had to STOP.
Nothing contradicted — all three tracks confirm the switch is safe.

## (a) Android KeyGenParameterSpec — what auth-binding adds at USE time

Citable sources:

- Android Keystore system:
  https://developer.android.com/privacy-and-security/keystore
  - "Key material never enters the application process" and "Key material
    can be bound to the secure hardware of the Android device, such as
    the Trusted Execution Environment (TEE) or Secure Element (SE).
    When this feature is enabled for a key, its key material is never
    exposed outside of secure hardware."
  - Key-use authorizations are a separate category: "User authentication:
    the key can only be used if the user has been authenticated recently
    enough" (under "Key use authorizations"), alongside Cryptography and
    Temporal-validity categories.
  - "Require user authentication for key use" section: "This is an
    advanced security feature that is generally useful only if your
    requirements are that a compromise of your application process after
    key generation/import (but not before or during) can't bypass the
    requirement for the user to be authenticated to use the key."
  - Modes: "Authorize for a duration of time" vs "Authorize for the
    duration of a specific cryptographic operation" (each op authorized
    via `BiometricPrompt.authenticate()` with a `CryptoObject`).
- `KeyGenParameterSpec.Builder.setUserAuthenticationRequired`:
  https://developer.android.com/reference/android/security/keystore/KeyGenParameterSpec.Builder#setUserAuthenticationRequired(boolean)
  - "By default, the key is authorized to be used regardless of whether
    the user has been authenticated."
- Key and ID attestation (AOSP):
  https://source.android.com/docs/security/features/keystore/attestation
  - Attestation certificate carries `attestationChallenge` (set at key
    generation) plus `attestationSecurityLevel` / `keyMintSecurityLevel`
    and the hardware/software-enforced authorization lists
    (`noAuthRequired`, `userAuthType`, `authTimeout` are independently
    inspectable tags).
  - `attestKey` "is considered a public key operation on the attested
    key, because it can be called at any time and doesn't need to meet
    authorization constraints. For example, if the attested key needs
    user authentication for use, an attestation can be generated without
    user authentication."
- Verify hardware-backed key pairs:
  https://developer.android.com/privacy-and-security/security-key-attestation
  - Trust comes from the chain to the Google attestation root plus
    `attestationSecurityLevel` = `TrustedEnvironment`/`StrongBox` —
    independent of any auth timeout.

Finding: `setUserAuthenticationRequired(true)` binds only at USE time
(recent-auth grant or per-op `BiometricPrompt.CryptoObject`). Hardware
binding (TEE/StrongBox-held, non-exportable) and attestation (challenge-
bound chain to Google roots) prove on their own. Non-auth-bound keys
remain non-exportable, TEE/StrongBox-held, and attestable with a
challenge — dropping the auth requirement removes only the use-time
human-presence signal, nothing about hardware custody or attestation.

## (b) attested_secure_keys 0.1.1 Dart/plugin semantics

Pinned version: `attested_secure_keys: ^0.1.1` in
`apps/proximity_app/pubspec.yaml` (resolved
`~/.pub-cache/hosted/pub.dev/attested_secure_keys-0.1.1`,
`-platform_interface-0.1.1`, `-android-0.1.1`).

Read:

- `lib/src/attested_secure_keys_base.dart` (`AttestedSecureKeys` facade):
  `generateKey` "walks the fallback ladder (StrongBox → TEE → software
  on Android; Secure Enclave → software on iOS)"; "pass
  [attestationChallenge] (your server-issued nonce) to bind it into the
  Android key attestation at creation time"; `sign` "triggers the
  biometric/PIN prompt if the key is auth-gated" (conditional — ungated
  keys sign without a prompt).
- `attested_secure_keys_platform_interface-0.1.1/lib/src/options.dart`
  (`UserAuthPolicy`): "By default no authentication is required";
  `UserAuthPolicy.none` is the default constructor (`type = none`,
  `validity = zero`); `timeBound(duration)` is
  `biometricOrCredential + duration`.
- `.../lib/src/models.dart` (`HwKey`/`HwKeyInfo`): `gatedByUserAuth`
  reports what the OS enforces; `isHardwareBacked` (StrongBox / TEE /
  SE) and `hasHardwareAttestation` are independent of gating.
- `attested_secure_keys_android-0.1.1/.../AttestedSecureKeysPlugin.kt`:
  - Ladder: `(StrongBox+attestation) → (TEE+attestation) → (TEE, no
    attestation) → software`, first success wins; floor enforced after
    (`rank(effective) < rank(minLevel)` deletes + throws
    `unsupported_security_level`).
  - `applyUserAuth` NONE path: `if (policy.type == NONE) return` — never
    calls `setUserAuthenticationRequired(true)`.
  - "Gating requested but NOT enforced" fail-closed branch:
    `requestedGating = (type != NONE)`; `actuallyGated` read back from
    `KeyInfo.isUserAuthenticationRequired`; `if (requestedGating &&
    !actuallyGated)` deletes the key + throws. Requesting `none` sets
    `requestedGating = false`, so it can NEVER trip this branch.
  - `sign` path: `gated = keyInfo?.isUserAuthenticationRequired`;
    ungated signs directly on the background queue thread (no
    `BiometricPrompt`); gated authorizes the `Signature` inside a
    `BiometricPrompt.CryptoObject`. Gating is read LIVE per key, so one
    code path serves old auth-bound and new ungated keys.
  - `attest` returns the generation-time chain verbatim (challenge was
    fixed at `generate` via `setAttestationChallenge`).

Finding: `UserAuthPolicy.none` in `generateKey` produces a HW-held,
attested, challenge-bound key with `gatedByUserAuth == false`; `sign()`
on it is direct (no `BiometricPrompt.CryptoObject`); requesting `none`
cannot trip the fail-closed branch. Mixed-fleet prove works because the
plugin reads gating live per key at sign time.

## (c) Failure record — LSKF super-encryption UNINITIALIZED

Citable sources:

- Stack Overflow 78260329:
  https://stackoverflow.com/questions/78260329/android-keystore-lskf-is-not-setup-for-the-user
  - `ProviderException: Failed to generate key pair` ← `KeyStoreException:
    Keystore not initialized (internal Keystore code: 3 …/security_level.rs…
    In generate_key… Failed to handle super encryption…
    …/super_key.rs… Failed to super encrypt with LskfBound key…
    …LSKF is not setup for the user… UNINITIALIZED)`. Reporter: resetting
    the lock-screen PIN/password did not help.
- `KeyStoreException.ERROR_KEYSTORE_UNINITIALIZED`:
  https://developer.android.com/reference/android/security/KeyStoreException
  - "an attempt has been made to generate an authorization bound key
    while the user has not set a lock screen knowledge factor (LSKF)."
- Keystore2 super-key source:
  `platform/system/security keystore2/src/super_key.rs` (via
  https://android.googlesource.com/platform/system/security/+/refs/heads/main/keystore2/src/super_key.rs)
  - Per-user LSKF-derived super keys (`after_first_unlock`,
    `UnlockedDeviceRequired`); `UserState::Uninitialized` →
    `UNINITIALIZED ("User … does not have super keys")`.
- AOSP issuetracker 399653576 (as documented in
  `apps/proximity_app/lib/core/enrollment.dart` generateKey catch +
  prior commit `2679312 fix(enroll): align LSKF failure copy with AOSP
  issuetracker findings`): Google-confirmed Keystore2 LSKF state for an
  Android user goes bad so EVERY auth-bound keygen fails while Settings
  still shows PIN+fingerprint; Android 12 work-profile deletion leaves
  this persistent bad per-user state (fixed for fresh A13+, not cleaned
  by OTA); also seen on Xiaomi/Samsung without profiles, sometimes
  surviving factory reset. No app-side policy tweak works around it
  (Okta + 3 years of Sentry reports found none) — only device-state
  procedures, none guaranteed.

Our probe matrix matches that signature exactly:

- Field case: Redmi Note 9 Pro Max, Android 12 / API 31, TEE-only,
  lock + fingerprint set.
- Production bind (`trustedEnvironment` floor + 4h
  biometric-or-credential) fails deterministically across installs;
  the identical-challenge no-auth bisect probe
  (`UserAuthPolicy.none`, same alias family / challenge / floor,
  throwaway alias, always deleted — `enrollment.dart` ~L818–864)
  succeeds; STRONG-only and short-window variants also fail.
- Diagnosis: per-user LSKF backend unusable → ANY auth-bound keygen
  fails. Screen-copy honesty rule in the same catch: only blame a
  missing lock when the preflight observed one missing; `deviceSecure ==
  true` + auth-blocked = lock IS set and this phone's KeyMint rejects
  the policy.

## Product requirements driving the switch (preserved in code/docs)

- (i) No student may be stranded by OS LSKF state.
- (ii) Changing biometrics must NEVER force re-enrollment (auth-bound
  keys invalidate on biometric enrollment change by OS design;
  non-auth-bound keys do not).
- Auth-binding's marginal value HERE is small: lent-phone proxy, theft,
  and clones already die at per-marking face check + one-device claim +
  non-migrating Keystore. What it uniquely added (second human-presence
  signal + use-time theft resistance) is outweighed by the LSKF failure
  class, forced re-enrollment on every new fingerprint, and per-window
  prompts. Unlike Okta-style systems we have live face verification, so
  their must-keep-auth-binding constraint does not transfer.
- New posture: HW-bound + attested + challenge-bound, use-time ungated;
  presence covered by face-per-marking and explicit Save-time presence
  (`UserPresenceGate` at enrollment Save, unchanged).

## Conclusion

(a) Non-auth-bound keys stay HW-held, non-exportable, attestable.
(b) `UserAuthPolicy.none` is a clean ungated path that cannot trip the
plugin's fail-closed branch, and the sign path serves both key kinds.
(c) Our field failure is the documented LSKF UNINITIALIZED class with a
matching probe matrix. No contradiction — proceed with the fleet-wide
switch (no per-device fallback, no migration code; old auth-bound keys
keep working until their holders next re-enroll; prove reads gating
live per key).
