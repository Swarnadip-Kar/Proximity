'use strict';

// verify.js end-to-end vectors with a throwaway test PKI (openssl CLI builds
// the certs, so the parser/verifier prove themselves against real native-
// generated certificates — not against their own fixtures). The test root
// is injected as the trust anchor; production roots are never touched.
// Requires the `openssl` CLI (skipped explicitly when absent).

const test = require('node:test');
const { before } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { verifyDeviceMaterial, verifyAndroid, verifyIos } = require('../verify');
const { spkiHex } = require('../roots');

let OPENSSL = true;
try {
  execFileSync('openssl', ['version'], { stdio: 'ignore' });
} catch (_) {
  OPENSSL = false;
}

// Shared throwaway PKI for the whole file (built once — RSA root keygen
// dominates per-test time). State declared up here because the hook below
// closes over it. Tests never depend on each other's state, only on this
// hook.
let DIR;
let ROOT_PEM;
let ROOT_KEY;
let TRUST;
before(() => {
  if (OPENSSL) setupPki();
});

// ---------- test-only DER writer ----------
function encodeLen(n) {
  if (n < 128) return Buffer.from([n]);
  const b = [];
  let x = n;
  while (x > 0) {
    b.unshift(x & 0xff);
    x = Math.floor(x / 256);
  }
  return Buffer.from([0x80 | b.length, ...b]);
}
const tlv = (tags, content) =>
  Buffer.concat([Buffer.from(tags), encodeLen(content.length), Buffer.from(content)]);
const SEQ = (...p) => tlv([0x30], Buffer.concat(p));
const SET = (...p) => tlv([0x31], Buffer.concat(p));
const INT = (n) => tlv([0x02], [n]);
const ENUM = (n) => tlv([0x0a], [n]);
const OCT = (b) => tlv([0x04], b);
const UTF8 = (s) => tlv([0x0c], Buffer.from(s, 'utf8'));
const CTX = (n, c) => tlv([0xa0 | n], c);
function CTX_HIGH(n, c) {
  const groups = [];
  let x = n;
  do {
    groups.unshift(x & 0x7f);
    x = Math.floor(x / 128);
  } while (x > 0);
  const body = groups.map((g, i) => (i + 1 < groups.length ? g | 0x80 : g));
  return tlv([0xbf, ...body], c);
}
const colonHex = (buf) => [...Buffer.from(buf)].map((b) => b.toString(16).padStart(2, '0')).join(':');

// KeyDescription (Android): SEQ { v INT, sec ENUM, kmv INT, kms ENUM,
// challenge OCT, uniqueId OCT, sw SEQ, tee SEQ([709] EXPLICIT appId?) }.
function keyDescDer({ secLevel, challenge, pkg, withAppId = true }) {
  const appId = SEQ(CTX(1, SET(SEQ(CTX(1, UTF8(pkg)), CTX(2, INT(1))))));
  const tee = withAppId ? SEQ(CTX_HIGH(709, OCT(appId))) : SEQ();
  return SEQ(INT(3), ENUM(secLevel), INT(41), ENUM(secLevel), OCT(challenge), OCT(Buffer.alloc(0)), SEQ(), tee);
}

// Apple nonce extension value: SEQ { [1] EXPLICIT OCTET STRING(nonce) }.
const appleNonceDer = (nonce) => SEQ(CTX(1, OCT(nonce)));

// ---------- test-only CBOR writer ----------
function cborHead(n, mt) {
  if (n < 24) return Buffer.from([(mt << 5) | n]);
  if (n < 256) return Buffer.from([(mt << 5) | 24, n]);
  if (n < 65536) {
    const b = Buffer.alloc(3);
    b[0] = (mt << 5) | 25;
    b.writeUInt16BE(n, 1);
    return b;
  }
  const b = Buffer.alloc(5);
  b[0] = (mt << 5) | 26;
  b.writeUInt32BE(n, 1);
  return b;
}
function enc(v) {
  if (typeof v === 'number') return cborHead(v >= 0 ? v : -1 - v, v >= 0 ? 0 : 1);
  if (typeof v === 'string') {
    const b = Buffer.from(v, 'utf8');
    return Buffer.concat([cborHead(b.length, 3), b]);
  }
  if (Buffer.isBuffer(v)) return Buffer.concat([cborHead(v.length, 2), v]);
  if (Array.isArray(v)) return Buffer.concat([cborHead(v.length, 4), ...v.map(enc)]);
  if (v && typeof v === 'object') {
    const ks = Object.keys(v);
    const parts = [cborHead(ks.length, 5)];
    for (const k of ks) parts.push(enc(/^-?\d+$/.test(k) ? Number(k) : k), enc(v[k]));
    return Buffer.concat(parts);
  }
  if (v === true) return Buffer.from([0xf5]);
  if (v === false) return Buffer.from([0xf4]);
  if (v === null) return Buffer.from([0xf6]);
  throw new Error('cbor enc: bad value');
}

// ---------- test PKI (state declared beside the hook above) ----------
function openssl(args) {
  execFileSync('openssl', args, { stdio: 'ignore' });
}

function setupPki() {
  DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'prox-att-'));
  ROOT_KEY = path.join(DIR, 'root.key');
  ROOT_PEM = path.join(DIR, 'root.pem');
  openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', ROOT_KEY,
    '-out', ROOT_PEM, '-days', '30', '-subj', '/CN=ProxTestRoot']);
  const rootPemText = fs.readFileSync(ROOT_PEM, 'utf8');
  const spki = spkiHex(rootPemText);
  TRUST = { googleKeys: new Set([spki]), appleKeys: new Set([spki]), applePresent: true };
}

function ecKeypair() {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const jwk = publicKey.export({ format: 'jwk' });
  const x = Buffer.from(jwk.x, 'base64url');
  const y = Buffer.from(jwk.y, 'base64url');
  return { privateKey, publicKey, x, y, point: Buffer.concat([Buffer.from([0x04]), x, y]) };
}

// Signs the keypair into a leaf carrying extension (oid -> DER hex), chaining to ROOT.
function issueLeaf(keypair, oidDerPairs) {
  const keyPath = path.join(DIR, `k${Math.random().toString(36).slice(2)}.pem`);
  const csrPath = `${keyPath}.csr`;
  const outPath = `${keyPath}.crt`;
  fs.writeFileSync(keyPath, keypair.privateKey.export({ format: 'pem', type: 'pkcs8' }));
  openssl(['req', '-new', '-key', keyPath, '-out', csrPath, '-subj', '/CN=leaf']);
  const extPath = `${keyPath}.cnf`;
  fs.writeFileSync(extPath, oidDerPairs.map(([oid, der]) => `${oid}=DER:${colonHex(der)}`).join('\n') + '\n');
  openssl(['x509', '-req', '-in', csrPath, '-CA', ROOT_PEM, '-CAkey', ROOT_KEY,
    '-CAcreateserial', '-days', '30', '-extfile', extPath, '-out', outPath]);
  return fs.readFileSync(outPath, 'utf8');
}

const OID_AND = '1.3.6.1.4.1.11129.2.1.17';
const OID_NONCE = '1.2.840.113635.100.8.2';
const PKG = 'org.iitbhilai.proximity';
const NOW = Date.now();

function androidMaterial({ secLevel = 2, challenge = crypto.randomBytes(32), pkg = PKG, withAppId = true, level = 'FULL' } = {}) {
  const kp = ecKeypair();
  const leafPem = issueLeaf(kp, [[OID_AND, keyDescDer({ secLevel, challenge, pkg, withAppId })]]);
  return {
    material: {
      chain: [leafPem, fs.readFileSync(ROOT_PEM, 'utf8')],
      pkg,
      challenge: challenge.toString('base64'),
    },
    pkDHex: kp.x.toString('hex'),
    level,
  };
}

const AAGUID = Buffer.alloc(16, 0xab);
function iosFixture({ rpId = 'org.iitbhilai.proximity', challenge = crypto.randomBytes(32), counter = 0, receipt = Buffer.from([9]) } = {}) {
  const kp = ecKeypair();
  const coseKey = enc({ 1: 2, 3: -7, '-1': 1, '-2': kp.x, '-3': kp.y });
  const head = Buffer.concat([
    crypto.createHash('sha256').update(rpId, 'utf8').digest(),
    Buffer.from([0x41]),
    (() => {
      const b = Buffer.alloc(4);
      b.writeUInt32BE(counter, 0);
      return b;
    })(),
    AAGUID,
    (() => {
      const b = Buffer.alloc(2);
      b.writeUInt16BE(kp.point.length, 0);
      return b;
    })(),
    kp.point,
    coseKey,
  ]);
  const clientHash = crypto.createHash('sha256').update(challenge).digest();
  const nonce = crypto.createHash('sha256').update(head).update(clientHash).digest();
  const leafPem = issueLeaf(kp, [[OID_NONCE, appleNonceDer(nonce)]]);
  const leafDer = new crypto.X509Certificate(leafPem).raw;
  const rootDer = new crypto.X509Certificate(fs.readFileSync(ROOT_PEM, 'utf8')).raw;
  const object = enc({ fmt: 'apple-appattest', attStmt: { x5c: [leafDer, rootDer], receipt }, authData: head });
  return {
    material: {
      object: object.toString('base64'),
      keyId: kp.point.toString('base64'),
      challenge: challenge.toString('base64'),
      rpId,
    },
  };
}

// ---------- Android ----------
test('android: genuine StrongBox chain verifies (FULL)', { skip: !OPENSSL }, () => {
  const { material, pkDHex } = androidMaterial();
  const r = verifyAndroid({ material, pkDHex, attestationLevel: 'FULL', attestedAtMs: NOW }, TRUST);
  assert.deepEqual(r, { ok: true, reason: 'chain-ok', derivedLevel: 'FULL' });
});

test('android: understated claim (STD on StrongBox hw) still passes', { skip: !OPENSSL }, () => {
  const { material, pkDHex } = androidMaterial({ level: 'STD' });
  const r = verifyAndroid({ material, pkDHex, attestationLevel: 'STD', attestedAtMs: NOW }, TRUST);
  assert.equal(r.ok, true);
});

test('android: TEE chain fails a FULL claim, passes STD', { skip: !OPENSSL }, () => {
  const { material, pkDHex } = androidMaterial({ secLevel: 1 });
  assert.equal(verifyAndroid({ material, pkDHex, attestationLevel: 'FULL', attestedAtMs: NOW }, TRUST).reason, 'level-mismatch');
  assert.equal(verifyAndroid({ material, pkDHex, attestationLevel: 'STD', attestedAtMs: NOW }, TRUST).ok, true);
});

test('android negatives: challenge / pkg / key / root / validity / appid', { skip: !OPENSSL }, () => {
  const good = androidMaterial();
  const base = { pkDHex: good.pkDHex, attestationLevel: 'FULL', attestedAtMs: NOW };
  assert.equal(
    verifyAndroid({ ...base, material: { ...good.material, challenge: crypto.randomBytes(32).toString('base64') } }, TRUST).reason,
    'challenge-mismatch');
  assert.equal(
    verifyAndroid({ ...base, material: { ...good.material, pkg: 'com.evil.clone' } }, TRUST).reason,
    'appid-mismatch');
  assert.equal(
    verifyAndroid({ ...base, pkDHex: '00'.repeat(32), material: good.material }, TRUST).reason,
    'key-mismatch');
  assert.equal(
    verifyAndroid({ ...base, material: good.material },
      { googleKeys: new Set(), appleKeys: new Set(), applePresent: true }).reason,
    'unknown-root');
  assert.equal(
    verifyAndroid({ ...base, attestedAtMs: NOW + 60 * 86400 * 1000, material: good.material }, TRUST).reason,
    'cert-validity');
  const noAppId = androidMaterial({ withAppId: false });
  assert.equal(
    verifyAndroid({ pkDHex: noAppId.pkDHex, attestationLevel: 'FULL', attestedAtMs: NOW, material: noAppId.material }, TRUST).reason,
    'appid-missing');
  const noExt = (() => {
    const kp = ecKeypair();
    const leafPem = issueLeaf(kp, []);
    return {
      material: { chain: [leafPem, fs.readFileSync(ROOT_PEM, 'utf8')], pkg: PKG, challenge: 'eA==' },
      pkDHex: kp.x.toString('hex'),
    };
  })();
  // Empty ext list: openssl writes no extensions -> missing-extension.
  // (If openssl ever requires >=1 ext, this vector fails loudly, not silently.)
  const rNoExt = verifyAndroid({ pkDHex: noExt.pkDHex, attestationLevel: 'FULL', attestedAtMs: NOW, material: noExt.material }, TRUST);
  assert.equal(rNoExt.reason, 'missing-extension');
});

test('android: chain signed by an attacker key fails (chain-signature)', { skip: !OPENSSL }, () => {
  const atkKey = path.join(DIR, 'atk.key');
  const atkPem = path.join(DIR, 'atk.pem');
  openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', atkKey, '-out', atkPem, '-days', '30', '-subj', '/CN=ProxTestRoot']);
  const kp = ecKeypair();
  const keyPath = path.join(DIR, 'evil.key');
  fs.writeFileSync(keyPath, kp.privateKey.export({ format: 'pem', type: 'pkcs8' }));
  openssl(['req', '-new', '-key', keyPath, '-out', `${keyPath}.csr`, '-subj', '/CN=leaf']);
  const challenge = crypto.randomBytes(32);
  fs.writeFileSync(`${keyPath}.cnf`, `${OID_AND}=DER:${colonHex(keyDescDer({ secLevel: 2, challenge, pkg: PKG }))}\n`);
  openssl(['x509', '-req', '-in', `${keyPath}.csr`, '-CA', atkPem, '-CAkey', atkKey,
    '-CAcreateserial', '-days', '30', '-extfile', `${keyPath}.cnf`, '-out', `${keyPath}.crt`]);
  const evilLeaf = fs.readFileSync(`${keyPath}.crt`, 'utf8');
  // Attacker presents the evil leaf but anchors to the REAL root: the
  // signature walk must fail, not the pin check.
  const r = verifyAndroid(
    { material: { chain: [evilLeaf, fs.readFileSync(ROOT_PEM, 'utf8')], pkg: PKG, challenge: challenge.toString('base64') },
      pkDHex: kp.x.toString('hex'), attestationLevel: 'FULL', attestedAtMs: NOW },
    TRUST);
  assert.equal(r.reason, 'chain-signature');
});

// ---------- iOS ----------
test('ios: genuine attestation object verifies', { skip: !OPENSSL }, () => {
  const { material } = iosFixture();
  const r = verifyIos({ material, attestedAtMs: NOW }, TRUST);
  assert.equal(r.ok, true);
  assert.equal(r.reason, 'chain-ok');
});

test('ios negatives: rpId / counter / nonce / receipt / keyId', { skip: !OPENSSL }, () => {
  const good = iosFixture();
  const base = { attestedAtMs: NOW };
  assert.equal(verifyIos({ ...base, material: { ...good.material, rpId: 'com.evil.clone' } }, TRUST).reason, 'rpid-mismatch');
  const badChallenge = iosFixture({ challenge: crypto.randomBytes(32) });
  // Right shape, wrong challenge -> nonce mismatch. (Build the object with
  // challenge A but declare challenge B.)
  const mixed = { ...good.material, challenge: badChallenge.material.challenge };
  assert.equal(verifyIos({ ...base, material: mixed }, TRUST).reason, 'nonce-mismatch');
  const counted = iosFixture({ counter: 1 });
  assert.equal(verifyIos({ ...base, material: counted.material }, TRUST).reason, 'counter-nonzero');
  const noReceipt = iosFixture({ receipt: Buffer.alloc(0) });
  assert.equal(verifyIos({ ...base, material: noReceipt.material }, TRUST).reason, 'receipt-missing');
  const wrongKey = iosFixture();
  assert.equal(
    verifyIos({ ...base, material: { ...good.material, keyId: wrongKey.material.keyId } }, TRUST).reason,
    'keyid-mismatch');
});

test('ios: missing Apple root throws roots-missing (never a device flag)', { skip: !OPENSSL }, () => {
  const { material } = iosFixture();
  const noApple = { googleKeys: TRUST.googleKeys, appleKeys: new Set(), applePresent: false };
  assert.throws(
    () => verifyDeviceMaterial({ platform: 'ios', material, pkDHex: '', attestationLevel: 'FULL', attestedAtMs: NOW }, noApple),
    (e) => e.code === 'roots-missing');
});

// ---------- dispatch ----------
test('dispatch: NONE skips, missing material / unknown platform fail closed', () => {
  const trust = { googleKeys: new Set(), appleKeys: new Set(), applePresent: false };
  assert.deepEqual(
    verifyDeviceMaterial({ platform: 'android', material: null, pkDHex: '', attestationLevel: 'NONE', attestedAtMs: NOW }, trust),
    { ok: true, reason: 'skipped-none', derivedLevel: 'NONE' });
  assert.equal(
    verifyDeviceMaterial({ platform: 'android', material: null, pkDHex: '', attestationLevel: 'FULL', attestedAtMs: NOW }, trust).reason,
    'missing-material');
  assert.equal(
    verifyDeviceMaterial({ platform: 'windows', material: {}, pkDHex: '', attestationLevel: 'STD', attestedAtMs: NOW }, trust).reason,
    'unknown-platform');
});
