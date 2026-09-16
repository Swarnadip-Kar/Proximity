// Local attestation self-check units (pure helper, no device): skip
// rules mirror the server, failures name the cause for enroll/mark copy.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/attestation_self_check.dart';

void main() {
  test('unbound legacy proofs skip (nothing to pre-check)', () {
    final r = checkAttestationChain(
      chainHex: const [],
      attestationLevel: 'NONE',
      emailLower: 's@x.in',
      installId: 'iA',
      pkSHex: 'aa',
      pkDHex: '',
    );
    expect(r.ok, isTrue);
    expect(r.reason, 'unbound-skip');
  });

  test('iOS branch skips the Android X.509 gate', () {
    final r = checkAttestationChain(
      chainHex: const [],
      attestationLevel: 'STD',
      emailLower: 's@x.in',
      installId: 'iA',
      pkSHex: 'aa',
      pkDHex: 'bb',
      iosBranch: true,
    );
    expect(r.ok, isTrue);
    expect(r.reason, 'ios-branch-skip');
  });

  test('bound proof with no chain fails closed as empty-chain', () {
    final r = checkAttestationChain(
      chainHex: const [],
      attestationLevel: 'FULL',
      emailLower: 's@x.in',
      installId: 'iA',
      pkSHex: 'aa' * 32,
      pkDHex: 'bb' * 32,
    );
    expect(r.ok, isFalse);
    expect(r.reason, 'attest-empty-chain');
    expect(
        attestationSelfCheckCopy(r), contains('no hardware attestation'));
  });

  test('malformed chain hex fails closed, never throws', () {    final r = checkAttestationChain(
      chainHex: const ['!!!not-hex!!!'],
      attestationLevel: 'FULL',
      emailLower: 's@x.in',
      installId: 'iA',
      pkSHex: 'aa' * 32,
      pkDHex: 'bb' * 32,
    );
    expect(r.ok, isFalse);
    expect(r.reason, 'attest-malformed');
  });

  test('non-DER synthetic chain skips (server stays authority)', () {
    // Unit-fixture chains are raw concatenations, not ASN.1 — the
    // production gate cannot parse them, and the server may accept them
    // via its test seam. The helper skips; it never fails them locally.
    final r = checkAttestationChain(
      chainHex: ['06012a', 'aabbcc'],
      attestationLevel: 'FULL',
      emailLower: 's@x.in',
      installId: 'iA',
      pkSHex: 'aa' * 32,
      pkDHex: 'bb' * 32,
    );
    expect(r.ok, isTrue);
    expect(r.reason, 'non-x509-skip');
    expect(r.chainLen, 2);
  });

  test('unknown-root copy names emulator/software/ROM remedy', () {
    const r = AttestationSelfCheck(
        ok: false, reason: 'unknown-root', rootPrefix: 'deadbeef', chainLen: 3);
    expect(attestationSelfCheckCopy(r), contains('deadbeef'));
    expect(attestationSelfCheckCopy(r), contains('hardware-backed'));
  });

  test('challenge-mismatch copy names re-enroll remedy', () {
    const r = AttestationSelfCheck(ok: false, reason: 'challenge-mismatch');
    expect(attestationSelfCheckCopy(r), contains('Re-enroll'));
  });

  test('expired-cert copy names certificate remedy (not the 90d window)', () {
    // Field 2026-09-15: the old shared copy blamed the anchor-or-window
    // for an X.509 leaf expiry. The split copy must name the certificate
    // path (update + refresh + Generate anew).
    const r = AttestationSelfCheck(ok: false, reason: 'expired-cert');
    final copy = attestationSelfCheckCopy(r);
    expect(copy, contains('certificate is expired'));
    expect(copy, contains('Generate a new device key'));
    expect(copy, isNot(contains('90 days')));
  });

  test('device-expired copy names the window remedy', () {
    const r = AttestationSelfCheck(ok: false, reason: 'device-expired');
    final copy = attestationSelfCheckCopy(r);
    expect(copy, contains('attestation window expired'));
    expect(copy, contains('go online once'));
  });
}
