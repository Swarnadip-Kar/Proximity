// Per-window TLS identity: runtime-generated self-signed RSA cert.
// The SHA-256 fingerprint of the DER is the channel-binding anchor:
// the student captures it during the TLS handshake and binds it into
// Sig_bind; the professor rejects any POST whose fingerprint differs
// from its own cert. A blind TCP relay (Evil-Twin AP) cannot present the
// professor's cert without its private key, so relayed POSTs fail binding.
// (Active accomplice radio-relay across both windows remains out of scope
// per design non-goals — same residual as the BLE wormhole note.)
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:proximity_protocol/protocol.dart';

// M1: bindPreimage's canonical home is proximity_protocol crypto/preimages.
// Re-export (same declaration — no ambiguity for importers of both packages).
export 'package:proximity_protocol/protocol.dart' show bindPreimage;

class WindowTls {
  final String certPem;
  final String keyPem;
  final Uint8List fingerprint; // SHA-256 over DER, 32B
  const WindowTls({
    required this.certPem,
    required this.keyPem,
    required this.fingerprint,
  });
}

Uint8List _derOfPem(String pem) {
  final lines = const LineSplitter().convert(pem.trim());
  final b64 = lines.where((l) => !l.startsWith('-----')).join();
  return Uint8List.fromList(base64.decode(b64));
}

/// Generates a 2-day self-signed RSA-2048 cert for one attendance window.
/// SANs cover localhost + link-local so hotspot/direct IPs verify by pin
/// (hostname checks are bypassed — pinning is the trust root here).
WindowTls generateWindowTls() {
  final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final priv = pair.privateKey as RSAPrivateKey;
  final pub = pair.publicKey as RSAPublicKey;
  final csr = X509Utils.generateRsaCsrPem({'CN': 'Proximity'}, priv, pub);
  final certPem = X509Utils.generateSelfSignedCertificate(priv, csr, 2,
      sans: const ['127.0.0.1', '::1', 'localhost'],
      extKeyUsage: const [ExtendedKeyUsage.SERVER_AUTH]);
  final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(priv);
  final fp = ProxCrypto.sha256Sync(_derOfPem(certPem));
  return WindowTls(certPem: certPem, keyPem: keyPem, fingerprint: fp);
}
