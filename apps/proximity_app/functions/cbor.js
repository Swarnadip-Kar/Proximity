'use strict';

// Minimal CBOR decoder: the subset needed for iOS App Attest attestation
// objects (maps, arrays, byte/text strings, unsigned + negative ints,
// booleans). No dependency for the same reason as der.js. Encoder lives
// only in test/ (vectors), never in the verify path.

class CborError extends Error {}

function readArg(buf, off, ai) {
  if (ai < 24) return { v: ai, next: off };
  if (ai === 24) return { v: buf[off], next: off + 1 };
  if (ai === 25) return { v: buf.readUInt16BE(off), next: off + 2 };
  if (ai === 26) return { v: buf.readUInt32BE(off), next: off + 4 };
  if (ai === 27) return { v: Number(buf.readBigUInt64BE(off)), next: off + 8 };
  throw new CborError(`unsupported CBOR arg ${ai}`);
}

function decodeOne(buf, off) {
  if (off >= buf.length) throw new CborError('truncated CBOR');
  const ib = buf[off];
  const mt = ib >> 5;
  const ai = ib & 0x1f;
  if (mt === 0 || mt === 1) {
    const { v, next } = readArg(buf, off + 1, ai);
    return { v: mt === 0 ? v : -1 - v, next };
  }
  if (mt === 2 || mt === 3) {
    const { v: len, next } = readArg(buf, off + 1, ai);
    if (next + len > buf.length) throw new CborError('CBOR string overrun');
    const slice = buf.subarray(next, next + len);
    return { v: mt === 2 ? Buffer.from(slice) : slice.toString('utf8'), next: next + len };
  }
  if (mt === 4) {
    const { v: n, next } = readArg(buf, off + 1, ai);
    const out = [];
    let p = next;
    for (let i = 0; i < n; i++) {
      const r = decodeOne(buf, p);
      out.push(r.v);
      p = r.next;
    }
    return { v: out, next: p };
  }
  if (mt === 5) {
    const { v: n, next } = readArg(buf, off + 1, ai);
    const out = {};
    let p = next;
    for (let i = 0; i < n; i++) {
      const k = decodeOne(buf, p);
      const val = decodeOne(buf, k.next);
      out[String(k.v)] = val.v;
      p = val.next;
    }
    return { v: out, next: p };
  }
  if (mt === 7) {
    if (ai === 20) return { v: false, next: off + 1 };
    if (ai === 21) return { v: true, next: off + 1 };
    if (ai === 22) return { v: null, next: off + 1 };
    throw new CborError(`unsupported CBOR simple ${ai}`);
  }
  throw new CborError(`unsupported CBOR major type ${mt}`);
}

function cborDecode(buf) {
  const { v, next } = decodeOne(Buffer.from(buf), 0);
  if (next !== buf.length) throw new CborError('trailing bytes after CBOR item');
  return v;
}

// Byte length of the single CBOR item at the start of [buf] (used to find
// the end of the embedded COSE key inside App Attest authData).
function cborItemLength(buf) {
  const { next } = decodeOne(Buffer.from(buf), 0);
  return next;
}

module.exports = { cborDecode, cborItemLength, CborError };
