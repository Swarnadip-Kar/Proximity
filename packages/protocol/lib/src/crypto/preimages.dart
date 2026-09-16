// packages/transport tls.dart). The student captures the live cert
// fingerprint during the TLS handshake and binds it into Sig_bind; the
// professor rejects any POST whose fingerprint differs from its own cert.
// A blind TCP relay (Evil-Twin AP) cannot present the professor's cert
// without its private key, so relayed POSTs fail binding.
//
// Prof/student/ack member preimages stay on ProxCrypto in primitives.dart
// (one class cannot span files); only this top-level preimage lives here.
library;

import 'dart:convert';
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

/// M5 channel-binding V2: V1 + lowercased student ID bytes appended
/// (sessionID || windowID || j32 || tlsFingerprint || emailLowerUtf8).
/// Binds the channel proof to the prover so a captured sigBind cannot be
/// transplanted across IDs in the same window. Servers verify V2 first,
/// V1 as migration fallback (mixed fleets); new clients MUST use V2.
Uint8List bindPreimageV2({
  required Uint8List sessionId,
  required Uint8List windowId,
  required int j,
  required Uint8List tlsFingerprint,
  required String studentId,
}) =>
    concat([
      sessionId,
      windowId,
      ProxCrypto.j32(j),
      tlsFingerprint,
      utf8.encode(studentId.trim().toLowerCase()),
    ]);
