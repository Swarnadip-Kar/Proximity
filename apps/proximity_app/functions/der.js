'use strict';

// Minimal DER reader: just enough to walk X.509 certificates and the
// Android Key Attestation extension (OID 1.3.6.1.4.1.11129.2.1.17).
// No dependency: Node ships no ASN.1 parser, and pulling one in for five
// tag types would be heavier than this (~120 lines, fully tested).

class DerError extends Error {}

function readLength(buf, off) {
  const first = buf[off];
  if (first < 0x80) return { len: first, header: 1 };
  const n = first & 0x7f;
  if (n === 0 || n > 4) throw new DerError('unsupported DER length');
  let len = 0;
  for (let i = 0; i < n; i++) len = len * 256 + buf[off + 1 + i];
  return { len, header: 1 + n };
}

class DerReader {
  constructor(buf, start = 0, end = buf.length) {
    this.buf = buf;
    this.pos = start;
    this.end = end;
  }

  get done() {
    return this.pos >= this.end;
  }

  // Reads one TLV; returns { cls, constructed, num, value: Buffer }.
  // cls: 0 universal, 1 application, 2 context-specific, 3 private.
  readTLV() {
    if (this.pos >= this.end) throw new DerError('unexpected end of DER');
    const tagByte = this.buf[this.pos];
    const cls = (tagByte >> 6) & 0x03;
    const constructed = (tagByte & 0x20) !== 0;
    let num = tagByte & 0x1f;
    let off = this.pos + 1;
    if (num === 0x1f) {
      num = 0;
      let b;
      do {
        if (off >= this.end) throw new DerError('truncated high tag');
        b = this.buf[off++];
        num = num * 128 + (b & 0x7f);
      } while (b & 0x80);
    }
    const { len, header } = readLength(this.buf, off);
    const valueStart = off + header;
    const valueEnd = valueStart + len;
    if (valueEnd > this.end) throw new DerError('DER length overruns parent');
    this.pos = valueEnd;
    return { cls, constructed, num, value: this.buf.subarray(valueStart, valueEnd) };
  }

  expectUniversal(num) {
    const t = this.readTLV();
    if (t.cls !== 0 || t.num !== num) {
      throw new DerError(`expected universal tag ${num}, got cls=${t.cls} num=${t.num}`);
    }
    return t;
  }

  readSequence() {
    const t = this.expectUniversal(16);
    if (!t.constructed) throw new DerError('SEQUENCE must be constructed');
    return new DerReader(t.value);
  }

  readInteger() {
    const t = this.expectUniversal(2);
    return t.value; // big-endian two's complement; callers use intValue()
  }

  readEnumerated() {
    const t = this.expectUniversal(10);
    return t.value;
  }

  readOctetString() {
    const t = this.expectUniversal(4);
    return Buffer.from(t.value);
  }

  readOid() {
    const t = this.expectUniversal(6);
    return oidToString(t.value);
  }

  skip() {
    this.readTLV();
  }
}

function intValue(bytes) {
  let v = 0;
  for (const b of bytes) v = v * 256 + b;
  return v;
}

function oidToString(bytes) {
  if (bytes.length === 0) throw new DerError('empty OID');
  const out = [Math.floor(bytes[0] / 40), bytes[0] % 40];
  let v = 0;
  for (let i = 1; i < bytes.length; i++) {
    v = v * 128 + (bytes[i] & 0x7f);
    if ((bytes[i] & 0x80) === 0) {
      out.push(v);
      v = 0;
    }
  }
  return out.join('.');
}

// Finds an extension value by OID in a DER-encoded Certificate.
// Returns the extnValue OCTET STRING contents (still DER-encoded) or null.
function findExtension(certDer, oid) {
  const cert = new DerReader(certDer).readSequence(); // Certificate
  const tbs = cert.readSequence(); // tbsCertificate
  // Walk tbsCertificate fields in order: [serial..subjectPK..] then
  // optional [0] issuerUniqueID, [1] subjectUniqueID, [2] extensions.
  // Field shapes vary (version is [0] EXPLICIT), so scan TLVs: the
  // extensions block is context-specific constructed tag 3.
  while (!tbs.done) {
    const t = tbs.readTLV();
    if (t.cls === 2 && t.num === 3 && t.constructed) {
      const exts = new DerReader(t.value).readSequence();
      while (!exts.done) {
        const e = exts.readSequence();
        const eOid = e.readOid();
        // critical BOOLEAN DEFAULT FALSE: present only when TRUE.
        let next = e.readTLV();
        if (next.cls === 0 && next.num === 1) next = e.readTLV();
        if (next.cls !== 0 || next.num !== 4) throw new DerError('bad extnValue');
        if (eOid === oid) return Buffer.from(next.value);
      }
      return null;
    }
  }
  return null;
}

module.exports = { DerReader, DerError, intValue, oidToString, findExtension };
