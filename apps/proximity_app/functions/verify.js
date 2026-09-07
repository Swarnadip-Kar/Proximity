'use strict';

// Device-attestation chain verification (the actual cryptography behind
// verifyAttestationChain). Pure functions over buffers/strings — no
// Firestore, no Auth — so they unit-test with an injected test PKI.
//
// Android: X.509 chain signatures up to a pinned Google root, validity at
// enrollment time, Key Attestation extension (OID 1.3.6.1.4.1.11129.2.1.17)
// challenge binding, StrongBox/TEE level mapping, leaf-key == pkD binding
// (P-256 X coordinate), attestationApplicationId (tag 709) package binding.
// iOS: App Attest CBOR object, x5c chain to the Apple root, RP ID hash,
// flags, zero counter, keyId binding, nonce =
// SHA256(authData || SHA256(challengeBytes)) binding, receipt presence.
// (The AAGUID is recorded, not enforced — dev vs prod AAGUID allocation
// is an Apple-side value we do not pin here; see README.)

const crypto = require('crypto');
const { DerReader, DerError, intValue, findExtension } = require('./der');
const { cborDecode, cborItemLength, CborError } = require('./cbor');

const OID_ANDROID_ATTESTATION = '1.3.6.1.4.1.11129.2.1.17';
const OID_APPLE_NONCE = '1.2.840.113635.100.8.2';
const TAG_ATTESTATION_APPLICATION_ID = 709;

// Keymaster security levels (attestationSecurityLevel ENUM).
const KM_SOFTWARE = 0;
const KM_TEE = 1;
const KM_STRONGBOX = 2;

function sha256Hex(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

function splitPems(text) {
  const blocks = String(text || '').match(/-----BEGIN CERTIFICATE-----[^-]+-----END CERTIFICATE-----/g);
  return blocks || [];
}

function parseChain(chainPems) {
  const blocks = Array.isArray(chainPems) ? chainPems.flatMap(splitPems) : splitPems(chainPems);
  if (blocks.length === 0) throw new Error('empty chain');
  return blocks.map((pem) => new crypto.X509Certificate(pem));
}

// Structural signature walk: every cert is signed by the next. Returns the
// leaf on success; throws a reason string on failure.
function verifyChainSignatures(certs) {
  for (let i = 0; i + 1 < certs.length; i++) {
    let ok = false;
    try {
      ok = certs[i].verify(certs[i + 1].publicKey);
    } catch (_) {
      ok = false;
    }
    if (!ok) throw 'chain-signature';
  }
  return certs[0];
}

function checkValidityAt(certs, atMs) {
  for (const c of certs) {
    const from = Date.parse(c.validFrom);
    const to = Date.parse(c.validTo);
    if (!(from <= atMs && atMs <= to)) throw 'cert-validity';
  }
}

function checkRootPin(certs, trustedSpkiHex) {
  const root = certs[certs.length - 1];
  const hex = root.publicKey.export({ format: 'der', type: 'spki' }).toString('hex');
  if (!trustedSpkiHex.has(hex)) throw 'unknown-root';
}

// P-256 X coordinate out of a leaf SPKI (SEQ{SEQ{OID ecPublicKey,
// OID prime256v1}, BIT STRING 0x00||0x04||X||Y}). Returns 32-byte Buffer
// or null when the leaf key is not P-256.
function p256XOfLeaf(leaf) {
  try {
    const spki = new DerReader(leaf.publicKey.export({ format: 'der', type: 'spki' })).readSequence();
    spki.readSequence(); // algorithm identifier
    const bit = spki.expectUniversal(3);
    const raw = Buffer.from(bit.value);
    if (raw.length !== 66 || raw[0] !== 0x00 || raw[1] !== 0x04) return null;
    return raw.subarray(2, 34);
  } catch (_) {
    return null;
  }
}

// Parses the KeyDescription SEQUENCE. Returns
// { secLevel, challenge: Buffer, teeEnforced: DerReader|null,
//   softwareEnforced: DerReader|null }.
function parseKeyDescription(extBytes) {
  const kd = new DerReader(extBytes).readSequence();
  kd.readInteger(); // attestationVersion
  const secLevel = intValue(kd.readEnumerated());
  kd.readInteger(); // keymasterVersion
  // keymasterSecurityLevel is ENUMERATED (same numbering as
  // attestationSecurityLevel). Consumed, not enforced: the level mapping
  // keys off attestationSecurityLevel only, so exotic-but-valid chains in
  // which the two differ are still verifiable (reviewable, not rejected).
  kd.readEnumerated(); // keymasterSecurityLevel
  const challenge = kd.readOctetString();
  kd.skip(); // uniqueId
  const sw = kd.readSequence();
  const tee = kd.readSequence();
  return { secLevel, challenge, softwareEnforced: sw, teeEnforced: tee };
}

// First packageName from an AuthorizationList containing tag 709
// (attestationApplicationId), or null when absent/unparseable.
function packageNameOf(authzList) {
  try {
    while (!authzList.done) {
      const entry = authzList.readTLV();
      if (entry.cls !== 2 || entry.num !== TAG_ATTESTATION_APPLICATION_ID) continue;
      const appIdBytes = new DerReader(entry.value).readOctetString();
      const appId = new DerReader(appIdBytes).readSequence();
      while (!appId.done) {
        const f = appId.readTLV();
        if (f.cls !== 2 || f.num !== 1) continue; // packageInfos [1]
        const set = new DerReader(f.value).expectUniversal(17); // SET
        const infos = new DerReader(set.value);
        if (infos.done) return null;
        const info = infos.readSequence();
        while (!info.done) {
          const pf = info.readTLV();
          if (pf.cls === 2 && pf.num === 1) {
            const nameTlv = new DerReader(pf.value).readTLV();
            if (nameTlv.cls === 0 && nameTlv.num === 12) {
              return Buffer.from(nameTlv.value).toString('utf8');
            }
          }
        }
        return null;
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}

function derivedLevelName(secLevel) {
  if (secLevel === KM_STRONGBOX) return 'FULL';
  if (secLevel === KM_TEE) return 'STD';
  return 'NONE';
}

// Android path. material: { chain: [pem...] | "pem bundle", pkg, challenge }.
function verifyAndroid({ material, pkDHex, attestationLevel, attestedAtMs }, trust) {
  const fail = (reason, detail) => ({ ok: false, reason, detail });
  let certs;
  try {
    certs = parseChain(material && material.chain);
  } catch (_) {
    return fail('bad-chain-pem');
  }
  try {
    verifyChainSignatures(certs);
    checkRootPin(certs, trust.googleKeys);
    checkValidityAt(certs, attestedAtMs);
  } catch (reason) {
    return fail(String(reason));
  }
  const leaf = certs[0];
  let kd;
  try {
    const ext = findExtension(leaf.raw, OID_ANDROID_ATTESTATION);
    if (!ext) return fail('missing-extension');
    kd = parseKeyDescription(ext);
  } catch (e) {
    if (e instanceof DerError) return fail('bad-extension');
    throw e;
  }
  // Challenge binding: the extension challenge must equal the enrollment
  // challenge the client stored (challengeBytes, base64 in material).
  const want = Buffer.from(String((material && material.challenge) || ''), 'base64');
  if (want.length === 0 || !want.equals(kd.challenge)) {
    return fail('challenge-mismatch');
  }
  // Level mapping: claimed FULL needs StrongBox; claimed STD accepts
  // StrongBox or TEE (understating is not an anomaly).
  const derived = derivedLevelName(kd.secLevel);
  const claimed = String(attestationLevel || 'NONE').toUpperCase();
  const rank = { NONE: 0, STD: 1, STANDARD: 1, FULL: 2 };
  if ((rank[claimed] || 0) > (rank[derived] || 0)) {
    return fail('level-mismatch', { claimed, derived });
  }
  if (derived === 'NONE') return fail('hw-not-present');
  // Key binding: the attested leaf key must be the bound DKey (P-256 X).
  const x = p256XOfLeaf(leaf);
  if (!x) return fail('key-type-mismatch');
  if (x.toString('hex') !== String(pkDHex || '').toLowerCase()) {
    return fail('key-mismatch');
  }
  // AppID binding: attestationApplicationId package must equal the
  // enrollment package (teeEnforced first, then softwareEnforced).
  const expectedPkg = String((material && material.pkg) || '');
  const gotPkg =
    packageNameOf(kd.teeEnforced) || packageNameOf(kd.softwareEnforced);
  if (!gotPkg) return fail('appid-missing');
  if (gotPkg !== expectedPkg) return fail('appid-mismatch', { gotPkg });
  return { ok: true, reason: 'chain-ok', derivedLevel: derived };
}

// iOS path. material: { object (b64 CBOR), keyId (b64), challenge (b64),
// rpId (bundle id) }.
function verifyIos({ material, attestedAtMs }, trust) {
  const fail = (reason, detail) => ({ ok: false, reason, detail });
  let obj;
  try {
    obj = cborDecode(Buffer.from(String((material && material.object) || ''), 'base64'));
  } catch (e) {
    if (e instanceof CborError) return fail('bad-object');
    throw e;
  }
  if (!obj || obj.fmt !== 'apple-appattest' || !obj.attStmt || !obj.authData) {
    return fail('bad-object');
  }
  const x5c = obj.attStmt.x5c;
  const receipt = obj.attStmt.receipt;
  if (!Array.isArray(x5c) || x5c.length === 0) return fail('bad-object');
  if (!receipt || receipt.length === 0) return fail('receipt-missing');
  let certs;
  try {
    certs = x5c.map((der) => new crypto.X509Certificate(Buffer.from(der)));
  } catch (_) {
    return fail('bad-chain-pem');
  }
  try {
    verifyChainSignatures(certs);
    checkRootPin(certs, trust.appleKeys);
    checkValidityAt(certs, attestedAtMs);
  } catch (reason) {
    return fail(String(reason));
  }
  const authData = Buffer.from(obj.authData);
  if (authData.length < 37) return fail('bad-object');
  const rpId = String((material && material.rpId) || '');
  const rpHash = crypto.createHash('sha256').update(rpId, 'utf8').digest();
  if (!rpHash.equals(authData.subarray(0, 32))) return fail('rpid-mismatch');
  const flags = authData[32];
  if ((flags & 0x01) === 0 || (flags & 0x40) === 0) return fail('flags');
  if (authData.readUInt32BE(33) !== 0) return fail('counter-nonzero');
  const aaguid = authData.subarray(37, 53).toString('hex');
  const credLen = authData.readUInt16BE(53);
  const credId = authData.subarray(55, 55 + credLen);
  const wantKeyId = Buffer.from(String((material && material.keyId) || ''), 'base64');
  if (wantKeyId.length === 0 || !wantKeyId.equals(credId)) {
    return fail('keyid-mismatch');
  }
  // authData ends after the embedded COSE key; its exact span is needed
  // for the nonce hash.
  const coseLen = cborItemLength(authData.subarray(55 + credLen));
  const fullAuthData = authData.subarray(0, 55 + credLen + coseLen);
  const clientHash = crypto
    .createHash('sha256')
    .update(Buffer.from(String((material && material.challenge) || ''), 'base64'))
    .digest();
  const nonce = crypto.createHash('sha256').update(fullAuthData).update(clientHash).digest();
  let extNonce = null;
  try {
    const ext = findExtension(certs[0].raw, OID_APPLE_NONCE);
    if (ext) {
      const seq = new DerReader(ext).readSequence();
      const tagged = seq.readTLV(); // [1] EXPLICIT nonce
      if (tagged.cls === 2 && tagged.num === 1) {
        extNonce = new DerReader(tagged.value).readOctetString();
      }
    }
  } catch (_) {
    extNonce = null;
  }
  if (!extNonce || !extNonce.equals(nonce)) return fail('nonce-mismatch');
  return { ok: true, reason: 'chain-ok', derivedLevel: 'FULL', detail: { aaguid } };
}

// Dispatches on the stored platform. Returns a verdict; never throws for
// bad input (every input failure is a named reason). Only server
// misconfiguration (missing Apple root) throws — the caller turns that
// into a non-verdict error so devices are never flagged for it.
function verifyDeviceMaterial(
  { platform, material, pkDHex, attestationLevel, attestedAtMs },
  trust,
) {
  const p = String(platform || '').toLowerCase();
  const claimed = String(attestationLevel || 'NONE').toUpperCase();
  if (claimed === 'NONE') {
    return { ok: true, reason: 'skipped-none', derivedLevel: 'NONE' };
  }
  if (!material || typeof material !== 'object') {
    return { ok: false, reason: 'missing-material' };
  }
  if (p.startsWith('android')) {
    return verifyAndroid({ material, pkDHex, attestationLevel, attestedAtMs }, trust);
  }
  if (p.startsWith('ios')) {
    if (!trust.applePresent) {
      const e = new Error('apple root not provisioned');
      e.code = 'roots-missing';
      throw e;
    }
    return verifyIos({ material, attestedAtMs }, trust);
  }
  return { ok: false, reason: 'unknown-platform', detail: { platform: String(platform || '') } };
}

module.exports = {
  verifyDeviceMaterial,
  verifyAndroid,
  verifyIos,
  splitPems,
  parseChain,
  sha256Hex,
  OID_ANDROID_ATTESTATION,
  OID_APPLE_NONCE,
};
