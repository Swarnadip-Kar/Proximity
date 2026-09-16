// Professor HTTPS server (shelf, foreground): §6.3 endpoints.
//
//   GET  /                human status page (no auth, no PII — class,
//                          window state, counts; diagnostics only)
//   GET  /window?org=     gated unicast identity (see _getWindow): matching
//                          or legacy org → {class, sessionID, windowID,
//                          j_now, pkP, sigP, tlsFp, display, org, profEmail,
//                          profPhoto?, profName?};
//                          mismatched org → 403 {decision, reason, org}
//                          (silence: no class, no email, no window).
//                          profEmail (lowercased host Gmail, '' = unknown)
//                          travels ONLY here — never in UDP beacons, never
//                          in BLE air packets, never in Sig_p/Sig_s.
//                          profName follows the same gated channel (never BLE).
//   POST /prove           {ID,windowID,j,C_j,Sig_s,faceScore,peerW,roll,
//                          tlsFp,sigBind} -> {confirmed|late|invalid,...}
//   GET  /live             counts + rows           (host bearer)
//   GET  /export           attendance.csv          (host bearer)
//
// Security notes:
//  - TLS cert is per-hosting runtime-generated (see tls.dart, LAN-IP SANs);
//    clients pin via channel binding (tlsFp + sigBind). A blind Evil-Twin
//    relay cannot present the professor's cert without its private key, so
//    relayed POSTs fail binding with `tls-mismatch`. First-connect cert
//    TOFU is the stated residual (UWB needed for a full close).
//  - BLE sightings come from the radio layer via [SightingLookup]; the
//    server never trusts client-claimed RSSI.
//  - Host bearer = hex(SHA-256(S_w)), fresh per window (rotated in
//    [openWindow]); pass via `Authorization: Bearer` (preferred — never in
//    URLs). A `?token=` query fallback stays for mixed fleets; the server
//    never logs request URIs and the path rides TLS.
//  - Rate limits: /prove 40/10s per IP AND 10/10s per ID, /window 5/10s/IP,
//    presence endpoints 20/10s per ID, all with Retry-After (§6.3).
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
  /// True when heard via a legacy v1 UUID (no direct-RSSI proof possible —
  /// air packets carry no TTL byte, so hop is always mapped 0; see
  /// matchResponse in the app's host driver). Drives the verify-rule log.
  final bool legacy;
  const RadioSighting(
      {required this.rssiDbm, required this.hop, this.legacy = false});
}

/// Which sighting rule marked the proof (host log only — the signed ACK
/// verdict is unchanged): `direct-rssi` (RSSI > kRssiDirectDbm on a v2 air
/// packet) vs `legacy-hop0-assumed` (v1 UUID or weak-signal path where
/// hop 0 is assumed because air packets carry no TTL byte).
String sightingRuleOf(RadioSighting? sight) {
  if (sight == null) return 'no-sighting';
  if (!sight.legacy && sight.rssiDbm > kRssiDirectDbm) return 'direct-rssi';
  return 'legacy-hop0-assumed';
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

  /// Hosting professor's Gmail (lowercased) for the GATED unicast /window
  /// only (see _getWindow). '' = unknown: the key is omitted so legacy
  /// payloads stay byte-equal. NEVER in UDP beacons (ClassAnnouncement has
  /// no such field by construction), NEVER in BLE air packets (IP:port
  /// only — asserted by tests), never in Sig_p/Sig_s. Set once at hosting
  /// start from the host account email; the window/prove path never
  /// mutates it.
  String sessionProfEmail;

  /// Hosting professor's Gmail profile photo URL for the GATED unicast
  /// /window only (same channel rules as [sessionProfEmail]). '' =
  /// unknown: the key is omitted so legacy payloads stay byte-equal.
  /// Settable after construction (the host account photo resolves after
  /// the server binds); students converge on the next 2s room poll. The
  /// student renders it with initials fallback, offline or absent.
  String sessionProfPhoto = '';

  /// Hosting professor's display name for the GATED unicast /window only
  /// (same channel rules as [sessionProfEmail]: LAN HTTPS, org-gated —
  /// never BLE air packets, which stay IP:port hints only). '' = unknown:
  /// the key is omitted so legacy payloads stay byte-equal. Set once at
  /// hosting start alongside the beacon `prof` name; the window/prove
  /// path never mutates it.
  String sessionProfName = '';

  /// Fired for every processed POST /prove (confirmed/late/invalid) so the
  /// host can log the verdict + reason live. Never throws (guarded).
  /// Also fires for org-mismatched /waiting + /manual-request rejects.
  final void Function(String email, String decision, String reason)? onProve;
  final SingleUseTracker _once = SingleUseTracker();
  // Tracks 2+3 anomaly context (server-kept, bounded): seen face-ticket
  // keys (reused-face flag), recent scores (1.000-repeat flag), last
  // pipeline tag (verifier-flapping flag).
  //
  // Ticket map (full-ticket key → FIRST ID that presented it),
  // WINDOW-scoped like the vector map: a legitimate retry re-presents its
  // own ticket across rotations (same ID, new j — the encouraged path), so
  // same-ID repeats must NOT flag. Only a DIFFERENT ID presenting an
  // already-seen FULL ticket flags (one face check transplanted across
  // Gmails — the actual hook signal). Keyed by the full ticket
  // (stamp + ticket hash incl. score/vers/liveness), NOT by stamp alone:
  // millis collisions across different holders in a large hall would
  // otherwise false-flag (500 holders in a 5min window collide with ~40%
  // chance on stamp alone; full-ticket collisions are transplant-only).
  // The anomaly call below receives other-IDs' stamps only (legacy stamp
  // scope for the stateless flag helper; the full-ticket gate below is
  // authoritative for transplant).
  final Map<int, String> _seenFaceStamps = {};
  // Full-ticket transplant map (authoritative): "$stampMs:$ticketHex" →
  // first ID. Window-scoped with the stamp map (see openWindow/closeWindow).
  final Map<String, String> _seenFaceTickets = {};
  final List<double> _recentScores = [];
  String _lastVerifierVer = '';
  // Local same-face dup path (RAM-only, window-scoped): email → canonical
  // int8 vector as received in `face:{vec}`. Planted only by
  // confirmed/late proofs carrying a usable vector; wiped on window close
  // AND window open (retake starts fresh) AND hosting teardown — vectors
  // never outlive the open window. Exemptions are SESSION-scoped (they
  // survive retakes; the server object lives for the whole hosting).
  final Map<String, FacePrintDoc> _faceVecs = {};
  final Set<String> _faceExemptPairs = {};
  static String _facePairKey(String a, String b) {
    final x = a.toLowerCase();
    final y = b.toLowerCase();
    return x.compareTo(y) <= 0 ? '$x\x00$y' : '$y\x00$x';
  }
  final RateLimiter _proveLimits = proveLimiter();
  final RateLimiter _windowLimits = windowLimiter();

  /// C1 TOFU pins (professor pre-fetch at online setup): emailLower →
  /// lowercased pkS hex first seen while online. Empty = pure TOFU (no
  /// roster lookup — studentDevices denies cross-Gmail get, so an online
  /// pre-fetch of other Gmails' keys is impossible under current rules;
  /// see host_driver TOFU note). When non-empty, an offline prove whose
  /// presented pkS mismatches the pin for that email fails closed as
  /// `unknown-pkS` (no silent re-key). Pins are structure-only hex
  /// comparisons — sealed/attestation bytes are never decrypted here.
  final Map<String, String> _pinnedPkS = {};

  /// Pins [emailLower] → [pkSHex] (first-seen-wins; re-pin requires
  /// explicit [force]). Returns true when the pin was (re)written.
  bool pinStudentKey(String emailLower, String pkSHex, {bool force = false}) {
    final email = emailLower.trim().toLowerCase();
    final pk = pkSHex.trim().toLowerCase();
    if (email.isEmpty || pk.isEmpty) return false;
    if (_pinnedPkS.containsKey(email) && !force) return false;
    _pinnedPkS[email] = pk;
    return true;
  }

  /// Bulk pre-fetch helper for online setup: pins every entry of
  /// [emailToPkSHex] first-seen-wins (unless [force]). Returns pinned count.
  /// [force] overwrites stale pins: the source is always the authenticated
  /// same-org directory merged over the persistent cache (never LAN), so a
  /// mid-class student re-enroll converges instead of refusing as
  /// `unknown-pkS` for the rest of the session.
  int pinStudentKeys(Map<String, String> emailToPkSHex, {bool force = false}) {
    var n = 0;
    emailToPkSHex.forEach((k, v) {
      if (pinStudentKey(k, v, force: force)) n++;
    });
    return n;
  }

  int get pinnedKeyCount => _pinnedPkS.length;

  /// Security §4 rollout flip: TRUE since the liveness rollout completed
  /// (MiniFASNetV2 model vendored + enrollment gated — sec-liveness): every
  /// Floor marker (pinned by hw_prove_test): the liveness rollout is done —
  /// [verifyProve] unconditionally requires a gated liveness ticket, and old
  /// builds are floored by the ForceUpdate barrier (app_config/min_version
  /// 0.2.0 + force:true) before they can prove. Kept as a named constant so
  /// the floor cannot be silently reverted.
  static const requireLivenessEnforced = true;

  /// Pinned attestation roots for the §2 chain gate (SHA-256 digests of
  /// trusted root DERs). Defaults to the Google Hardware Attestation roots
  /// ([defaultPinnedAttestationRoots]); tests inject throwaway pins.
  final List<Uint8List> pinnedAttestationRoots;

  /// Pinned Apple App Attest roots for the iOS branch (SHA-256 digests of
  /// trusted root DERs). Defaults to [defaultPinnedAppAttestRoots]; tests
  /// inject throwaway pins.
  final List<Uint8List> pinnedAppAttestRoots;

  /// Sighting grace: the student's response ADV precedes its POST, but the
  /// host BLE scan delivers sightings seconds later — a POST that is valid
  /// in every way EXCEPT a missing sighting waits this long for the radio
  /// instead of instantly failing. Without it, marking is a coin flip
  /// between WiFi latency and scan intervals. 6s covers the student 3x
  /// response burst (~1s) plus one duty-cycled scan window on balanced
  /// Android stacks; uniform on all platforms. Tests shrink it.
  Duration sightingGrace = const Duration(seconds: 6);

  /// Test-only chain-gate override (HW transport tests use fake-DER chains
  /// carrying the OID + challenge bytes but no X.509 signatures — the
  /// production [verifyAttestationChainPin] with checkValidity:true rejects
  /// them as bad-chain-der. The test stub reuses the REAL byte-helpers for
  /// challenge containment and approximates the leaf-pkD bind as
  /// byte-containment of the raw pkD (exact SPKI equality is covered at the
  /// protocol level on genuine Google fixtures in chain_verify_test).
  /// X.509 signature math is therefore NOT exercised here — only the
  /// dSig + challenge-recompute + tier wiring. Null = production gate.
  /// Never set outside tests.
  ChainPinResult Function({
    required AttestationChain chain,
    required List<Uint8List> pinnedRootHashes,
    required Uint8List expectedChallenge,
    required Uint8List? expectedLeafPkD,
    required AttestationLevel level,
    // iOS branch only: the enrollment App Attest CBOR raw hex ('' on the
    // Android path). Stubs ignore it unless they assert the branch.
    String appAttestRawHex,
  })? testChainGate;

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
    this.sessionProfEmail = '',
    this.sessionProfName = '',
    List<Uint8List>? pinnedRoots,
    List<Uint8List>? pinnedAppleRoots,
  })  : tally = tally ?? TallyStore(),
        pinnedAttestationRoots =
            pinnedRoots ?? defaultPinnedAttestationRoots(),
        pinnedAppAttestRoots =
            pinnedAppleRoots ?? defaultPinnedAppAttestRoots() {
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
  String get boundAddress => _http?.address.address ?? '?';
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
    // Fresh round = fresh vector map (a retake that skipped the grace
    // close must not compare against the previous window's vectors).
    // Exemptions survive: the professor's override is session-scoped.
    _faceVecs.clear();
    // Same window scope for ticket stamps + full tickets (a new window's
    // face checks mint new stamps; old entries would only false-flag).
    _seenFaceStamps.clear();
    _seenFaceTickets.clear();
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
    // Detection for the closing window is already complete (compare runs
    // per prove, including stop-grace proofs) — vectors must not outlive it.
    _faceVecs.clear();
    // Ticket stamps + full tickets share the window scope (see openWindow).
    _seenFaceStamps.clear();
    _seenFaceTickets.clear();
  }
  int get windowNo => _windowNo;

  /// Drops all session vectors from RAM NOW (hosting teardown calls this
  /// explicitly before dropping the server — audit both paths).
  void clearFaceVectors() => _faceVecs.clear();

  /// Held vectors right now (observability/tests — count only, never the
  /// bytes: vectors are never logged, never exported).
  int get faceVectorCount => _faceVecs.length;

  /// Professor override: this pair never flags again this session. The
  /// professor SEES both faces in the room — the human resolves what the
  /// matcher cannot (twins/siblings). Survives retakes (unlike vectors).
  void exemptFacePair(String a, String b) {
    if (a.trim().isEmpty || b.trim().isEmpty) return;
    _faceExemptPairs.add(_facePairKey(a, b));
  }

  // ---- Waiting room (students join before the window opens) ----
  // Delegated to LiveRoom (identical semantics; see live_room.dart).
  // Returns the leave token ('' when nothing registered).
  String registerWaiting(String email, String name,
          [String roll = '', String photoUrl = '']) =>
      room.registerWaiting(email, name, roll, photoUrl);

  /// Explicit leave over HTTP (token-enforced — see [_postLeave]).
  bool removeWaiting(String email, {String leaveToken = ''}) =>
      room.removeWaiting(email, leaveToken: leaveToken);

  /// Server-internal waiting drop (mark auto-exit): token-free by
  /// construction (the server owns it).
  bool dropWaiting(String email) => room.dropWaiting(email);

  /// Professor eject: drops one email from waiting + manual queue + tally
  /// (session-local; saved history untouched until the next upsert).
  /// Rejoin/re-mark re-adds. Returns true when anything was removed.
  bool removeStudent(String email) => room.removeStudent(email);

  List<WaitingEntry> get waitingRows => room.waitingRows;

  int get waitingCount => room.waitingCount;

  // ---- Manual attendance over LAN ----
  void requestManual(String email, String name,
          [String roll = '', String photoUrl = '']) =>
      room.requestManual(email, name, roll, photoUrl);

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

  /// M5 per-ID+IP limiter (10/10s per email+IP): bounds one device
  /// hammering many IDs behind one NAT IP, where the IP-only _proveLimits
  /// (40/10s/IP) is too coarse. Keyed ip|id after body parse (see
  /// _postProve); the IP gate above still runs first.
  final RateLimiter _proveIdLimits =
      RateLimiter(maxHits: 10, window: kRateWindow);

  /// M5 presence-endpoint limiter (20/10s/IP shared): /waiting, /leave and
  /// /manual-request were unguarded — one loop could fill the professor's
  /// waiting list. Window-membership itself stays presence-volunteered
  /// (no crypto proof at join — /prove owns marking); the gate here is
  /// rate + org-match, never identity.
  final RateLimiter _presenceLimits =
      RateLimiter(maxHits: 20, window: kRateWindow);

  Response _rateLimited() => Response(429,
      body: jsonEncode({'error': 'rate-limited'}),
      headers: {'content-type': 'application/json', 'retry-after': '10'});

  Future<Response> _route(Request req) async {
    final path = req.url.pathSegments;
    try {
      if (req.method == 'GET' && path.length == 1 && path[0] == 'window') {
        if (!_windowLimits.allow(_ip(req))) {
          return _rateLimited();
        }
        return _getWindow(req);
      }
      if (req.method == 'POST' && path.length == 1 && path[0] == 'prove') {
        if (!_proveLimits.allow(_ip(req))) {
          return _rateLimited();
        }
        return await _postProve(req);
      }
      if (req.method == 'POST' && path.length == 1 && path[0] == 'waiting') {
        if (!_presenceLimits.allow(_ip(req))) {
          return _rateLimited();
        }
        return await _postWaiting(req);
      }
      if (req.method == 'POST' && path.length == 1 && path[0] == 'leave') {
        if (!_presenceLimits.allow(_ip(req))) {
          return _rateLimited();
        }
        return await _postLeave(req);
      }
      if (req.method == 'GET' && path.length == 1 && path[0] == 'waiting') {
        return _guarded(req, _getWaiting);
      }
      if (req.method == 'POST' &&
          path.length == 1 &&
          path[0] == 'manual-request') {
        if (!_presenceLimits.allow(_ip(req))) {
          return _rateLimited();
        }
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
      // Human reachability page on the SAME port (deliberately not a
      // second port: no extra bind, no extra firewall hole, no new
      // attack surface). No auth, no PII — class label (already in
      // beacons), window state, counts, server time. If a phone browser
      // loads this, unicast reaches the host; if not, the break is the
      // network/firewall, not the app. Unrate-limited by design: a
      // diagnostic must answer even under prove load.
      if (req.method == 'GET' && path.isEmpty) {
        return _statusPage();
      }
      return _json({'error': 'not-found'}, 404);
    } catch (e) {
      return _json({'error': '$e'}, 500);
    }
  }

  /// Human status page (see route comment): class label is escaped
  /// (professor-typed); roster data never leaves guarded endpoints.
  Response _statusPage() {
    const esc = HtmlEscape();
    final cls = esc.convert(classLabel);
    final state = windowOpen ? 'window OPEN — marking' : 'idle — waiting room open';
    final body = '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>Proximity attendance — running</title></head><body>'
        '<h1>Proximity attendance system running</h1>'
        '<p>Class: <b>$cls</b><br>State: <b>$state</b><br>'
        'Waiting: <b>$waitingCount</b><br>'
        'Server time (UTC): <b>${DateTime.now().toUtc().toIso8601String()}</b></p>'
        '<p>Students mark attendance in the Proximity app (same WiFi + '
        'Bluetooth on). This page only proves your device reaches the host.</p>'
        '</body></html>';
    return Response.ok(body, headers: {'content-type': 'text/html'});
  }

  /// Gated unicast identity (org-gated discovery — the ONLY wire carrier
  /// of [sessionProfEmail]).
  ///
  /// The student sends its org claim FIRST as `?org=` (the waitlist intent
  /// for discovery); the professor org-checks it HERE and responds ONLY on
  /// match — only then does the class (with the prof email) appear on that
  /// student's phone. Foreign org gets silence: 403 with NO class, NO
  /// email, NO window material (the `org` echo only feeds the wrong-org
  /// card for typed-IP joins; beacons already broadcast it). Legacy '' on
  /// either side passes (migration) and renders as before (email key
  /// omitted when unknown so payloads stay byte-equal).
  ///
  /// Chosen over the POST /waiting reply because /window is already the
  /// unicast identity path: pinned-TLS GET, idempotent, rate-limited,
  /// already probed per hinted host (probeHost) and per waiting room
  /// (probeWindow) — email rides zero new round-trips. /waiting stays a
  /// presence heartbeat (403 on mismatch) and /prove stays the marking
  /// gate: both remain as defense-in-depth behind this primary gate.
  Response _getWindow(Request req) {
    final queryOrg =
        (req.url.queryParameters['org'] ?? '').trim().toLowerCase();
    if (sessionOrg.isNotEmpty &&
        queryOrg.isNotEmpty &&
        queryOrg != sessionOrg) {
      try {
        onProve?.call(queryOrg, 'invalid', 'org-mismatch');
      } catch (_) {}
      return _json({
        'decision': 'invalid',
        'reason': 'org-mismatch',
        'org': sessionOrg,
      }, 403);
    }
    final email = sessionProfEmail.trim().toLowerCase();
    final profPhoto = sessionProfPhoto.trim();
    final profName = sessionProfName.trim();
    final w = _window;
    if (w == null) {
      return _json({
        'class': classLabel,
        'windowOpen': false,
        'waiting': waitingCount,
        'pkP': hexEncode(profPk.bytes.sublist(0, 32)),
        'tlsFp': hexEncode(tls.fingerprint),
        'org': sessionOrg,
        if (email.isNotEmpty) 'profEmail': email,
        if (profPhoto.isNotEmpty) 'profPhoto': profPhoto,
        if (profName.isNotEmpty) 'profName': profName,
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
        if (email.isNotEmpty) 'profEmail': email,
        if (profPhoto.isNotEmpty) 'profPhoto': profPhoto,
        if (profName.isNotEmpty) 'profName': profName,
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
      if (email.isNotEmpty) 'profEmail': email,
      if (profPhoto.isNotEmpty) 'profPhoto': profPhoto,
      if (profName.isNotEmpty) 'profName': profName,
      if (prev != null) ...prev,
    });
  }

  Future<Response> _postProve(Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final now = DateTime.now().toUtc();
    final w = _window;
    if (w == null) {
      // Window closed (or never opened): no session/window context exists
      // to sign an ACK with, so this is the ONE unsigned invalid verdict
      // (serverTime present, zero sig). The client maps `window-closed`
      // to prove-the-next-rotation BEFORE any ACK check — never BAD-sig.
      return _json({
        'decision': 'invalid',
        'reason': 'window-closed',
        'serverTime': now.toUtc().toIso8601String(),
        'sigAck': hexEncode(Uint8List(64)),
      }, 200);
    }
    // Signed-invalid helper for the early gates below (org-mismatch,
    // unknown-pkS): EVERY /prove verdict carries a real Sig_p ACK over
    // (session||window||j||ID||invalid||time), so the student verifies the
    // rejection as authentic instead of logging `BAD prof signature`.
    // The wire `reason` stays bare; log-only tokens ride the onProve
    // suffix (parsed by prefix, never shown).
    Response signedInvalid(String id, int j, String reason,
        {String logSuffix = ''}) {
      final at = DateTime.now().toUtc();
      final sig = ProxCrypto.sign(
        profSk,
        ProxCrypto.ackPreimage(
          sessionId: w.sessionId,
          windowId: w.windowId,
          j: j,
          studentId: id,
          decision: decisionCode(ProveDecision.invalid),
          serverTimeMs: at.millisecondsSinceEpoch,
        ),
      );
      try {
        onProve?.call(id, 'invalid',
            logSuffix.isEmpty ? reason : '$reason|$logSuffix');
      } catch (_) {}
      return _json({
        'decision': 'invalid',
        'reason': reason,
        'serverTime': at.toUtc().toIso8601String(),
        'sigAck': hexEncode(sig),
      }, 200);
    }
    try {
      final id = (body['ID'] as String).toLowerCase();
      // j parses BEFORE the org gate: the early invalid verdicts below
      // sign their ACKs, and the preimage needs j. Malformed bodies still
      // fail as bad-body in the catch below.
      final jEarly = body['j'] as int;
      // H2: session-stamped org gates /prove strictly — empty body org
      // fails closed (missingOrg grace sunset on the LAN path). The shape
      // mirrors _fail so ProxClient.prove parses without retrying.
      final bodyOrg = (body['org'] as String? ?? '').trim().toLowerCase();
      if (sessionOrg.isNotEmpty &&
          (bodyOrg.isEmpty || bodyOrg != sessionOrg)) {
        return signedInvalid(id, jEarly, 'org-mismatch');
      }
      // M5 per-ID+IP gate (after id parse, before crypto): one device
      // hammering many IDs behind one NAT IP is bounded per identity.
      if (!_proveIdLimits.allow('${_ip(req)}|$id')) {
        return _rateLimited();
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
      // images/embeddings leave the device) + pkD + dSig. Absent fields
      // mean an unbound proof, which never confirms (`liveness-unbound`).
      // Bound → extended Sig_s + allowlist + tiers.
      // `bound` keys on TICKET CONTENT, not map presence: the local dup
      // vector rides `face:{vec}` on unbound proofs too, and a vec-only map
      // must NOT flip an unbound-Sig_s proof into the bound path.
      final faceMap = body['face'] as Map<String, dynamic>?;
      final ticketStampMs =
          (faceMap?['faceValidAt'] as num?)?.toInt() ?? 0;
      final verifierVer = faceMap?['verifierVer'] as String? ?? '';
      // Security §4 liveness ticket: `liveness:{score,ver}` (classifier
      // output only, no images). Absent/0.0/'' = pre-liveness client.
      final liveMap = body['liveness'] as Map<String, dynamic>?;
      final livenessScore =
          (liveMap?['score'] as num?)?.toDouble() ?? 0.0;
      final livenessVer = liveMap?['ver'] as String? ?? '';
      // Security §5 integrity flag: `integrityFlag` top-level or inside
      // `att` (both accepted; top-level wins). '' = clean/legacy,
      // 'integrity-flagged' rides the outcome flags (never auto-absent).
      final integrityFlag = (body['integrityFlag'] as String? ??
              (body['att'] as Map<String, dynamic>?)?['integrityFlag']
                  as String? ??
              '')
          .trim();
      final bound = verifierVer.isNotEmpty ||
          ticketStampMs != 0 ||
          livenessVer.isNotEmpty ||
          livenessScore != 0.0;
      final ticketScore =
          (faceMap?['score'] as num?)?.toDouble() ?? faceScore;
      // Local dup vector (`face:{vec}` — base64 int8 mean embedding). Parse
      // is fail-soft: absent/oversized/garbage means no dup participation
      // for this proof (same as a legacy proof), never a 400.
      var faceVecB64 = '';
      try {
        final v = faceMap?['vec'] as String? ?? '';
        if (v.isNotEmpty && v.length <= 1024) faceVecB64 = v;
      } catch (_) {}
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
      // Security §2 HW binding (sec-hwkey): `pkD` (64B P-256 x||y) +
      // `dSig` (64B raw R||S over deviceProvePreimage). The P-256 math
      // runs below ([verifyDeviceSignature]); X.509 chain SIGNATURE math
      // is explicitly out of scope (offline pin+challenge gate instead —
      // see the chain gate after verify) — the residual is stated, never
      // silent.
      final attMap = body['att'] as Map<String, dynamic>?;
      final attLevel = attestationLevelOf(attMap?['level'] as String? ?? 'NONE');
      final attUntil = attMap?['until'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (attMap!['until'] as num).toInt(), isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      final ticket = bound
          ? ProxCrypto.faceTicketHash(
              faceScore: ticketScore,
              faceValidAtMs: ticketStampMs,
              verifierVer: verifierVer,
              livenessScore: livenessScore,
              livenessVer: livenessVer)
          : Uint8List(0);

      // Rosterless (offline-local phase): the student presents its device
      // key and a bound+liveness+FULL proof verifies against it —
      // trust-on-first-use per class, no roster lookup. Liveness, radio
      // freshness, single-use, face score, sighting, dSig, chain pin and
      // channel binding all gate. Email is self-asserted
      // (verified identity returns with the professor-sign-in phase).
      final presentedPk =
          Uint8List.fromList(hexDecode(body['pkS'] as String? ?? ''));
      if (presentedPk.length != 32) {
        return _json(
            {'decision': 'invalid', 'reason': 'bad-body: pkS'}, 400);
      }
      // C1 TOFU enforcement: a pinned pkS mismatching the presented key
      // fails closed (unknown-pkS). Unpinned emails stay TOFU (first prove
      // pins implicitly only via explicit pinStudentKeys — never auto-pin
      // here, so a transient attacker cannot self-pin over the LAN).
      // Offline-first reading: an UNPINNED email is NOT fatal for being
      // offline — first-seen proves mark normally (TOFU) and the host log
      // carries a `first-seen` token (see the flagged reason below). A
      // PINNED mismatch (stale pin after a student re-enroll, or a second
      // device) fails closed; the log suffix says `pin-mismatch` (not
      // "unknown") and the ACK is signed, so the student sees the true
      // `unknown-pkS` verdict instead of `BAD prof signature`.
      final presentedPkHex = hexEncode(presentedPk).toLowerCase();
      final pinned = _pinnedPkS[id];
      if (pinned != null && pinned != presentedPkHex) {
        return signedInvalid(id, jEarly, 'unknown-pkS',
            logSuffix:
                'pin-mismatch presented=${presentedPkHex.substring(0, 8)}…');
      }
      final stuPk = ed.PublicKey(presentedPk);

      final expectedCj = w.challengeFor(j);
      // Security §2 (sec-hwkey): REAL dSig verification + chain pin
      // inputs. The enrollment challenge is recomputed from the LAN body
      // (ID, installId, pkS) — the same canonical the client bound into
      // the HW key at creation (no server nonce exists offline). `dSig`
      // verifies over the canonical deviceProvePreimage with the
      // EXPECTED challenge (a claimed-challenge mismatch already fails as
      // `bad-challenge` in verify below).
      final bodyInstallId =
          (body['installId'] as String? ?? '').trim();
      AttestationChain? proveChain;
      try {
        final rawChain = body['attestationChain'];
        if (rawChain is List && rawChain.isNotEmpty) {
          proveChain = AttestationChain.fromHexList(
              [for (final e in rawChain) '${e ?? ''}']);
        }
      } catch (_) {
        proveChain = null;
      }
      // Enrollment challenge (V2 canonical, domain-separated +
      // length-prefixed) bound at key creation (HwDeviceKey.bindEnrollment).
      // The professor recomputes exactly it — no alternates, no migration
      // accepts. Structure/length/challenge containment only — the
      // leaf bytes are never decrypted or interpreted.
      final expectedAttChallenge = deviceBindingChallengeV2(
        emailLower: id,
        installId: bodyInstallId,
        pkS: presentedPk,
      );
      // Security §5 integrity binding (sec-gates): `integrityHash` is the
      // 8-hex verdict hash the HW key SIGNED inside dSig. The preimage is
      // recomputed with the CLAIMED hash, so a transplanted dSig (wrong
      // hash, or a pre-binding dSig with no trailing field) fails verify.
      // dSig-gated (FULL/STD: pkD+dSig present) proofs additionally REQUIRE
      // a well-formed hash — proofs without one fail closed
      // here as device-unproven, never a silent downgrade to the hash-less
      // preimage. NONE proofs never confirm (`device-none-requires-approval`
      // in verify); their advisory `integrity-flagged` flag still rides the
      // outcome flags below.
      final integrityHash =
          ((body['integrityHash'] as String?) ?? '').trim().toLowerCase();
      final integrityHashOk =
          RegExp(r'^[0-9a-f]{8}$').hasMatch(integrityHash);
      final hwClaimed = pkD.isNotEmpty && dSig.isNotEmpty;
      var dSigValidReal = false;
      if (bound && ticket.isNotEmpty) {
        if (hwClaimed && !integrityHashOk) {
          dSigValidReal = false;
        } else {
          dSigValidReal = verifyDeviceSignature(
            pkDRaw64: pkD,
            preimage: ProxCrypto.deviceProvePreimage(
              sessionId: w.sessionId,
              windowId: w.windowId,
              j: j,
              challenge: expectedCj,
              faceTicketHashBytes: ticket,
              pkS: presentedPk,
              integrityHash: integrityHashOk ? integrityHash : '',
            ),
            sig64: dSig,
          );
        }
      }
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
            livenessScore: livenessScore,
            livenessVer: livenessVer,
            attestationLevel: bound ? attLevel : AttestationLevel.none,
            attestedUntil: attUntil,
            dSigValid: bound && dSigValidReal,
            // Transplant-only scope (see _seenFaceTickets): reused-face is
            // gated by the FULL ticket below (authoritative), not by stamp
            // alone — millis collisions across holders would otherwise
            // false-flag in large halls. Pass empty here so the stateless
            // helper never flags on stamp alone; the full-ticket check
            // after verify adds `attest-reused-face` only on a true
            // cross-Gmail ticket transplant. Same-ID retries never flag.
            seenFaceValidAtMs: const {},
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
      // The sighting that actually verified (drives the verify-rule log).
      RadioSighting? verifiedSight = sight;

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
          verifiedSight = lateSight;
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

      // TLS channel binding: the client must have seen OUR cert. M5 V2
      // (ID-bound) verifies first; V1 (legacy, no ID) is the migration
      // fallback so mixed fleets keep marking. New clients MUST send V2.
      bool bindOk(Uint8List preimage) =>
          ProxCrypto.verify(stuPk, preimage, sigBind);
      if (outcome.decision == ProveDecision.confirmed) {
        if (!bytesEqual(tlsFp, tls.fingerprint)) {
          outcome =
              const VerifyOutcome(ProveDecision.invalid, 'tls-mismatch');
        } else {
          final v2 = bindPreimageV2(
            sessionId: w.sessionId,
            windowId: w.windowId,
            j: j,
            tlsFingerprint: tls.fingerprint,
            studentId: id,
          );
          final v1 = bindPreimage(
            sessionId: w.sessionId,
            windowId: w.windowId,
            j: j,
            tlsFingerprint: tls.fingerprint,
          );
          if (!bindOk(v2) && !bindOk(v1)) {
            outcome = const VerifyOutcome(ProveDecision.invalid, 'bad-bind');
          }
        }
      }

      // Security §2 chain gate (sec-hwkey): a confirming FULL/STD proof
      // must carry a chain that (a) is well-formed with the attestation
      // OID, (b) embeds the recomputed enrollment challenge (V2 canonical),
      // (c) binds the leaf SPKI to the proving pkD
      // (expectedLeafPkD — structure-only compare, no decryption), (d)
      // validates X.509 signatures + validity dates, and (e) pins to the
      // Google roots. Any failure verdicts device-unproven (never a tier,
      // never a silent presence flag). NONE proofs never reach this as
      // confirms (verify fails them first); unbound proofs never reach it
      // (their level parses as none).
      //
      // iOS branch (Apple App Attest CBOR in `appAttestRaw`, '' on
      // Android): the Android OID gate cannot apply (App Attest leaves
      // carry the Apple nonce extension, never the Google OID), so Apple
      // proofs verify via `verifyAppAttestChainPin` (object path: x5c vs
      // Apple roots + SE-key/challenge nonce binding, STD tier) or
      // `verifyAppAttestAssertionProof` (assertion path: signature under
      // the enrollment credential key + recomputed clientDataHash — the
      // credential key itself is TOFU there, see app_attest.dart). The
      // branch is selected by artifact presence, never by a claimed
      // platform string (unspoofable routing: an Android chain fails the
      // Apple pin and vice versa). The Android path below is unchanged.
      final appAttestRawHex =
          ((body['appAttestRaw'] as String?) ?? '').trim().toLowerCase();
      final appAttestCredKeyHex =
          ((body['appAttestCredKey'] as String?) ?? '').trim().toLowerCase();
      final iosBranch = appAttestRawHex.isNotEmpty;
      if ((outcome.decision == ProveDecision.confirmed ||
              outcome.decision == ProveDecision.late) &&
          attLevel != AttestationLevel.none) {
        final ChainPinResult pin;
        if (!iosBranch) {
          pin = proveChain == null
              ? const ChainPinResult(
                  ok: false,
                  reason: 'empty-chain',
                  flags: ['attest-empty-chain'])
              : testChainGate != null
                  ? testChainGate!(
                      chain: proveChain,
                      pinnedRootHashes: pinnedAttestationRoots,
                      expectedChallenge: expectedAttChallenge,
                      expectedLeafPkD: pkD.isNotEmpty ? pkD : null,
                      level: attLevel,
                    )
                  : verifyAttestationChainPin(
                      chain: proveChain,
                      pinnedRootHashes: pinnedAttestationRoots,
                      expectedChallenge: expectedAttChallenge,
                      expectedLeafPkD: pkD.isNotEmpty ? pkD : null,
                      level: attLevel,
                      checkValidity: true,
                    );
        } else {
          pin = _verifyIosBranch(
            appAttestRawHex: appAttestRawHex,
            appAttestCredKeyHex: appAttestCredKeyHex,
            expectedAttChallenge: expectedAttChallenge,
            pkD: pkD,
            attLevel: attLevel,
          );
        }
        if (!pin.ok) {
          // Root diagnostic (log only): WHICH unrecognized anchor refused
          // the chain — the host log carries `root=<sha256-prefix>` so one
          // glance distinguishes a software/emulator/ROM root (fail-closed
          // by design — compare against the pinned Google HW roots (RSA
          // 2019/2021/2022 vintages + EC CA1))
          // from a truncated chain. Public anchor hash, never key material.
          var rootToken = '';
          if (pin.reason == 'unknown-root' && proveChain != null) {
            try {
              final root = proveChain.root;
              if (root != null && root.isNotEmpty) {
                rootToken =
                    'root=${hexEncode(ProxCrypto.sha256Sync(root)).substring(0, 8)}';
              }
            } catch (_) {}
          }
          outcome = VerifyOutcome(
              ProveDecision.invalid,
              'device-unproven',
              [
                ...outcome.attestationFlags,
                ...pin.flags,
                if (rootToken.isNotEmpty) rootToken
              ]);
        } else {
          // Flag-only KeyDescription boot telemetry (attendance posture,
          // fail-open): unlocked / unverified-boot / software-level ride as
          // advisory flags alongside the confirming verdict — never a
          // verdict change. Unparseable leaves (fake units, future KeyMint)
          // emit no flags. iOS branch skipped (App Attest leaves carry no
          // Android KeyDescription).
          if (!iosBranch && proveChain != null) {
            try {
              final leaf = proveChain.leaf;
              if (leaf != null && leaf.isNotEmpty) {
                final bootFlags = bootFlagsOf(leaf);
                if (bootFlags.isNotEmpty) {
                  outcome = VerifyOutcome(
                    outcome.decision,
                    outcome.reason,
                    [...outcome.attestationFlags, ...bootFlags],
                  );
                }
              }
            } catch (_) {}
          }
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
            roll: roll,
            late: outcome.decision == ProveDecision.late,
            // Stamp the volunteered presence photo so the present roster
            // card matches the waiting card (same StudentCard contract).
            photoUrl: room.photoFor(id));
        // Marked-complete auto-exit (SYNC-owned): the /prove verdict IS
        // the waiting-area leave — the student app parks on its marked
        // badge and re-registers via presence on the next round, so the
        // waiting count drops at mark time instead of lingering until an
        // explicit /leave (Cancel/back/dispose only). Piggybacked on this
        // in-flight response: zero new requests, endpoints, or fields.
        // Invalid proofs keep their waiting entry (the student is still
        // unmarked — retry/manual paths own their own leave).
      dropWaiting(id);
    }
    // Local same-face dup check (RAM-only, window-scoped): exact cosine
      // over dequantized vectors, O(session) per prove. Runs on marked
      // proofs carrying a usable vector — no bound ticket required
      // (pipeline-equality inside the matcher is the comparability gate:
      // '' == '' compares, 'x' vs 'y' skips). Invalid proofs plant nothing
      // (no framing via junk POSTs); legacy proofs without vectors
      // participate in nothing. The vector is stored VERBATIM as received
      // (already canonical int8 base64 from the student's quantize — no
      // float round-trip); compare-then-plant so a retry never self-flags.
      // Residuals, stated: custom clients can omit/garbage vectors
      // (evasion only — transplanting another holder's vector merely
      // self-flags, and the Sig_s face-ticket crypto above is untouched);
      // proofs without vectors mark normally.
      final dupPeers = <String>[];
      final markedNow = outcome.decision == ProveDecision.confirmed ||
          outcome.decision == ProveDecision.late;
      // Validate-before-plant: garbage own-vectors mark normally but plant
      // nothing (no RAM noise, no count noise).
      var vecPlanted = false;
      if (markedNow &&
          faceVecB64.isNotEmpty &&
          faceVecDecode(faceVecB64) != null) {
        final mine = FacePrintDoc(
            org: '', verifierVer: verifierVer, embQ: faceVecB64,
            buckets: const [], updatedAtMillis: 0);
        for (final h in findFaceDuplicates(
            myEmail: id, mine: mine, others: _faceVecs)) {
          if (!_faceExemptPairs.contains(_facePairKey(id, h.email))) {
            dupPeers.add(h.email);
          }
        }
        _faceVecs[id] = mine;
        vecPlanted = true;
      }
      // Tracks 2+3: feed the anomaly context (bounded) and surface flags
      // alongside the verdict. The signed ACK is unchanged; flags ride in
      // `flags` + the onProve reason suffix for the host log.
      // Security §5: client-asserted `integrity-flagged` rides alongside
      // (never a verdict change offline — professor-visible flag only).
      final flags = [
        ...outcome.attestationFlags,
        if (integrityFlag == 'integrity-flagged') 'integrity-flagged',
      ];
      if (bound) {
        // First presenter wins the stamp + full ticket (transplant scope:
        // a LATER different ID re-presenting the FULL ticket flags;
        // same-ID retries never do; millis-only collisions never flag).
        _seenFaceStamps.putIfAbsent(ticketStampMs, () => id);
        // Full-ticket transplant gate (authoritative for reused-face):
        // key binds stamp + score/vers/liveness via the ticket hash, so a
        // transplanted face check across Gmails flags while coincidental
        // millis equality does not.
        var transplant = false;
        try {
          if (ticket.isNotEmpty && ticketStampMs != 0) {
            final ticketKey = '$ticketStampMs:${hexEncode(ticket)}';
            final first = _seenFaceTickets[ticketKey];
            if (first == null) {
              _seenFaceTickets[ticketKey] = id;
            } else if (first != id) {
              transplant = true;
            }
          }
        } catch (_) {}
        if (transplant && !flags.contains('attest-reused-face')) {
          flags.add('attest-reused-face');
        }
        _recentScores.add(ticketScore);
        if (_recentScores.length > 8) _recentScores.removeAt(0);
        if (verifierVer.isNotEmpty) _lastVerifierVer = verifierVer;
      }
      // Verify-rule log: which sighting rule marked this proof. Confirmed
      // and late verdicts name it (direct-rssi vs legacy-hop0-assumed);
      // invalid verdicts keep the bare reason (nothing marked). The JSON
      // `reason` below stays the bare outcome — the rule rides only the
      // host log line via onProve, never the wire verdict.
      final marked =
          outcome.decision == ProveDecision.confirmed || outcome.decision == ProveDecision.late;
      final rule = marked ? sightingRuleOf(verifiedSight) : '';
      final flaggedReason = [
        outcome.reason,
        if (rule.isNotEmpty) rule,
        ...flags,
        // First-seen TOFU marker (log only, never the wire verdict): this
        // email had NO pin when it proved and marked normally anyway —
        // offline first sight is not fatal. Lets the professor tell
        // "marked on first sight (TOFU)" apart from "marked on a known
        // pin" in the terminal, and from `unknown-pkS|pin-mismatch`
        // (a STALE pin refusing a re-enrolled key) above.
        if (marked && pinned == null) 'first-seen',
        // Vector receipt marker (log only, never the wire verdict): a
        // decodable session vector planted with no dup match. Lets the
        // professor terminal confirm the dedup path is ARMED per prove
        // (`vec-ok` = vectors arriving + comparing, just no twins this
        // round) instead of wondering whether vectors arrive at all. A
        // matched pair rides `dupface:` instead (never both).
        if (vecPlanted && dupPeers.isEmpty) 'vec-ok',
        // Dup pair rides the host log line (never the wire verdict): the
        // app parses it into roster flags + override. Peers only — the
        // prover is the callback's first arg. Neutral copy at the UI, not
        // here: this token is machine-readable, never shown.
        if (dupPeers.isNotEmpty) 'dupface:${dupPeers.join(',')}',
      ].join('|');
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

  /// H9: bearer via `Authorization: Bearer` (preferred — never logged in
  /// URLs) with legacy `?token=` fallback for mixed fleets.
  bool _bearerOk(Request req) {
    final auth = req.headers['authorization'] ?? '';
    if (auth.startsWith('Bearer ')) {
      return auth.substring('Bearer '.length).trim() == bearer;
    }
    return req.url.queryParameters['token'] == bearer;
  }

  Response _guarded(Request req, Response Function() fn) {
    if (!_bearerOk(req)) {
      return _json({'error': 'forbidden'}, 403);
    }
    return fn();
  }

  Future<Response> _guardedJson(
      Request req, FutureOr<Response> Function(Map<String, dynamic>) fn) async {
    if (!_bearerOk(req)) {
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

  /// iOS App Attest branch of the §2 chain gate (see the call site for the
  /// routing + trust contract). Object path verifies the x5c chain vs the
  /// Apple roots with the SE-key/challenge nonce binding (STD tier);
  /// assertion path verifies the signature under the enrollment credential
  /// key with the recomputed clientDataHash (credential key TOFU there).
  /// Malformed CBOR/hex fails closed as `device-unproven` (never throws).
  ChainPinResult _verifyIosBranch({
    required String appAttestRawHex,
    required String appAttestCredKeyHex,
    required Uint8List expectedAttChallenge,
    required Uint8List pkD,
    required AttestationLevel attLevel,
  }) {
    late final ParsedAppAttestRaw parsed;
    try {
      parsed = ParsedAppAttestRaw.parse(hexDecode(appAttestRawHex));
    } catch (_) {
      return const ChainPinResult(
          ok: false,
          reason: 'bad-appattest-cbor',
          flags: ['attest-bad-appattest-cbor']);
    }
    if (parsed.kind == AppAttestRawKind.attestationObject) {
      final iosChain = AttestationChain(parsed.x5c);
      if (testChainGate != null) {
        return testChainGate!(
          chain: iosChain,
          pinnedRootHashes: pinnedAppAttestRoots,
          expectedChallenge: expectedAttChallenge,
          expectedLeafPkD: pkD.isNotEmpty ? pkD : null,
          level: attLevel,
          appAttestRawHex: appAttestRawHex,
        );
      }
      return verifyAppAttestChainPin(
        chain: iosChain,
        pinnedRootHashes: pinnedAppAttestRoots,
        expectedChallenge: expectedAttChallenge,
        expectedPkD: pkD,
        appAttestAuthData: parsed.authData,
        level: attLevel,
        checkValidity: true,
      );
    }
    Uint8List credKey;
    try {
      credKey = hexDecode(appAttestCredKeyHex);
    } catch (_) {
      credKey = Uint8List(0);
    }
    if (testChainGate != null) {
      return testChainGate!(
        chain: AttestationChain(const []),
        pinnedRootHashes: pinnedAppAttestRoots,
        expectedChallenge: expectedAttChallenge,
        expectedLeafPkD: pkD.isNotEmpty ? pkD : null,
        level: attLevel,
        appAttestRawHex: appAttestRawHex,
      );
    }
    return verifyAppAttestAssertionProof(
      assertionAuthData: parsed.authData,
      assertionSignature: parsed.signature,
      expectedChallenge: expectedAttChallenge,
      expectedPkD: pkD,
      credentialPubKey64: credKey,
    );
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
      final leaveToken = registerWaiting(email, name, roll,
          (body['photo'] as String? ?? '').trim());
      // Piggybacked window sample for the join fast-path (SYNC-owned):
      // this POST just proved the host reachable over TLS, so shipping
      // the live window flag + display code on the in-flight reply lets
      // room entry skip its immediate GET /window (one fewer capped hit
      // per entry, one fewer TLS handshake on join→face). The 2s room
      // poll stays the authoritative flip; clients tolerant-parse these
      // keys (absent = closed) so mixed-version fleets fall back safely.
      // `leaveToken` is the anti-ejection credential: the client stores it
      // and presents it on /leave (old clients ignore it — their leave
      // then 403s, and the floor forces them to update).
      return _json({
        'ok': true,
        'waiting': waitingCount,
        'windowOpen': windowOpen,
        'display': _window?.displayCode ?? '',
        'leaveToken': leaveToken,
      });
    } catch (e) {
      return _json({'error': 'bad-body: $e'}, 400);
    }
  }

  Future<Response> _postLeave(Request req) async {
    try {
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final email = (body['email'] as String? ?? '').toLowerCase();
      if (email.isEmpty) return _json({'error': 'bad-email'}, 400);
      // Anti-ejection: only the token issued at THIS email's join removes
      // it. Missing/mismatched tokens 403 REGARDLESS of whether the entry
      // exists (no existence oracle for LAN scanners — a tokenless probe
      // learns nothing about who is waiting). Honest clients always carry
      // the token from their /waiting reply, so honest leave is unchanged.
      final token = (body['leaveToken'] as String? ?? '').trim();
      if (token.isEmpty) return _json({'error': 'forbidden'}, 403);
      final removed = removeWaiting(email, leaveToken: token);
      if (!removed) return _json({'error': 'forbidden'}, 403);
      return _json({'ok': true, 'removed': true, 'waiting': waitingCount});
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
      requestManual(email, name, roll,
          (body['photo'] as String? ?? '').trim());
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
