'use strict';

// verifyAttestationChain — the ONE server endpoint in this project.
//
// Narrow scope (deliberate, see functions/README.md): it re-verifies the
// calling device's STORED attestation material (studentDevices/{emailLower}
// attestMaterialJson) against the baked Google roots / provisioned Apple
// root, then admin-writes ONLY {attestationAnomaly, serverVerifiedAtMillis}
// on that same doc. It never reads or writes attendance, never blocks the
// live/offline path (clients call it from SyncEngine's sync-on-reconnect
// flush only), and failure flags the device for professor/admin review —
// it never retroactively invalidates attendance.
//
// v1 onCall (not v2): the v1 callable URL
// (https://us-central1-<project>.cloudfunctions.net/verifyAttestationChain)
// is stable and documented, so the Flutter client can invoke it over plain
// HTTPS without the cloud_functions plugin (which has no Windows/Linux
// build — the app compiles for both). Low volume (~1 call per device per
// attestation window) needs nothing v2 would add.

const admin = require('firebase-admin');
const functions = require('firebase-functions');
const { verifyDeviceMaterial } = require('./verify');
const { loadTrust } = require('./roots');

function tokenOrg(email) {
  const e = String(email || '').trim().toLowerCase();
  const at = e.lastIndexOf('@');
  if (at <= 0 || at === e.length - 1) return '';
  return e.substring(at + 1);
}

let _db = null;
function db() {
  if (!_db) {
    try {
      admin.initializeApp();
    } catch (_) {
      // initializeApp throws when already initialized in warm instances.
    }
    _db = admin.firestore();
  }
  return _db;
}

async function decideForDevice({ deviceSnap, nowMs, trust }) {
  const d = deviceSnap.data() || {};
  const verdict = verifyDeviceMaterial(
    {
      platform: d.platform || '',
      material: parseMaterial(d.attestMaterialJson),
      pkDHex: d.pkDHex || '',
      attestationLevel: d.attestationLevel || 'NONE',
      attestedAtMs: Number(d.attestedAtMillis) || nowMs,
    },
    trust,
  );
  return verdict;
}

function parseMaterial(raw) {
  if (raw === undefined || raw === null || raw === '') return null;
  if (typeof raw === 'object') return raw;
  try {
    return JSON.parse(String(raw));
  } catch (_) {
    return null;
  }
}

exports.verifyAttestationChain = functions
  .region('us-central1')
  .https.onCall(async (data, context) => {
    if (!context.auth || !context.auth.token || !context.auth.token.email) {
      throw new functions.https.HttpsError('unauthenticated', 'Sign in first.');
    }
    const email = String(context.auth.token.email).toLowerCase();
    const nowMs = Date.now();
    const ref = db().doc(`studentDevices/${email}`);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new functions.https.HttpsError('not-found', 'No enrolled device for this account.');
    }
    const stored = snap.data() || {};
    // Org discipline: the caller verifies its own same-org binding only.
    // Legacy org-less docs verify anyway (they predate org stamping).
    const org = stored.org || '';
    if (org !== '' && org !== tokenOrg(email)) {
      throw new functions.https.HttpsError('permission-denied', 'Cross-org verify refused.');
    }
    const trust = loadTrust();
    let verdict;
    try {
      verdict = await decideForDevice({ deviceSnap: snap, nowMs, trust });
    } catch (e) {
      // Server misconfiguration (e.g. Apple root not provisioned): NOT a
      // device anomaly — surface an error so the client defers and retries
      // later instead of flagging an innocent device.
      if (e && e.code === 'roots-missing') {
        throw new functions.https.HttpsError('failed-precondition', String(e.message));
      }
      throw e;
    }
    // Admin write: clients cannot set these fields themselves (see
    // firestore.rules — client writes that change attestationAnomaly or
    // serverVerifiedAtMillis are denied). Attendance is untouched.
    await ref.update({
      attestationAnomaly: !verdict.ok,
      serverVerifiedAtMillis: nowMs,
      serverVerifyReason: verdict.reason,
    });
    return {
      verified: true,
      anomaly: !verdict.ok,
      reason: verdict.reason,
      derivedLevel: verdict.derivedLevel || null,
      serverVerifiedAtMillis: nowMs,
      org,
    };
  });

// Exported for unit tests (pure logic; no Firestore/Auth needed).
exports._test = { decideForDevice, parseMaterial, tokenOrg };
