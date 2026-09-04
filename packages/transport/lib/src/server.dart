// Professor HTTPS server (shelf, foreground): §6.3 endpoints.
//
//   GET  /window          {class, sessionID, windowID, j_now, pkP, sigP,
//                          tlsFp, display}
//   GET  /epoch/:j        {sigP(j)}              (no C_j; C_j is radio-only)
//   POST /prove           {ID,windowID,j,C_j,Sig_s,faceScore,peerW,roll,
//                          tlsFp,sigBind} -> {confirmed|late|invalid,...}
//   GET  /live?token=     counts + rows           (host bearer)
//   GET  /export?token=   attendance.csv          (host bearer)
//
// Security notes:
//  - TLS cert is per-window runtime-generated (see tls.dart); clients pin
//    via channel binding (tlsFp + sigBind). A blind Evil-Twin relay cannot
//    present the professor's cert without its private key, so relayed POSTs
//    fail binding with `tls-mismatch`.
//  - BLE sightings come from the radio layer via [SightingLookup]; the
//    server never trusts client-claimed RSSI.
//  - Host bearer = hex(SHA-256(S_w)): only the host knows the window secret.
//  - Rate limits: /prove 40/10s/IP, /window 5/10s/IP (§6.3).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_storage/storage.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'tls.dart';

/// BLE sighting as seen by the host radio. Null = never heard over radio.
class RadioSighting {
  final int rssiDbm;
  final int hop; // 0 = direct
  const RadioSighting({required this.rssiDbm, required this.hop});
}

/// Radio lookup for a proof: the server recomputes the expected student
/// response UUID and asks the radio layer whether it was heard. The radio
/// layer never trusts client-claimed RSSI.
typedef SightingLookup = RadioSighting? Function({
  required Uint8List peerW,
  required String expectedResponseUuid,
});

/// Professor bearer token: only the host knows S_w.
String hostBearer(Uint8List windowSecret) =>
    hexEncode(ProxCrypto.sha256Sync(windowSecret));

String _ip(Request req) {
  final info = req.context['shelf.io.connection_info'] as HttpConnectionInfo?;
  return info?.remoteAddress.address ?? 'unknown';
}

Response _json(Object o, [int status = 200]) => Response(status,
    body: jsonEncode(o), headers: {'content-type': 'application/json'});

class ProxServer {
  final String classLabel;
  final ed.PrivateKey profSk;
  final ed.PublicKey profPk;
  final Map<String, ed.PublicKey> studentKeys; // email -> enrolled PK
  final Set<String> revokedPkHex;
  final SightingLookup sightings;
  final TallyStore tally;
  final SingleUseTracker _once = SingleUseTracker();
  final RateLimiter _proveLimits = proveLimiter();
  final RateLimiter _windowLimits = windowLimiter();

  HttpServer? _http;
  WindowParams? _window;
  int _windowNo = 1;
  late final WindowTls tls;
  String _bearer = '';

  ProxServer({
    required this.classLabel,
    required this.profSk,
    required this.profPk,
    required this.studentKeys,
    required this.revokedPkHex,
    required this.sightings,
    TallyStore? tally,
  }) : tally = tally ?? TallyStore() {
    // One TLS identity per hosting session (bind needs a cert before any
    // window opens). Freshness still binds per window: the fingerprint is
    // delivered inside the per-sub-epoch signed /window descriptor, and
    // proofs channel-bind to the presented cert.
    tls = generateWindowTls();
  }

  int get port => _http?.port ?? -1;
  bool get windowOpen => _window != null;
  WindowParams? get window => _window;
  String get bearer => _bearer;

  /// Opens a 30s window: fresh secrets + fresh host bearer. Students see
  /// `windowOpen: true` on their next beacon and begin proving.
  void openWindow(WindowParams window, int windowNo) {
    _window = window;
    _windowNo = windowNo;
    _bearer = hostBearer(window.secret);
  }

  /// Closes the window. Proofs are rejected as `window-closed`; the HTTPS
  /// server and LAN announce stay up so late students see the state.
  void closeWindow() {
    _window = null;
  }

  Future<HttpServer> start({String host = '0.0.0.0', int port = 8443}) async {
    final ctx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(tls.certPem))
      ..usePrivateKeyBytes(utf8.encode(tls.keyPem));
    final server = await shelf_io.serve(_route, host, port,
        securityContext: ctx, shared: true);
    _http = server;
    return server;
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _http = null;
  }

  Future<Response> _route(Request req) async {
    final path = req.url.pathSegments;
    try {
      if (req.method == 'GET' && path.length == 1 && path[0] == 'window') {
        if (!_windowLimits.allow(_ip(req))) {
          return _json({'error': 'rate-limited'}, 429);
        }
        return _getWindow();
      }
      if (req.method == 'GET' && path.length == 2 && path[0] == 'epoch') {
        return _getEpoch(path[1]);
      }
      if (req.method == 'POST' && path.length == 1 && path[0] == 'prove') {
        if (!_proveLimits.allow(_ip(req))) {
          return _json({'error': 'rate-limited'}, 429);
        }
        return await _postProve(req);
      }
      if (req.method == 'GET' && path.length == 1 && path[0] == 'live') {
        return _guarded(req, _getLive);
      }
      if (req.method == 'GET' && path.length == 1 && path[0] == 'export') {
        return _guarded(req, _getExport);
      }
      return _json({'error': 'not-found'}, 404);
    } catch (e) {
      return _json({'error': '$e'}, 500);
    }
  }

  Response _getWindow() {
    final w = _window;
    if (w == null) {
      return _json({
        'class': classLabel,
        'windowOpen': false,
        'pkP': hexEncode(profPk.bytes.sublist(0, 32)),
        'tlsFp': hexEncode(tls.fingerprint),
      });
    }
    final j = w.jForTime(DateTime.now().toUtc()).clamp(0, 5);
    final cj = w.challengeFor(j);
    final sigP = ProxCrypto.signProfChallenge(
      profSk: profSk,
      sessionId: w.sessionId,
      windowId: w.windowId,
      j: j,
      challenge: cj,
    );
    return _json({
      'class': classLabel,
      'windowOpen': true,
      'sessionID': hexEncode(w.sessionId),
      'windowID': hexEncode(w.windowId),
      'j_now': j,
      'pkP': hexEncode(profPk.bytes.sublist(0, 32)),
      'sigP': hexEncode(sigP),
      'tlsFp': hexEncode(tls.fingerprint),
      'display': w.displayCode,
    });
  }

  Response _getEpoch(String jStr) {
    final w = _window;
    if (w == null) return _json({'error': 'window-closed'}, 400);
    final j = int.tryParse(jStr);
    if (j == null || j < 0 || j >= kSubEpochsPerWindow) {
      return _json({'error': 'bad-j'}, 400);
    }
    final sigP = ProxCrypto.signProfChallenge(
      profSk: profSk,
      sessionId: w.sessionId,
      windowId: w.windowId,
      j: j,
      challenge: w.challengeFor(j),
    );
    return _json({'j': j, 'sigP': hexEncode(sigP)});
  }

  Future<Response> _postProve(Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final now = DateTime.now().toUtc();
    final w = _window;
    if (w == null) {
      return _json(
          {'decision': 'invalid', 'reason': 'window-closed'}, 200);
    }
    try {
      final id = (body['ID'] as String).toLowerCase();
      final wid = Uint8List.fromList(hexDecode(body['windowID'] as String));
      final j = body['j'] as int;
      final cClaimed = Uint8List.fromList(hexDecode(body['C_j'] as String));
      final sigS = Uint8List.fromList(hexDecode(body['Sig_s'] as String));
      final faceScore = (body['faceScore'] as num).toDouble();
      final peerW = Uint8List.fromList(hexDecode(body['peerW'] as String));
      final roll = body['roll'] as String? ?? '';
      final name = body['name'] as String? ?? id;
      final tlsFp = Uint8List.fromList(hexDecode(body['tlsFp'] as String? ?? ''));
      final sigBind =
          Uint8List.fromList(hexDecode(body['sigBind'] as String? ?? ''));

      final expectedCj = w.challengeFor(j);
      final stuPk = studentKeys[id];
      final expectedResponse =
          UuidCodec.packResponse(ProxCrypto.responseToken(expectedCj, id));
      final sight = peerW.length == 8
          ? sightings(peerW: peerW, expectedResponseUuid: expectedResponse)
          : null;

      var outcome = verifyProve(
        req: VerifyRequest(
          id: id,
          windowId: wid,
          j: j,
          cClaimed: cClaimed,
          sigS: sigS,
          faceScore: faceScore,
          // Holder freshness is gated on-device (SK locked without fresh
          // face); transport re-checks score + radio + crypto proofs.
          faceValidAt: now,
          peerW: peerW,
          rssiDbm: sight?.rssiDbm ?? -127,
          relayHop: sight?.hop ?? 99,
          now: now,
        ),
        expectedCj: expectedCj,
        sessionId: w.sessionId,
        windowIdExpected: w.windowId,
        studentPk: stuPk,
        revoked: stuPk != null &&
            revokedPkHex.contains(
                hexEncode(Uint8List.fromList(stuPk.bytes.sublist(0, 32)))),
        freshWindow: w.isFresh(j, now),
        singleUseOk: _once.claim(id, j),
      );

      // TLS channel binding: the client must have seen OUR cert.
      if (outcome.decision == ProveDecision.confirmed) {
        if (!bytesEqual(tlsFp, tls.fingerprint)) {
          outcome =
              const VerifyOutcome(ProveDecision.invalid, 'tls-mismatch');
        } else if (stuPk == null ||
            !ProxCrypto.verify(
                stuPk,
                bindPreimage(
                  sessionId: w.sessionId,
                  windowId: w.windowId,
                  j: j,
                  tlsFingerprint: tls.fingerprint,
                ),
                sigBind)) {
          outcome = const VerifyOutcome(ProveDecision.invalid, 'bad-bind');
        }
      }

      final code = decisionCode(outcome.decision);
      final ackSig = ProxCrypto.sign(
        profSk,
        ProxCrypto.ackPreimage(
          sessionId: w.sessionId,
          windowId: w.windowId,
          j: j,
          studentId: id,
          decision: code,
          serverTimeMs: now.millisecondsSinceEpoch,
        ),
      );
      if (outcome.decision == ProveDecision.confirmed) {
        tally.mark(id, name, _windowNo, roll: roll);
      }
      return _json({
        'decision': switch (outcome.decision) {
          ProveDecision.confirmed => 'confirmed',
          ProveDecision.late => 'late',
          ProveDecision.invalid => 'invalid',
        },
        'reason': outcome.reason,
        'serverTime': now.toIso8601String(),
        'sigAck': hexEncode(ackSig),
      });
    } catch (e) {
      return _json({'decision': 'invalid', 'reason': 'bad-body: $e'}, 400);
    }
  }

  Response _guarded(Request req, Response Function() fn) {
    if (req.url.queryParameters['token'] != bearer) {
      return _json({'error': 'forbidden'}, 403);
    }
    return fn();
  }

  Response _getLive() {
    return _json({
      'present': tally.presentCount,
      'rows': [
        for (final r in tally.present)
          {'email': r.email, 'name': r.name, 'w1': r.w1, 'w2': r.w2}
      ],
    });
  }

  Response _getExport() {
    // Detached prof signature over the export is produced by the app layer
    // (holds SK_p); transport returns the canonical CSV.
    return _json({
      'csv': tally.exportCsv(classLabel: classLabel, dateIso: dateIsoNow())
    });
  }
}

/// YYYY-MM-DD today (UTC).
String dateIsoNow() {
  final n = DateTime.now().toUtc();
  return '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}
