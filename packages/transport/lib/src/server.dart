// Professor HTTPS server (shelf, foreground): §6.3 endpoints.
//
//   GET  /window          {class, sessionID, windowID, j_now, pkP, sigP,
//                          tlsFp, display}
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_storage/storage.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'live_room.dart';
import 'tls.dart';

export 'live_room.dart';

/// BLE sighting as seen by the host radio. Null = never heard over radio.
class RadioSighting {
  final int rssiDbm;
  final int hop; // 0 = direct
  const RadioSighting({required this.rssiDbm, required this.hop});
}

/// Radio lookup for a proof: the server recomputes the expected student
/// response token and asks the radio layer whether it was heard (v2 air
/// key and legacy v1 UUID forms both accepted — mixed fleets). The radio
/// layer never trusts client-claimed RSSI.
typedef SightingLookup = RadioSighting? Function({
  required Uint8List peerW,
  required String expectedAirKey,
  required String expectedUuid,
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
  final SightingLookup sightings;
  final TallyStore tally;

  /// Prof org domain for the join-gate (see orgOf in the app). '' = legacy
  /// host: every body org passes (migration). Set once at hosting start;
  /// the window/prove path never mutates it.
  String sessionOrg;

  /// Fired for every processed POST /prove (confirmed/late/invalid) so the
  /// host can log the verdict + reason live. Never throws (guarded).
  /// Also fires for org-mismatched /waiting + /manual-request rejects.
  final void Function(String email, String decision, String reason)? onProve;
  final SingleUseTracker _once = SingleUseTracker();
  // Tracks 2+3 anomaly context (server-kept, bounded): seen face-ticket
  // stamps (reused-face flag), recent scores (1.000-repeat flag), last
  // pipeline tag (verifier-flapping flag).
  final Set<int> _seenFaceStamps = {};
  final List<double> _recentScores = [];
  String _lastVerifierVer = '';
  final RateLimiter _proveLimits = proveLimiter();
  final RateLimiter _windowLimits = windowLimiter();

  /// Sighting grace: the student's response ADV precedes its POST, but the
  /// host BLE scan delivers sightings seconds later — a POST that is valid
  /// in every way EXCEPT a missing sighting waits this long for the radio
  /// instead of instantly failing. Without it, marking is a coin flip
  /// between WiFi latency and scan intervals. Tests shrink it.
  Duration sightingGrace = const Duration(seconds: 4);

  HttpServer? _http;
  WindowParams? _window;
  int _windowNo = 1;
  late final WindowTls tls;
  String _bearer = '';
  late final LiveRoom room;

  ProxServer({
    required this.classLabel,
    required this.profSk,
    required this.profPk,
    required this.sightings,
    TallyStore? tally,
    this.onProve,
    this.sessionOrg = '',
  }) : tally = tally ?? TallyStore() {
    // Waiting/manual registry lives in LiveRoom; the server keeps the same
    // public API by delegation (approve still marks current window/1 idle).
    room = LiveRoom(tally: this.tally, windowNoOf: () => _windowNo);
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

  /// Polls the radio lookup until the expected response sighting lands or
  /// [sightingGrace] elapses. The lookup never throws out (a radio-layer
  /// hiccup mid-wait must not 500 the POST).
  Future<RadioSighting?> _awaitSighting({
    required Uint8List peerW,
    required String expectedAirKey,
    required String expectedUuid,
  }) async {
    final until = DateTime.now().add(sightingGrace);
    while (true) {
      RadioSighting? s;
      try {
        s = sightings(
            peerW: peerW,
            expectedAirKey: expectedAirKey,
            expectedUuid: expectedUuid);
      } catch (_) {
        s = null;
      }
      if (s != null) return s;
      if (DateTime.now().isAfter(until)) return null;
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  /// Opens a window: fresh secrets + fresh host bearer. Students see
  /// `windowOpen: true` on their next beacon and begin proving. The window
  /// stays open until [closeWindow] — challenges rotate unbounded, so no
  /// round clock can strand a slow prover.
  /// Single-use (ID,j) claims reset: every window carries a fresh windowId,
  /// so an old claim can never validate again (window-mismatch) — but the
  /// bare (ID,j) key WOULD false-reject a new window's same-j prove (window
  /// #2, or a retaken round). Clearing is safe: closed-window proofs are
  /// rejected as window-closed regardless of the tracker.
  void openWindow(WindowParams window, int windowNo) {
    _window = window;
    _windowNo = windowNo;
    _bearer = hostBearer(window.secret);
    _once.clear();
  }

  /// Closes the window. Proofs are rejected as `window-closed`; the HTTPS
  /// server and LAN announce stay up so late students see the state.
  /// The completed round number is recorded even when nobody marked —
  /// otherwise empty and late-only rounds vanish from history and a
  /// 5-round visit renders as 2 windows. (Noted at CLOSE, not open: an
  /// in-progress round must not collapse the live all-windows
  /// intersection to zero before anyone marks.)
  void closeWindow() {
    if (_windowNo > 0) tally.noteWindow(_windowNo);
    _window = null;
  }
  int get windowNo => _windowNo;

  // ---- Waiting room (students join before the window opens) ----
  // Delegated to LiveRoom (identical semantics; see live_room.dart).
  void registerWaiting(String email, String name, [String roll = '']) =>
      room.registerWaiting(email, name, roll);

  /// Explicit leave: the student backed out of the waiting room (Cancel /
  /// back navigation / dispose). Returns true when an entry was removed.
  /// Presence heartbeats stop with the room timers, so without this the
  /// professor's waiting count would stay stale.
  bool removeWaiting(String email) => room.removeWaiting(email);

  List<WaitingEntry> get waitingRows => room.waitingRows;

  int get waitingCount => room.waitingCount;

  // ---- Manual attendance over LAN ----
  void requestManual(String email, String name, [String roll = '']) =>
      room.requestManual(email, name, roll);

  List<ManualEntry> get manualRows => room.manualRows;

  List<ManualEntry> get manualPending => room.manualPending;

  String manualStatus(String email) => room.manualStatus(email);

  /// Prof decision. Approving marks the student present in the current
  /// window (or window 1 when idle) so manual marks count in the session.
  bool decideManual(String email, bool approve) =>
      room.decideManual(email, approve);

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
      if (req.method == 'POST' && path.length == 1 && path[0] == 'prove') {
        if (!_proveLimits.allow(_ip(req))) {
          return _json({'error': 'rate-limited'}, 429);
        }
        return await _postProve(req);
      }
      if (req.method == 'POST' && path.length == 1 && path[0] == 'waiting') {
        return await _postWaiting(req);
      }
      if (req.method == 'POST' && path.length == 1 && path[0] == 'leave') {
        return await _postLeave(req);
      }
      if (req.method == 'GET' && path.length == 1 && path[0] == 'waiting') {
        return _guarded(req, _getWaiting);
      }
      if (req.method == 'POST' &&
          path.length == 1 &&
          path[0] == 'manual-request') {
        return await _postManualRequest(req);
      }
      if (req.method == 'GET' &&
          path.length == 1 &&
          path[0] == 'manual-requests') {
        return _guarded(req, _getManualRequests);
      }
      if (req.method == 'POST' &&
          path.length == 1 &&
          path[0] == 'manual-decide') {
        return await _guardedJson(req, _postManualDecide);
      }
      if (req.method == 'GET' &&
          path.length == 1 &&
          path[0] == 'manual-status') {
        final email = req.url.queryParameters['email'] ?? '';
        return _json({'status': manualStatus(email)});
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
        'waiting': waitingCount,
        'pkP': hexEncode(profPk.bytes.sublist(0, 32)),
        'tlsFp': hexEncode(tls.fingerprint),
        'org': sessionOrg,
      });
    }
    // j is unbounded (the window closes only when the professor stops it).
    // A pre-open clock (t0 in the future) is reported closed, never a
    // verifiable-but-deterministically-late challenge.
    final jRaw = w.jForTime(DateTime.now().toUtc());
    if (jRaw < 0) {
      return _json({
        'class': classLabel,
        'windowOpen': false,
        'waiting': waitingCount,
        'pkP': hexEncode(profPk.bytes.sublist(0, 32)),
        'tlsFp': hexEncode(tls.fingerprint),
        'org': sessionOrg,
      });
    }
    final j = jRaw.clamp(0, 1 << 30);
    final cj = w.challengeFor(j);
    final sigP = ProxCrypto.signProfChallenge(
      profSk: profSk,
      sessionId: w.sessionId,
      windowId: w.windowId,
      j: j,
      challenge: cj,
    );
    // Rotation tolerance: the student heard C over BLE up to seconds ago;
    // the fetch can land just after the 5s tick, when the live challenge
    // is already C_{j} but the radio copy is C_{j-1}. Ship the previous
    // signature too so the client can verify either token instead of
    // failing a live round as "fake professor".
    Map<String, Object>? prev;
    if (j >= 1) {
      final cjPrev = w.challengeFor(j - 1);
      prev = {
        'j_prev': j - 1,
        'sigP_prev': hexEncode(ProxCrypto.signProfChallenge(
          profSk: profSk,
          sessionId: w.sessionId,
          windowId: w.windowId,
          j: j - 1,
          challenge: cjPrev,
        )),
      };
    }
    return _json({
      'class': classLabel,
      'windowOpen': true,
      'sessionID': hexEncode(w.sessionId),
      'windowID': hexEncode(w.windowId),
      'j_now': j,
      'windowNo': _windowNo,
      'waiting': waitingCount,
      'pkP': hexEncode(profPk.bytes.sublist(0, 32)),
      'sigP': hexEncode(sigP),
      'tlsFp': hexEncode(tls.fingerprint),
      'display': w.displayCode,
      'org': sessionOrg,
      if (prev != null) ...prev,
    });
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
      // Org join-gate (Track 1): cross-domain proofs never reach crypto or
      // the tally. Legacy '' on either side passes (migration). The shape
      // mirrors _fail so ProxClient.prove parses without retrying.
      final bodyOrg = (body['org'] as String? ?? '').trim().toLowerCase();
      if (sessionOrg.isNotEmpty &&
          bodyOrg.isNotEmpty &&
          bodyOrg != sessionOrg) {
        try {
          onProve?.call(id, 'invalid', 'org-mismatch');
        } catch (_) {}
        return _json({
          'decision': 'invalid',
          'reason': 'org-mismatch',
          'serverTime': now.toUtc().toIso8601String(),
          'sigAck': hexEncode(Uint8List(64)),
        }, 200);
      }
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

      // Tracks 2+3 bound ticket: face:{score,faceValidAt,verifierVer} (no
      // images/embeddings leave the device) + pkD + dSig. Absent → legacy
      // path (migration). Bound → extended Sig_s + allowlist + tiers.
      final faceMap = body['face'] as Map<String, dynamic>?;
      final bound = faceMap != null;
      final ticketScore =
          (faceMap?['score'] as num?)?.toDouble() ?? faceScore;
      final ticketStampMs =
          (faceMap?['faceValidAt'] as num?)?.toInt() ?? 0;
      final verifierVer = faceMap?['verifierVer'] as String? ?? '';
      Uint8List pkD = Uint8List(0);
      Uint8List dSig = Uint8List(0);
      try {
        if (body['pkD'] is String && (body['pkD'] as String).isNotEmpty) {
          pkD = Uint8List.fromList(hexDecode(body['pkD'] as String));
        }
        if (body['dSig'] is String && (body['dSig'] as String).isNotEmpty) {
          dSig = Uint8List.fromList(hexDecode(body['dSig'] as String));
        }
      } catch (_) {
        pkD = Uint8List(0);
        dSig = Uint8List(0);
      }
      // Lightweight attestation claims (client-asserted; full X.509 chain
      // verify is deferred — see file header caveat + residual risks).
      final attMap = body['att'] as Map<String, dynamic>?;
      final attLevel = attestationLevelOf(attMap?['level'] as String? ?? 'NONE');
      final attUntil = attMap?['until'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (attMap!['until'] as num).toInt(), isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      // dSig presence check (raw P-256 verify lives in the platform
      // verifier — deferred; the ticket+Sig_s crypto below is fully
      // verified here, and the double-pkD audit flags clones post-hoc).
      final dSigPresent = pkD.isNotEmpty && dSig.isNotEmpty;
      final ticket = bound
          ? ProxCrypto.faceTicketHash(
              faceScore: ticketScore,
              faceValidAtMs: ticketStampMs,
              verifierVer: verifierVer)
          : Uint8List(0);

      // Rosterless (offline-local phase): the student presents its device
      // key and both signatures verify against it — trust-on-first-use per
      // class, no roster lookup. Radio freshness, single-use, face score,
      // sighting and channel binding still gate. Email is self-asserted
      // (verified identity returns with the professor-sign-in phase).
      final presentedPk =
          Uint8List.fromList(hexDecode(body['pkS'] as String? ?? ''));
      if (presentedPk.length != 32) {
        return _json(
            {'decision': 'invalid', 'reason': 'bad-body: pkS'}, 400);
      }
      final stuPk = ed.PublicKey(presentedPk);

      final expectedCj = w.challengeFor(j);
      final rid = ProxCrypto.responseToken(expectedCj, id);
      final expectedAirKey = '$kAirTypeResponse:${hexEncode(rid)}';
      final expectedUuid =
          'uuid:${UuidCodec.normalize(UuidCodec.packResponse(rid))}';
      final sight = peerW.length == 8
          ? sightings(
              peerW: peerW,
              expectedAirKey: expectedAirKey,
              expectedUuid: expectedUuid)
          : null;

      VerifyOutcome runVerify(RadioSighting? s, DateTime t,
          {required bool singleUse}) {
        return verifyProve(
          req: VerifyRequest(
            id: id,
            windowId: wid,
            j: j,
            cClaimed: cClaimed,
            sigS: sigS,
            faceScore: bound ? ticketScore : faceScore,
            // Holder freshness is gated on-device (SK locked without fresh
            // face); transport re-checks score + radio + crypto proofs.
            // Bound path: the stamp IS the ticket time (reused/future
            // stamps flag via the anomaly context below).
            faceValidAt: bound
                ? DateTime.fromMillisecondsSinceEpoch(ticketStampMs,
                    isUtc: true)
                : now,
            peerW: peerW,
            rssiDbm: s?.rssiDbm ?? -127,
            relayHop: s?.hop ?? 99,
            now: t,
            verifierVer: verifierVer,
            faceValidAtMs: ticketStampMs,
            pkD: pkD,
            faceTicketHashBytes: ticket,
            attestationLevel: bound ? attLevel : AttestationLevel.none,
            attestedUntil: attUntil,
            dSigValid: bound && dSigPresent,
            seenFaceValidAtMs: _seenFaceStamps,
            priorScores: List.of(_recentScores),
            lastVerifierVer: _lastVerifierVer,
          ),
          expectedCj: expectedCj,
          sessionId: w.sessionId,
          windowIdExpected: w.windowId,
          studentPk: stuPk,
          revoked: false, // no revocation source in the offline-local phase
          freshWindow: w.isFresh(j, t),
          singleUseOk: singleUse,
          requireBoundTicket: bound,
        );
      }

      // Single-use is scoped to (windowId, ID, j): every window carries a
      // fresh windowId, so an old claim can never collide — and a bare
      // (ID, j) key would false-reject a new window's same-j prove after a
      // retake (or burn the slot on a stale-window POST that fails
      // window-mismatch below). The clear() in openWindow stays as a belt
      // over the same-window suspenders.
      final useScope = '$id#${hexEncode(wid)}';
      var outcome = runVerify(sight, now, singleUse: _once.claim(useScope, j));

      // Sighting grace: crypto, freshness, single-use and face all passed
      // but the scan hasn't delivered the response yet (the POST beats the
      // scan — normal). The answer went on air BEFORE the POST, so wait
      // for the radio instead of failing a present student. A token that
      // ages past freshness during the wait honestly verdicts `late`.
      if (outcome.decision == ProveDecision.invalid &&
          outcome.reason == 'no-ble-sighting' &&
          peerW.length == 8) {
        final lateSight = await _awaitSighting(
            peerW: peerW,
            expectedAirKey: expectedAirKey,
            expectedUuid: expectedUuid);
        if (lateSight != null) {
          outcome = runVerify(lateSight, DateTime.now().toUtc(),
              singleUse: true); // claimed by the first verify above
        }
      }

      // Duplicate-POST idempotency: the client retries a POST up to 3x
      // when the ACK is lost on flaky WiFi. The retry carries the identical
      // body, so a bare (ID,j) replay is EXPECTED here — and the mark
      // already exists from the first processing. Confirm the duplicate
      // (tally unchanged) instead of failing a marked student as invalid.
      // A replay with no prior mark is still a genuine replay → invalid.
      if (outcome.decision == ProveDecision.invalid &&
          outcome.reason == 'replay-id-j' &&
          tally.isMarked(id, _windowNo)) {
        outcome = const VerifyOutcome(
            ProveDecision.confirmed, 'duplicate-confirmed');
      }

      // TLS channel binding: the client must have seen OUR cert.
      if (outcome.decision == ProveDecision.confirmed) {
        if (!bytesEqual(tlsFp, tls.fingerprint)) {
          outcome =
              const VerifyOutcome(ProveDecision.invalid, 'tls-mismatch');
        } else if (!ProxCrypto.verify(
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
      // The ACK binds the decision instant, not POST arrival: the sighting
      // grace above can hold the handler for seconds, and the receipt time
      // must match the verdict, not a stale timestamp.
      final decisionAt = DateTime.now().toUtc();
      final ackSig = ProxCrypto.sign(
        profSk,
        ProxCrypto.ackPreimage(
          sessionId: w.sessionId,
          windowId: w.windowId,
          j: j,
          studentId: id,
          decision: code,
          serverTimeMs: decisionAt.millisecondsSinceEpoch,
        ),
      );
      // `late` is crypto-valid but aged (grace wait outlived freshness):
      // the student WAS there, so the round keeps its mark — flagged late
      // so exports can tell it apart. Without this, late-only rounds
      // vanished from history entirely.
      if (outcome.decision == ProveDecision.confirmed ||
          outcome.decision == ProveDecision.late) {
        tally.mark(id, name, _windowNo,
            roll: roll, late: outcome.decision == ProveDecision.late);
      }
      // Tracks 2+3: feed the anomaly context (bounded) and surface flags
      // alongside the verdict. The signed ACK is unchanged; flags ride in
      // `flags` + the onProve reason suffix for the host log.
      final flags = outcome.attestationFlags;
      if (bound) {
        _seenFaceStamps.add(ticketStampMs);
        _recentScores.add(ticketScore);
        if (_recentScores.length > 8) _recentScores.removeAt(0);
        if (verifierVer.isNotEmpty) _lastVerifierVer = verifierVer;
      }
      final flaggedReason =
          flags.isEmpty ? outcome.reason : '${outcome.reason}|${flags.join(',')}';
      try {
        onProve?.call(id, outcome.decision.name, flaggedReason);
      } catch (_) {}
      return _json({
        'decision': switch (outcome.decision) {
          ProveDecision.confirmed => 'confirmed',
          ProveDecision.late => 'late',
          ProveDecision.invalid => 'invalid',
        },
        'reason': outcome.reason,
        if (flags.isNotEmpty) 'flags': flags,
        'serverTime': decisionAt.toIso8601String(),
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

  Future<Response> _guardedJson(
      Request req, FutureOr<Response> Function(Map<String, dynamic>) fn) async {
    if (req.url.queryParameters['token'] != bearer) {
      return _json({'error': 'forbidden'}, 403);
    }
    Map<String, dynamic> body = const {};
    try {
      final text = await req.readAsString();
      if (text.isNotEmpty) {
        body = jsonDecode(text) as Map<String, dynamic>;
      }
    } catch (_) {}
    return await fn(body);
  }

  Future<Response> _postWaiting(Request req) async {
    try {
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final email = (body['email'] as String? ?? '').toLowerCase();
      final name = body['name'] as String? ?? email;
      final roll = body['roll'] as String? ?? '';
      if (email.isEmpty) return _json({'error': 'bad-email'}, 400);
      final bodyOrg = (body['org'] as String? ?? '').trim().toLowerCase();
      if (sessionOrg.isNotEmpty &&
          bodyOrg.isNotEmpty &&
          bodyOrg != sessionOrg) {
        try {
          onProve?.call(email, 'invalid', 'org-mismatch');
        } catch (_) {}
        return _json(
            {'decision': 'invalid', 'reason': 'org-mismatch'}, 403);
      }
      registerWaiting(email, name, roll);
      return _json({'ok': true, 'waiting': waitingCount});
    } catch (e) {
      return _json({'error': 'bad-body: $e'}, 400);
    }
  }

  Future<Response> _postLeave(Request req) async {
    try {
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final email = (body['email'] as String? ?? '').toLowerCase();
      if (email.isEmpty) return _json({'error': 'bad-email'}, 400);
      final removed = removeWaiting(email);
      return _json({'ok': true, 'removed': removed, 'waiting': waitingCount});
    } catch (e) {
      return _json({'error': 'bad-body: $e'}, 400);
    }
  }

  Response _getWaiting() => _json({
        'waiting': waitingCount,
        'windowOpen': windowOpen,
        'windowNo': _windowNo,
        'rows': [for (final w in waitingRows) w.toJson()],
      });

  Future<Response> _postManualRequest(Request req) async {
    try {
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final email = (body['email'] as String? ?? '').toLowerCase();
      final name = body['name'] as String? ?? email;
      final roll = body['roll'] as String? ?? '';
      if (email.isEmpty) return _json({'error': 'bad-email'}, 400);
      final bodyOrg = (body['org'] as String? ?? '').trim().toLowerCase();
      if (sessionOrg.isNotEmpty &&
          bodyOrg.isNotEmpty &&
          bodyOrg != sessionOrg) {
        try {
          onProve?.call(email, 'invalid', 'org-mismatch');
        } catch (_) {}
        return _json(
            {'decision': 'invalid', 'reason': 'org-mismatch'}, 403);
      }
      requestManual(email, name, roll);
      return _json({'ok': true, 'status': manualStatus(email)});
    } catch (e) {
      return _json({'error': 'bad-body: $e'}, 400);
    }
  }

  Response _getManualRequests() => _json({
        'rows': [for (final m in manualRows) m.toJson()],
        'pending': manualPending.length,
      });

  Future<Response> _postManualDecide(Map<String, dynamic> body) async {
    final email = (body['email'] as String? ?? '').toLowerCase();
    final approve = (body['approve'] as bool?) ?? false;
    if (email.isEmpty) return _json({'error': 'bad-email'}, 400);
    final ok = decideManual(email, approve);
    if (!ok) return _json({'error': 'unknown-email'}, 404);
    return _json({'ok': true, 'status': manualStatus(email)});
  }

  Response _getLive() {
    return _json({
      'present': tally.presentCount,
      'waiting': waitingCount,
      'windowNo': _windowNo,
      'rows': [
        for (final r in tally.present)
          {
            'email': r.email,
            'name': r.name,
            'roll': r.roll,
            'wins': r.wins.toList()..sort(),
          }
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
