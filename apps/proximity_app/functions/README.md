# functions — verifyAttestationChain (the ONE server endpoint)

This directory is the project's narrow, one-purpose exception to
serverless-direct Firestore: a single callable Cloud Function,
`verifyAttestationChain`, that independently re-verifies a calling
device's stored attestation chain. See PROXIMITY_DESIGN.md §"Server
attestation re-verification" for the amendment statement and the Track 5
review-screen handoff. Nothing else lives here, and nothing else may be
added without revisiting that amendment.

## Why Cloud Functions (v1 callable) — and not Cloud Run / v2

- The job is Firestore-coupled admin writes with Firebase Auth context.
  A callable provides verified `context.auth` (uid + email) with zero
  token plumbing; Cloud Run would need manual ID-token verification plus
  service wiring for no benefit.
- v1, not v2: the v1 callable URL
  (`https://us-central1-<project>.cloudfunctions.net/verifyAttestationChain`)
  is stable and documented, so the Flutter client invokes it over plain
  HTTPS without the `cloud_functions` plugin (which has no Windows/Linux
  build — the app compiles for both). Volume (~1 call per device per
  attestation window) needs nothing v2 would add.

## Contract

- Auth: required. The caller verifies exactly one doc:
  `studentDevices/{lowercased caller email}`.
- Org: the doc's `org` must equal the caller's email domain (legacy
  org-less docs verify anyway — they predate stamping).
- Writes (Admin SDK, bypasses rules): ONLY `attestationAnomaly`,
  `serverVerifiedAtMillis`, `serverVerifyReason` on that same doc.
  Clients cannot write these fields themselves (firestore.rules denies
  any client write that changes them). Attendance collections are never
  read or written.
- Failure semantics: a completed verification with a negative verdict
  sets `attestationAnomaly: true` + stamps `serverVerifiedAtMillis` —
  the device/install is flagged for professor/admin review. Attendance
  already recorded under valid offline trust is NEVER retroactively
  invalidated.
- Non-verdicts (unauthenticated, no device doc, cross-org, or server
  misconfiguration such as a missing Apple root) THROW instead of
  writing a flag — the client treats these as "defer, retry later"
  (offline discipline), never as anomalies. A device is never flagged
  for a server-side problem.

## Stored material schema (`attestMaterialJson` on the device doc)

Written by the client at enrollment (empty until the HW keystore/Enclave
track lands — see "Remains" below). One JSON object, platform-interpreted:

- Android: `{"chain": ["-----BEGIN CERTIFICATE-----...", ...],
  "pkg": "org.iitbhilai.proximity", "challenge": "<base64>"}`
  `chain` is the Key Attestation chain leaf-first; `challenge` is the
  exact enrollment challenge bytes whose SHA-256… no — the raw challenge
  bytes placed in the attestation request (`attestationChallenge` must
  equal them); `pkg` must equal the attestationApplicationId package.
- iOS: `{"object": "<base64 CBOR attestation object>",
  "keyId": "<base64 credential id>", "challenge": "<base64>",
  "rpId": "org.iitbhilai.proximity"}`
  The clientData hash is `SHA256(challenge)` and the leaf nonce must
  equal `SHA256(authData || clientDataHash)`; `rpId` is the bundle id.

`attestationLevel NONE` short-circuits to `skipped-none` (pass + stamp:
nothing to verify, and the offline path already treats NONE as
device-unproven → manual path).

## Trust roots (roots/)

Google's Hardware Attestation roots are baked (fetched 2026-09-07 from
the authoritative doc page — see roots/README.md for fingerprints).
Apple's App Attest root is a provisioned slot: place the PEM at
`roots/apple_appattest_root.pem` (or set `APPLE_APPATTEST_ROOT_PEM`)
before deploying iOS verification; while absent, iOS FULL/STD devices
get a `failed-precondition` error (client defers — never a flag, never
a pass). Apple publishes no stable fetchable URL for this root; the
provisioning step is documented in roots/README.md.

## Deploy

```
firebase deploy --only functions:verifyAttestationChain --project proximity-attendence
```

Emulator drill (rules + function, no prod writes):

```
firebase emulators:start --only firestore,functions --project proximity-attendence
```

## Tests

```
npm install && npm test   # node:test, zero test deps; needs the `openssl` CLI
```

Vectors build a throwaway PKI with native-generated certs (leaf chains
with crafted attestation/nonce extensions): Android FULL/STD mapping,
challenge/AppID/key/root/validity negatives, attacker-signed chain,
iOS RP ID/counter/nonce/receipt/keyId negatives, roots-missing
fail-closed, and the NONE/missing-material/unknown-platform dispatch.

## Remains (explicit escalation, not TODOs)

1. Apple root provisioning (one file — see roots/README.md).
2. On-device material persistence: the HW keystore/Enclave enrollment
   (deferred platform work) must store `attestMaterialJson` at claim
   time; until it does, HW-claiming devices without material verify as
   `missing-material` (flagged, attendance untouched).
3. Revocation (CRL / status checks) is out of scope for the prototype:
   chains verify structurally + validity-at-enrollment; stolen-device
   response is the existing 7-day move bound + manual attendance.
