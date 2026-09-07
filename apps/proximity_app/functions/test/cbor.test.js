'use strict';

// cbor.js unit vectors: hand-encoded CBOR, no PKI needed.
const test = require('node:test');
const assert = require('node:assert/strict');
const { cborDecode, cborItemLength, CborError } = require('../cbor');

const hex = (s) => Buffer.from(s.replace(/\s+/g, ''), 'hex');

test('ints, strings, bool, arrays, maps', () => {
  assert.equal(cborDecode(hex('18 2A')), 42); // uint 42
  assert.equal(cborDecode(hex('39 03 E7')), -1000); // nint
  assert.equal(cborDecode(hex('44 01 02 03 04')).length, 4); // bstr
  assert.equal(cborDecode(hex('63 666F6F')), 'foo'); // tstr "foo"
  assert.deepEqual(cborDecode(hex('83 01 02 03')), [1, 2, 3]);
  assert.deepEqual(cborDecode(hex('A2 61 61 01 61 62 F5')), { a: 1, b: true });
});

test('nested attestation-object shape decodes', () => {
  // { "fmt": "apple-appattest", "n": 7 }
  const buf = hex('A2 63 666D74 6F 6170706C652D617070617474657374 61 6E 07');
  const v = cborDecode(buf);
  assert.equal(v.fmt, 'apple-appattest');
  assert.equal(v.n, 7);
});

test('cborItemLength spans nested items exactly', () => {
  const buf = hex('A2 63 666D74 6F 6170706C652D617070617474657374 61 6E 07  FF');
  assert.equal(cborItemLength(buf), buf.length - 1); // trailing 0xFF excluded
});

test('truncated / trailing input throws (fail closed)', () => {
  assert.throws(() => cborDecode(hex('83 01 02')), CborError);
  assert.throws(() => cborDecode(hex('01 02')), CborError);
});
