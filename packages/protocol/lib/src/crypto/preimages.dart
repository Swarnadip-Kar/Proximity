// Channel-binding preimage (canonical home, moved verbatim from
// packages/transport tls.dart). The student captures the live cert
// fingerprint during the TLS handshake and binds it into Sig_bind; the
// professor rejects any POST whose fingerprint differs from its own cert.
// A blind TCP relay (Evil-Twin AP) cannot present the professor's cert
// without its private key, so relayed POSTs fail binding.
//
// Prof/student/ack member preimages stay on ProxCrypto in primitives.dart
// (one class cannot span files); only this top-level preimage lives here.
library;

import 'dart:typed_data';

import '../bytes.dart';
import 'primitives.dart';

/// Channel-binding preimage: sessionID || windowID || j32 || tlsFingerprint.
Uint8List bindPreimage({
  required Uint8List sessionId,
  required Uint8List windowId,
  required int j,
  required Uint8List tlsFingerprint,
}) =>
    concat([sessionId, windowId, ProxCrypto.j32(j), tlsFingerprint]);
