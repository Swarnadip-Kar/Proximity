'use strict';

// Trust anchors. Android: Google's Hardware Attestation roots, baked from
// the authoritative source (developer.android.com/privacy-and-security/
// security-key-attestation, fetched 2026-09-07 — see roots/README.md for
// fingerprints + rotation procedure). iOS: the Apple App Attest root is a
// provisioned slot (roots/apple_appattest_root.pem or the
// APPLE_APPATTEST_ROOT_PEM env var) — NOT baked, because Apple publishes
// no stable fetchable URL for it; provisioning is a documented deploy step
// and a missing Apple root is a fail-closed server error (never a pass).

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOTS_DIR = __dirname + '/roots';

function readPem(name) {
  return fs.readFileSync(path.join(ROOTS_DIR, name), 'utf8');
}

function spkiHex(pem) {
  const cert = new crypto.X509Certificate(pem);
  return cert.publicKey.export({ format: 'der', type: 'spki' }).toString('hex');
}

let cache = null;

function loadTrust() {
  if (cache) return cache;
  const googleFiles = [
    'google_hw_rsa_2022.pem',
    'google_hw_rsa_2021.pem',
    'google_hw_rsa_2019.pem',
    'google_key_attestation_ca1.pem',
  ];
  const googleKeys = new Set(googleFiles.map((f) => spkiHex(readPem(f))));
  // Apple slot: file wins, env override for rotation without redeploy.
  let applePem = null;
  const applePath = path.join(ROOTS_DIR, 'apple_appattest_root.pem');
  if (process.env.APPLE_APPATTEST_ROOT_PEM) {
    applePem = process.env.APPLE_APPATTEST_ROOT_PEM.replace(/\\n/g, '\n');
  } else if (fs.existsSync(applePath)) {
    applePem = fs.readFileSync(applePath, 'utf8');
  }
  const appleKeys = new Set(applePem ? [spkiHex(applePem)] : []);
  cache = { googleKeys, appleKeys, applePresent: applePem !== null };
  return cache;
}

function clearTrustCache() {
  cache = null;
}

module.exports = { loadTrust, clearTrustCache, spkiHex };
