'use strict';

// der.js unit vectors: hand-built DER, no PKI needed.
const test = require('node:test');
const assert = require('node:assert/strict');
const { DerReader, DerError, intValue, oidToString, findExtension } = require('../der');

const hex = (s) => Buffer.from(s.replace(/\s+/g, ''), 'hex');

test('reads INTEGER + ENUMERATED + OCTET STRING out of a SEQUENCE', () => {
  // SEQ { INT 3, ENUM 2, OCTET "AB" }
  const buf = hex('30 0A 02 01 03 0A 01 02 04 02 41 42');
  const seq = new DerReader(buf).readSequence();
  assert.equal(intValue(seq.readInteger()), 3);
  assert.equal(intValue(seq.readEnumerated()), 2);
  assert.deepEqual(seq.readOctetString(), Buffer.from('AB'));
  assert.ok(seq.done);
});

test('long-form lengths + high-tag context-specific skip', () => {
  // SEQ { [709] EXPLICIT OCTET STRING(200 x 0x55), INT 1 }
  const body = Buffer.alloc(200, 0x55);
  const inner = Buffer.concat([Buffer.from([0x04, 0x81, 0xc8]), body]);
  // Tag 709 high-tag form: BF 85 45; length covers the value only.
  const tag = Buffer.from([0xbf, 0x85, 0x45, 0x81, inner.length]);
  const tlv709 = Buffer.concat([tag, inner]);
  const seqBody = Buffer.concat([tlv709, Buffer.from([0x02, 0x01, 0x01])]);
  const buf = Buffer.concat([Buffer.from([0x30, 0x82]), Buffer.from([(seqBody.length >> 8) & 0xff, seqBody.length & 0xff]), seqBody]);
  const seq = new DerReader(buf).readSequence();
  const entry = seq.readTLV();
  assert.equal(entry.cls, 2);
  assert.equal(entry.num, 709);
  assert.equal(intValue(seq.readInteger()), 1);
});

test('OID decode incl. multi-byte arcs', () => {
  // 1.3.6.1.4.1.11129.2.1.17
  const buf = hex('06 0A 2B 06 01 04 01 D6 79 02 01 11');
  assert.equal(new DerReader(buf).readOid(), '1.3.6.1.4.1.11129.2.1.17');
  assert.equal(oidToString(Buffer.from([0x2a, 0x03])), '1.2.3');
});

test('truncated input throws DerError (fail closed, never partial)', () => {
  assert.throws(() => new DerReader(hex('30 09 02 01')).readSequence(), DerError);
  assert.throws(() => new DerReader(hex('02 05 01 02')).readInteger(), DerError);
});

test('findExtension locates an extension by OID in a real cert', async () => {
  // Built with openssl at test time: leaf carrying a marker extension.
  const { execFileSync } = require('node:child_process');
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'prox-der-'));
  try {
    execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', path.join(dir, 'k'), '-out', path.join(dir, 'r.pem'),
      '-days', '1', '-subj', '/CN=t'], { stdio: 'ignore' });
    execFileSync('openssl', ['req', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', path.join(dir, 'l.key'), '-out', path.join(dir, 'l.csr'),
      '-subj', '/CN=l'], { stdio: 'ignore' });
    fs.writeFileSync(path.join(dir, 'ext.cnf'), '1.2.3.4.5=DER:04:02:41:42\n');
    execFileSync('openssl', ['x509', '-req', '-in', path.join(dir, 'l.csr'),
      '-CA', path.join(dir, 'r.pem'), '-CAkey', path.join(dir, 'k'),
      '-CAcreateserial', '-days', '1', '-extfile', path.join(dir, 'ext.cnf'),
      '-out', path.join(dir, 'l.pem')], { stdio: 'ignore' });
    const crypto = require('crypto');
    const leafDer = new crypto.X509Certificate(fs.readFileSync(path.join(dir, 'l.pem'))).raw;
    const found = findExtension(leafDer, '1.2.3.4.5');
    // extnValue OCTET STRING contents: the wrapped DER `04 02 41 42`
    // (callers DER-decode one more layer — see parseKeyDescription).
    assert.deepEqual(found, hex('04 02 41 42'));
    assert.equal(findExtension(leafDer, '9.9.9.9'), null);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
