// Student HTTPS client: fetch window descriptor, verify professor
// signature, POST signed proofs with jittered retries.
//
// TLS trust: the first /window fetch is TOFU within the session, but every
// byte that matters is Ed25519-signed (Sig_p verified against pkP before
// anything is signed). The professor independently verifies the TLS channel
// binding (tlsFp + sigBind), so a relayed connection is rejected server-side
// even if the student fetched the descriptor through it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:proximity_protocol/protocol.dart';

import 'transport_core.dart';

class WindowDescriptor {
  final String classLabel;
  final Uint8List sessionId;
  final Uint8List windowId;
  final int jNow;
  final ed.PublicKey profPk;
  final Uint8List sigP;
  final Uint8List tlsFp;
  final String display;
  const WindowDescriptor({
    required this.classLabel,
    required this.sessionId,
    required this.windowId,
    required this.jNow,
    required this.profPk,
    required this.sigP,
    required this.tlsFp,
    required this.display,
  });
}

class ProveResult {
  final ProveDecision decision;
  final String reason;
  final DateTime serverTime;
  final Uint8List sigAck;
  const ProveResult({
    required this.decision,
    required this.reason,
    required this.serverTime,
    required this.sigAck,
  });

  bool verifyAck({
    required ed.PublicKey profPk,
    required Uint8List sessionId,
    required Uint8List windowId,
    required int j,
    required String studentId,
  }) =>
      ProxCrypto.verify(
        profPk,
        ProxCrypto.ackPreimage(
          sessionId: sessionId,
          windowId: windowId,
          j: j,
          studentId: studentId,
          decision: decisionCode(decision),
          serverTimeMs: serverTime.millisecondsSinceEpoch,
        ),
        sigAck,
      );
}

class ProxClient {
  final String host;
  final int port;
  final HttpClient _http = HttpClient();
  Uint8List? _pinnedFp; // captured from /window fetch

  ProxClient({required this.host, required this.port});

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'https', host: host, port: port, path: path, queryParameters: query);

  void close() => _http.close(force: true);

  Future<(int, Map<String, dynamic>)> _get(String path) async {
    _http.badCertificateCallback = (cert, h, p) {
      _pinnedFp = Uint8List.fromList(
          ProxCrypto.sha256Sync(cert.der));
      return true; // TOFU: content is signature-verified below
    };
    final req = await _http.getUrl(_uri(path));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return (resp.statusCode, jsonDecode(body) as Map<String, dynamic>);
  }

  /// Fetches + verifies the window descriptor (Sig_p over the live C_j…
  /// verified against the C_j the caller heard over BLE radio).
  Future<WindowDescriptor> fetchWindow(Uint8List radioChallenge) async {
    final (status, j) = await _get('/window');
    if (status != 200) throw StateError('window fetch: $j');
    final sessionId = Uint8List.fromList(hexDecode(j['sessionID'] as String));
    final windowId = Uint8List.fromList(hexDecode(j['windowID'] as String));
    final jNow = j['j_now'] as int;
    final profPk = ed.PublicKey(hexDecode(j['pkP'] as String));
    final sigP = Uint8List.fromList(hexDecode(j['sigP'] as String));
    // The descriptor never carries C_j (radio-only). The caller proves it
    // heard the live challenge by verifying Sig_p against its radio copy.
    final ok = ProxCrypto.verifyProfChallenge(
      profPk: profPk,
      sessionId: sessionId,
      windowId: windowId,
      j: jNow,
      challenge: radioChallenge,
      sig: sigP,
    );
    if (!ok) throw StateError('prof signature mismatch (fake professor?)');
    return WindowDescriptor(
      classLabel: j['class'] as String,
      sessionId: sessionId,
      windowId: windowId,
      jNow: jNow,
      profPk: profPk,
      sigP: sigP,
      tlsFp: Uint8List.fromList(hexDecode(j['tlsFp'] as String)),
      display: j['display'] as String,
    );
  }

  /// POSTs a signed proof with herd-spread jitter, up to 3 attempts.
  /// [sign] builds (sigS, sigBind) for the attempt's sub-epoch.
  Future<ProveResult> prove({
    required WindowDescriptor desc,
    required String studentId,
    required Uint8List challenge,
    required int j,
    required double faceScore,
    required Uint8List peerW,
    String name = '',
    String roll = '',
    required Uint8List Function(Uint8List challenge, int j) sigSFor,
    required Uint8List Function(Uint8List tlsFp, int j) sigBindFor,
    Random? rng,
    int maxAttempts = 3,
  }) async {
    Object? lastErr;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future.delayed(FloodController.postJitter(rng: rng));
      }
      try {
        return await _proveOnce(
          desc: desc,
          studentId: studentId,
          challenge: challenge,
          j: j,
          faceScore: faceScore,
          peerW: peerW,
          name: name,
          roll: roll,
          sigSFor: sigSFor,
          sigBindFor: sigBindFor,
        );
      } catch (e) {
        lastErr = e;
      }
    }
    throw StateError('prove failed after $maxAttempts attempts: $lastErr');
  }

  Future<ProveResult> _proveOnce({
    required WindowDescriptor desc,
    required String studentId,
    required Uint8List challenge,
    required int j,
    required double faceScore,
    required Uint8List peerW,
    required String name,
    required String roll,
    required Uint8List Function(Uint8List challenge, int j) sigSFor,
    required Uint8List Function(Uint8List tlsFp, int j) sigBindFor,
  }) async {
    final tlsFp = _pinnedFp ?? desc.tlsFp;
    final body = jsonEncode(buildProveBody(
      id: studentId,
      windowId: desc.windowId,
      j: j,
      challenge: challenge,
      sigS: sigSFor(challenge, j),
      faceScore: faceScore,
      peerW: peerW,
      name: name,
      roll: roll,
      tlsFp: tlsFp,
      sigBind: sigBindFor(tlsFp, j),
    ));
    _http.badCertificateCallback = (cert, h, p) {
      final fp =
          Uint8List.fromList(ProxCrypto.sha256Sync(cert.der));
      // Pin to the fingerprint from the verified descriptor fetch.
      return bytesEqual(fp, desc.tlsFp);
    };
    final req = await _http.postUrl(_uri('/prove'));
    req.headers.contentType = ContentType.json;
    req.write(body);
    final resp = await req.close().timeout(const Duration(seconds: 8));
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode == 429) throw StateError('rate-limited, retry later');
    final m = jsonDecode(text) as Map<String, dynamic>;
    return ProveResult(
      decision: switch (m['decision']) {
        'confirmed' => ProveDecision.confirmed,
        'late' => ProveDecision.late,
        _ => ProveDecision.invalid,
      },
      reason: m['reason'] as String? ?? '',
      serverTime: DateTime.parse(m['serverTime'] as String),
      sigAck: Uint8List.fromList(hexDecode(m['sigAck'] as String)),
    );
  }
}
