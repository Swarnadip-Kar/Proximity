// Local attestation self-check (UX fail-fast — NEVER authority).
//
// Runs the SAME pure chain gate the professor will run
// (`verifyAttestationChainPin` vs `defaultPinnedAttestationRoots`), BEFORE
// the claim leaves at enroll time and BEFORE the POST leaves at mark time,
// so an unrecognized chain fails with a NAMED cause on this phone instead
// of a mysterious `device-unproven` at marking time (or a useless binding
// at enroll time). The server verdict stays final — this only
// short-circuits the round trip and names the cause. Skip rules mirror the
// server exactly: unbound/legacy proofs (no pkD) and the iOS App Attest
// branch (no Android X.509 chain) have nothing to pre-check.
//
// What `unknown-root` means (pins cover Google's published f92009e853b6b045
// RSA vintages — 2019/2021/2022 — plus the EC CA1 root): the key attested
// under a NON-Google anchor — emulator/software Keystore, custom ROM, or
// non-GMS hardware. Those keys fail closed BY DESIGN (software attestation
// is not hardware trust); the copy says so instead of stranding the holder
// at marking time.
library;

import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';

/// Outcome of [checkAttestationChain]. Pure data, no logging here —
/// callers log the one line (root prefix + length ride every call so the
/// field can compare anchors across phones).
class AttestationSelfCheck {
  /// True = the professor's gate will (barring races) also pass, or there
  /// is nothing to pre-check (unbound legacy / iOS branch).
  final bool ok;

  /// Pin reason when ![ok] (`unknown-root`, `challenge-mismatch`,
  /// `attest-empty-chain`, …), else a skip code (`unbound-skip`,
  /// `ios-branch-skip`, `ok`).
  final String reason;
  final List<String> flags;

  /// SHA-256 of the chain's top cert, first 8 hex ('' when no chain).
  /// Public anchor hash — identifies WHICH root refused without moving
  /// key material. Compare against the pinned Google HW roots.
  final String rootPrefix;

  /// Chain length in certs (0 when none).
  final int chainLen;

  /// Debug-only validity detail (per-cert dates + indexes, no key material
  /// — see `chainValidityDebugLine`). '' when nothing was parsed. Carried
  /// into the CRYPTO log + enroll debug card; never affects the verdict.
  final String debugDetail;
  const AttestationSelfCheck(
      {required this.ok,
      required this.reason,
      this.flags = const [],
      this.rootPrefix = '',
      this.chainLen = 0,
      this.debugDetail = ''});

  /// One-line debug summary for logs + the enroll debug card (no secrets:
  /// chain length, anchor prefix, flags, per-cert dates).
  String get debugLine =>
      'chain=$chainLen root=${rootPrefix.isEmpty ? 'none' : rootPrefix} flags=$flags $debugDetail'
          .trim();
}

/// Local pre-run of the professor's chain gate. [chainHex] is the DER-hex
/// wire form (leaf-first), [attestationLevel] the stored `FULL`/`STD`/
/// `NONE` string, [pkSHex]/[pkDHex] the stored hex. [iosBranch] must be
/// true when App Attest artifacts ride instead (server routes by artifact
/// presence — mirror that, never a claimed platform string). Never throws
/// (malformed hex fails closed with its reason).
AttestationSelfCheck checkAttestationChain({
  required List<String> chainHex,
  required String attestationLevel,
  required String emailLower,
  required String installId,
  required String pkSHex,
  required String pkDHex,
  bool iosBranch = false,
}) {
  String rootPrefix = '';
  var chainLen = 0;
  var debugDetail = '';
  try {
    final certs = <Uint8List>[];
    for (final h in chainHex) {
      final t = h.trim();
      if (t.isEmpty) continue;
      certs.add(Uint8List.fromList(hexDecode(t)));
    }
    chainLen = certs.length;
    if (certs.isNotEmpty) {
      try {
        rootPrefix =
            hexEncode(ProxCrypto.sha256Sync(certs.last)).substring(0, 8);
      } catch (_) {}
      // Debug-only per-cert validity (dates + EXPIRED markers, no key
      // material): names WHICH cert in a 5-chain is stale. Best-effort,
      // never throws, never affects the verdict below.
      try {
        final nowIso =
            DateTime.now().toUtc().toIso8601String().substring(0, 16);
        final perCert = chainValidityDebugLine(certs);
        // Raw leaf time strings (byte offsets included): independent
        // cross-check proving impossible parsed dates are firmware-encoded,
        // not misparsed. Leaf only — keeps the line short.
        var leafTimes = '';
        try {
          final raw = certTimeStringsDebug(certs.first);
          if (raw.isNotEmpty) leafTimes = ' leafTimes=[$raw]';
        } catch (_) {}
        debugDetail = perCert.isEmpty
            ? 'now=${nowIso}Z$leafTimes'
            : 'now=${nowIso}Z $perCert$leafTimes';
      } catch (_) {}
    }
    // Skip rules mirror the server: unbound/legacy (no pkD) and the iOS
    // branch have no Android X.509 chain to pre-check.
    if (pkDHex.trim().isEmpty) {
      return AttestationSelfCheck(
          ok: true,
          reason: 'unbound-skip',
          rootPrefix: rootPrefix,
          chainLen: chainLen,
          debugDetail: debugDetail);
    }
    if (iosBranch) {
      return AttestationSelfCheck(
          ok: true,
          reason: 'ios-branch-skip',
          rootPrefix: rootPrefix,
          chainLen: chainLen,
          debugDetail: debugDetail);
    }
    final level = attestationLevelOf(attestationLevel);
    if (certs.isEmpty) {
      // Empty + bound is a real signal (FULL claim, no chain) — fail here
      // exactly as the server will. (Empty + unbound returned above.)
      if (pkDHex.trim().isEmpty) {
        return AttestationSelfCheck(
            ok: true,
            reason: 'unbound-skip',
            rootPrefix: rootPrefix,
            chainLen: chainLen,
            debugDetail: debugDetail);
      }
      return AttestationSelfCheck(
          ok: false,
          reason: 'attest-empty-chain',
          flags: const ['attest-empty-chain'],
          rootPrefix: rootPrefix,
          chainLen: chainLen,
          debugDetail: debugDetail);
    }
    // X.509-shape pre-gate: synthetic/test chains (unit fixtures, fake
    // keys) are not DER — the production gate cannot parse them, and the
    // server may accept them via its test seam. Only pre-run on
    // DER-shaped input (SEQUENCE tag on every cert); anything else goes
    // to the server, which stays the authority (production rejects
    // non-DER as bad-chain-der — the skip only costs a POST, never trust).
    final looksX509 =
        certs.every((c) => c.length > 2 && c[0] == 0x30);
    if (!looksX509) {
      return AttestationSelfCheck(
          ok: true,
          reason: 'non-x509-skip',
          rootPrefix: rootPrefix,
          chainLen: chainLen,
          debugDetail: debugDetail);
    }
    final pin = verifyAttestationChainPin(
      chain: AttestationChain(certs),
      pinnedRootHashes: defaultPinnedAttestationRoots(),
      expectedChallenge: deviceBindingChallengeV2(
        emailLower: emailLower,
        installId: installId,
        pkS: Uint8List.fromList(hexDecode(pkSHex.trim())),
      ),
      expectedLeafPkD: Uint8List.fromList(hexDecode(pkDHex.trim())),
      level: level,
      checkValidity: true,
    );
    if (!pin.ok) {
      return AttestationSelfCheck(
          ok: false,
          reason: pin.reason,
          flags: List<String>.of(pin.flags),
          rootPrefix: rootPrefix,
          chainLen: chainLen,
          debugDetail: debugDetail);
    }
    // Flag-only KeyDescription boot telemetry (attendance posture,
    // fail-open): unlocked / unverified-boot / software-level ride as
    // advisory flags alongside ok — never a refusal. Unparseable leaves
    // (fake units, future KeyMint) emit no flags. Server stays final.
    final bootFlags = <String>[];
    try {
      bootFlags.addAll(bootFlagsOf(certs.first));
    } catch (_) {}
    return AttestationSelfCheck(
        ok: true,
        reason: 'ok',
        flags: [...pin.flags, ...bootFlags],
        rootPrefix: rootPrefix,
        chainLen: chainLen,
        debugDetail: debugDetail);
  } catch (e) {
    return AttestationSelfCheck(
        ok: false,
        reason: 'attest-malformed',
        flags: const ['attest-malformed'],
        rootPrefix: rootPrefix,
        chainLen: chainLen,
        debugDetail: debugDetail);
  }
}

/// User-facing copy for a failed [AttestationSelfCheck] (enroll refusal /
/// mark-time detail). Names the cause + the remedy; never raw hex.
///
/// Field note 2026-09-13 (Samsung A52s, GPay works but chain root
/// 1ef1a04b unknown): GPay passing proves Play Integrity DEVICE only, NOT
/// hardware chain to a Google HW root (STRONG). An unknown root with a
/// COMPLETE chain (OID/challenge/signatures pass, only the pin fails) means
/// non-Google attestation — software Keystore fallback, custom ROM, Knox-
/// tripped/unprovisioned TEE, or non-GMS hardware — fail-closed by design.
/// Resolved 2026-09-14: 1ef1a04b IS the genuine Google 2019 RSA vintage
/// (same key as the 2022 root, docs-page PEM) — 2019 + 2021 vintages now
/// pinned, so factory-provisioned 2021 devices pass; anything still unknown
/// needs the checklist below, not a retry.
String attestationSelfCheckCopy(AttestationSelfCheck r) {
  switch (r.reason) {
    case 'unknown-root':
      return 'This phone\u2019s hardware attestation isn\u2019t recognized '
          '(chain root ${r.rootPrefix.isEmpty ? 'unknown' : r.rootPrefix}). '
          'Payment apps can still work without hardware attestation. Check: '
          'stock ROM + locked bootloader (no custom ROM/Magisk), Knox 0x0, '
          'screen lock + biometric enrolled, Play Services updated, then '
          're-enroll online. Marking needs a hardware-backed Android '
          'keystore — enroll on a physical certified phone instead.';
    case 'challenge-mismatch':
      return 'This enrollment\u2019s device key doesn\u2019t match this '
          'phone\u2019s install (reinstall without re-enrolling?). '
          'Re-enroll this device, then mark again.';
    case 'attest-empty-chain':
      return 'This enrollment carries no hardware attestation (chain '
          'missing). Re-enroll this device on a hardware-backed phone.';
    case 'device-expired':
    case 'expired-cert':
      // Split by cause — the old shared copy blamed both, which sent users
      // with a stale RKP leaf down the heartbeat path and users with a
      // spent window down the OS-update path:
      // - expired-cert: an X.509 date in the chain passed (leaf /
      //   intermediate / anchor — the Debug line names which). A fresh key
      //   mints a fresh 90d window but reuses the provisioned chain, so
      //   retrying the SAME key cannot pass: update + online refresh (RKP
      //   re-provisioning), then Generate anew.
      // - device-expired: the 90d attestation window + 14d grace spent with
      //   no online refresh — the chain itself is fine, one online
      //   heartbeat fixes it.
      if (r.reason == 'device-expired') {
        return 'This phone\u2019s attestation window expired (90 days online-refresh + 14 days grace spent) — go online once so it re-attests, then try again.';
      }
      return 'This phone\u2019s hardware certificate is expired (a date in its attestation chain has passed — update Android + Play Services, stay online a few minutes so it fetches fresh certificates, then Generate a new device key and Save again. Ask your professor for manual attendance meanwhile.)';
    default:
      return 'This phone\u2019s hardware proof doesn\u2019t verify '
          '(${r.reason}). Re-enroll this device, then mark again.';
  }
}
