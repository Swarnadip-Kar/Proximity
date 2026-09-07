# Trust roots

## Google Hardware Attestation roots (baked)

Fetched 2026-09-07 from the authoritative source,
`https://developer.android.com/privacy-and-security/security-key-attestation`
(section "Root certificates": "The following two root certificates should
be used as trust anchors…" plus previously-issued, still-valid roots).
The endpoint pins trust by root PUBLIC KEY (SPKI SHA-256), not by subject
or file — the three RSA files below carry one key re-issued across
validity windows, so they are effectively one anchor plus the ECDSA CA1.

| file | subject | validity | SPKI SHA-256 |
|---|---|---|---|
| google_hw_rsa_2022.pem | serialNumber=f92009e853b6b045 | 2022-03-20 → 2042-03-15 | `feb2ea75…4580fbae` |
| google_hw_rsa_2021.pem | serialNumber=f92009e853b6b045 | 2021-11-17 → 2036-11-13 | `feb2ea75…4580fbae` (same key) |
| google_hw_rsa_2019.pem | serialNumber=f92009e853b6b045 | 2019-11-22 → 2034-11-18 | `feb2ea75…4580fbae` (same key) |
| google_key_attestation_ca1.pem | CN=Key Attestation CA1, OU=Android, O=Google LLC, C=US | 2025-07-17 → 2035-07-15 | `3ee44512…676cd07ec` |

(Full fingerprints: RSA `feb2ea7551ee316ed4bb443c8293b884dbfdea40b603ee3e4f4a897e4580fbae`,
ECDSA `3ee44512a1af2beb39c889490c60ea3f82e43f5d5a5532f5ab9419f676cd07ec` —
recompute with `openssl x509 -in <file> -noout -pubkey | openssl pkey
-pubin -outform DER | openssl dgst -sha256`.)

Deliberately EXCLUDED: the 2016 RSA root (expired 2026-05-24) — chains
rooted there fail the validity-at-enrollment check with reason
`cert-validity`, which is the correct verdict for them.

Rotation: when Google publishes a new root, drop its PEM in this
directory, add the filename to the `googleFiles` list in `roots.js`,
redeploy. No client change needed.

## Apple App Attest root (provisioned slot — NOT baked)

Apple publishes no stable fetchable URL for the App Attest root, so this
repo does not vendor a copy whose provenance cannot be verified. To
enable iOS verification:

1. Obtain the Apple App Attest root certificate (via your Apple
   developer account / Apple's DeviceCheck documentation — the same root
   Apple's "Validating apps that connect to your server" sample trusts).
2. Place the PEM at `roots/apple_appattest_root.pem` (committed, like the
   Google roots), or set the `APPLE_APPATTEST_ROOT_PEM` function config
   for rotation without redeploy.
3. Redeploy the function.

Until then, iOS FULL/STD verifications return `failed-precondition`
(`roots-missing`): clients defer and retry later. Devices are never
flagged and chains are never passed on a missing root.
