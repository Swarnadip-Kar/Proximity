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
  final String org; // prof org domain, '' = legacy host
  /// Hosting professor's Gmail, lowercased, '' = unknown/legacy.
  /// Gated unicast ONLY (GET /window with a matching or legacy org —
  /// never UDP beacons, never BLE air packets, never Sig_p/Sig_s).
  final String profEmail;

  /// Hosting professor's Gmail profile photo URL (same gated channel as
  /// [profEmail]; '' = unknown). Rendered with initials fallback.
  final String profPhoto;

  /// Hosting professor's display name (same gated LAN channel as
  /// [profEmail]; '' = unknown). Never BLE — air packets stay IP:port
  /// hints only.
  final String profName;
  const WindowDescriptor({
    required this.classLabel,
    required this.sessionId,
    required this.windowId,
    required this.jNow,
    required this.profPk,
    required this.sigP,
    required this.tlsFp,
    required this.display,
    this.org = '',
    this.profEmail = '',
    this.profPhoto = '',
    this.profName = '',
  });
}

class ProveResult {
  final ProveDecision decision;
  final String reason;
  final DateTime serverTime;
  final Uint8List sigAck;
  /// Attestation anomaly flags from the host (empty on legacy path).
  /// Advisory: the signed ACK verdict is authoritative.
  final List<String> flags;
  const ProveResult({
    required this.decision,
    required this.reason,
    required this.serverTime,
    required this.sigAck,
    this.flags = const [],
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

  ProxClient({required this.host, required this.port}) {
    // Enterprise WiFi blackholes SYNs (no RST): an unbounded connect
    // hangs FOREVER mid-prove with zero log lines. Bound it — the driver
    // treats TimeoutException as transient and proves the next rotation.
    // (TLS handshake has no separate knob: every getUrl/postUrl below is
    // additionally wrapped in .timeout for the same reason.)
    _http.connectionTimeout = const Duration(seconds: 6);
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'https', host: host, port: port, path: path, queryParameters: query);

  void close() => _http.close(force: true);

  /// Lightweight LAN probe for the waiting room: reachable + windowOpen,
  /// without needing a radio challenge. Accepts the self-signed host cert.
  /// [org] is the student's org claim (gated discovery): matching or
  /// legacy org returns the descriptor WITH profEmail; mismatched org
  /// returns unreachable (gated silence — never the class, never email).
  Future<
      ({
        bool reachable,
        bool windowOpen,
        String classLabel,
        int waiting,
        String display,
        String org,
        String profEmail,
        String profPhoto,
        String profName
      })> probeWindow(
      {Duration timeout = const Duration(seconds: 4),
      void Function(Object e)? onError,
      String org = ''}) async {
    try {
      _http.badCertificateCallback = (cert, h, p) => true;
      final uri = org.trim().isEmpty
          ? _uri('/window')
          : _uri('/window', {'org': org.trim().toLowerCase()});
      final req = await _http.getUrl(uri).timeout(timeout);
      final resp = await req.close().timeout(timeout);
      final body =
          await resp.transform(utf8.decoder).join().timeout(timeout);
      if (resp.statusCode == 403) {
        // Gated silence: org-mismatch — never the class, never the email.
        onError?.call(StateError('org-mismatch (gated silence)'));
        return (
          reachable: false,
          windowOpen: false,
          classLabel: '',
          waiting: 0,
          display: '',
          org: '',
          profEmail: '',
          profPhoto: '',
          profName: ''
        );
      }
      if (resp.statusCode != 200) {
        onError?.call(StateError('HTTP ${resp.statusCode}'));
        return (
          reachable: false,
          windowOpen: false,
          classLabel: '',
          waiting: 0,
          display: '',
          org: '',
          profEmail: '',
          profPhoto: '',
          profName: ''
        );
      }
      final m = jsonDecode(body) as Map<String, dynamic>;
      return (
        reachable: true,
        windowOpen: (m['windowOpen'] as bool?) ?? false,
        classLabel: (m['class'] as String?) ?? '',
        waiting: (m['waiting'] as num?)?.toInt() ?? 0,
        display: (m['display'] as String?) ?? '',
        org: (m['org'] as String?) ?? '',
        profEmail: ((m['profEmail'] as String?) ?? '').trim().toLowerCase(),
        profPhoto: ((m['profPhoto'] as String?) ?? '').trim(),
        profName: ((m['profName'] as String?) ?? '').trim(),
      );
    } catch (e) {
      onError?.call(e);
      return (
        reachable: false,
        windowOpen: false,
        classLabel: '',
        waiting: 0,
        display: '',
        org: '',
        profEmail: '',
        profPhoto: '',
        profName: ''
      );
    }
  }

  Future<Map<String, dynamic>> _postJson(
      String path, Map<String, dynamic> body) async {
    _http.badCertificateCallback = (cert, h, p) => true;
    final req =
        await _http.postUrl(_uri(path)).timeout(const Duration(seconds: 8));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final resp = await req.close().timeout(const Duration(seconds: 6));
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode >= 400) {
      throw StateError('$path failed: ${resp.statusCode}');
    }
    try {
      final m = jsonDecode(text);
      if (m is Map<String, dynamic>) return m;
    } catch (_) {}
    return const {};
  }

  /// Presence heartbeat + piggybacked window sample (SYNC-owned): the
  /// professor's POST /waiting reply carries the live window flag +
  /// display code on the same round trip, so waiting-room entry fast-paths
  /// without a second (rate-capped) GET /window. Tolerant-parsed
  /// (absent keys = closed) so older hosts degrade to the probe path.
  Future<({int waiting, bool windowOpen, String display})> postWaiting(
          {required String email,
          required String name,
          String roll = '',
          String org = '',
          String photoUrl = ''}) async {
    final m = await _postJson('/waiting', {
      'email': email,
      'name': name,
      'roll': roll,
      'org': org,
      if (photoUrl.trim().isNotEmpty) 'photo': photoUrl.trim(),
    });
    return (
      waiting: (m['waiting'] as num?)?.toInt() ?? 0,
      windowOpen: (m['windowOpen'] as bool?) ?? false,
      display: (m['display'] as String?) ?? '',
    );
  }

  /// Explicit waiting-room leave (best-effort: never throws; the prof UI
  /// also converges because heartbeats stop with the room timers).
  Future<void> postLeave({required String email}) async {
    try {
      await _postJson('/leave', {'email': email});
    } catch (_) {}
  }

  Future<void> postManualRequest(
          {required String email,
          required String name,
          String roll = '',
          String org = '',
          String photoUrl = ''}) =>
      _postJson('/manual-request', {
        'email': email,
        'name': name,
        'roll': roll,
        'org': org,
        if (photoUrl.trim().isNotEmpty) 'photo': photoUrl.trim(),
      });

  Future<String> fetchManualStatus(String email) async {
    try {
      _http.badCertificateCallback = (cert, h, p) => true;
      final req = await _http
          .getUrl(_uri('/manual-status', {'email': email}))
          .timeout(const Duration(seconds: 4));
      final resp =
          await req.close().timeout(const Duration(seconds: 4));
      final body =
          await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 4));
      final m = jsonDecode(body) as Map<String, dynamic>;
      return (m['status'] as String?) ?? 'none';
    } catch (_) {
      return 'none';
    }
  }

  Future<(int, Map<String, dynamic>)> _get(String path,
      [Map<String, String>? query]) async {
    // TOFU: the self-signed host cert is accepted here AND on POST, but
    // content is signature-verified below (Sig_p over the radio challenge)
    // and channel-bound at POST (sigBind over the live cert fingerprint,
    // checked server-side). A MITM serves a cert whose fingerprint fails
    // both gates, so no pin state is kept across calls.
    _http.badCertificateCallback = (cert, h, p) => true;
    final req = await _http
        .getUrl(_uri(path, query))
        .timeout(const Duration(seconds: 8));
    final resp = await req.close().timeout(const Duration(seconds: 8));
    final body = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    return (resp.statusCode, jsonDecode(body) as Map<String, dynamic>);
  }

  /// Fetches + verifies the window descriptor (Sig_p over the live C_j…
  /// verified against the C_j the caller heard over BLE radio). The fetch
  /// can land just after the 5s rotation tick, when the live challenge is
  /// already C_{j} but the radio copy is C_{j-1}: the server ships the
  /// previous signature too, and either token verifies (both stay fresh
  /// for a full rotation + drift). Only a token matching NEITHER is a
  /// genuine mismatch — stale air, or a fake professor.
  ///
  /// [org] is the student's org claim (gated discovery): a mismatched org
  /// throws `org-mismatch:<classOrg>` (never the email, never window
  /// material) so the caller returns a structured wrong-org receipt
  /// without sending any proof. Matching or legacy org returns the
  /// descriptor WITH profEmail (gated unicast only).
  Future<WindowDescriptor> fetchWindow(Uint8List radioChallenge,
      {String org = ''}) async {
    final query =
        org.trim().isEmpty ? null : {'org': org.trim().toLowerCase()};
    final (status, body) = await _get('/window', query);
    if (status == 429) throw StateError('window rate-limited, retry later');
    if (status == 403 && body['reason'] == 'org-mismatch') {
      throw StateError('org-mismatch:${body['org'] ?? ''}');
    }
    if (status != 200) {
      throw StateError(
          'window fetch HTTP $status (${body['error'] ?? body['windowOpen'] ?? 'no body'})');
    }
    // Closed/idle window: no challenge material at all (the heard C_j is
    // stale — e.g. relay lag, or a window that just closed).
    // Throw a clean error instead of crashing on the missing keys below.
    if (body['windowOpen'] == false) {
      throw StateError('window closed on professor — try the next round');
    }
    for (final k in const [
      'sessionID',
      'windowID',
      'j_now',
      'pkP',
      'sigP',
      'tlsFp',
      'class',
      'display'
    ]) {
      if (body[k] == null) throw StateError('window descriptor missing $k');
    }
    final sessionId = Uint8List.fromList(hexDecode(body['sessionID'] as String));
    final windowId = Uint8List.fromList(hexDecode(body['windowID'] as String));
    final jNow = body['j_now'] as int;
    final profPk = ed.PublicKey(hexDecode(body['pkP'] as String));
    final sigP = Uint8List.fromList(hexDecode(body['sigP'] as String));
    // The descriptor never carries C_j (radio-only). The caller proves it
    // heard the live challenge by verifying Sig_p against its radio copy.
    // `org` + `profEmail` + `profName` ride alongside (join-gate display
    // only — never in Sig_p/Sig_s; gated LAN unicast only, never BLE).
    WindowDescriptor descFor(int jj, Uint8List sig) => WindowDescriptor(
          classLabel: body['class'] as String,
          sessionId: sessionId,
          windowId: windowId,
          jNow: jj,
          profPk: profPk,
          sigP: sig,
          tlsFp: Uint8List.fromList(hexDecode(body['tlsFp'] as String)),
          display: body['display'] as String,
          org: body['org'] as String? ?? '',
          profEmail:
              ((body['profEmail'] as String?) ?? '').trim().toLowerCase(),
          profPhoto: ((body['profPhoto'] as String?) ?? '').trim(),
          profName: ((body['profName'] as String?) ?? '').trim(),
        );
    bool verifies(int jj, Uint8List sig) => ProxCrypto.verifyProfChallenge(
          profPk: profPk,
          sessionId: sessionId,
          windowId: windowId,
          j: jj,
          challenge: radioChallenge,
          sig: sig,
        );
    if (verifies(jNow, sigP)) return descFor(jNow, sigP);
    // Rotation-boundary fallback: the radio token is one tick behind.
    final jPrev = body['j_prev'] as int?;
    final sigPrevHex = body['sigP_prev'] as String?;
    if (jPrev != null && sigPrevHex != null && jPrev >= 0) {
      final sigPrev = Uint8List.fromList(hexDecode(sigPrevHex));
      if (verifies(jPrev, sigPrev)) return descFor(jPrev, sigPrev);
    }
    throw StateError('prof signature mismatch (stale token or fake professor?)');
  }

  /// POSTs a signed proof with herd-spread jitter, up to 3 attempts.
  /// [sign] builds (sigS, sigBind) for the attempt's sub-epoch. Only
  /// TRANSPORT failures retry here — a decided verdict (confirmed / late /
  /// invalid …) returns immediately, never re-POSTed: the rotation is 5s
  /// and a same-j retry would only age the token (and burn single-use on
  /// a retake). Each attempt carries its own budget so a hung POST can
  /// never outlive the driver's dead-air cap.
  ///
  /// Tracks 2+3 (all optional, legacy-compatible): [faceValidAtMs] +
  /// [verifierVer] emit the `face:{score,faceValidAt,verifierVer}` ticket
  /// (Sig_s binds them — no images/embeddings leave the device); [pkD] +
  /// [dSigFor] emit the device binding (`pkD` hex + `dSig` over
  /// deviceProvePreimage with the ticket hash). [dSigFor] receives the
  /// ticket, the sub-epoch, and the §5 [integrityHash] — the closure MUST
  /// sign the canonical preimage WITH that hash (server recomputes the
  /// identical bytes; mismatch fails closed). [faceVecB64] attaches the
  /// LAN-only session vector (`face:{vec}` — RAM-only on the professor
  /// phone, never the cloud); empty means no dup participation.
  /// Security §2: [attestationChain] (DER-hex, leaf-first, from the stored
  /// enrollment) + [installId] (challenge binding) ride on HW-bound proofs;
  /// the professor pins + recomputes offline.
  /// Security §5: [integrityHash] (8-hex verdict hash) is bound into the
  /// SIGNED dSig preimage (via [dSigFor]'s ticket) and carried in the body
  /// so the professor recomputes the identical preimage — pre-binding
  /// clients omit it and fail closed on HW tiers (never a silent
  /// downgrade). [integrityFlag] stays advisory alongside.
  Future<ProveResult> prove({
    required WindowDescriptor desc,
    required String studentId,
    required Uint8List challenge,
    required int j,
    required double faceScore,
    required Uint8List peerW,
    String name = '',
    String roll = '',
    required Uint8List pkS,
    required Uint8List Function(Uint8List challenge, int j) sigSFor,
    required Uint8List Function(Uint8List tlsFp, int j) sigBindFor,
    String org = '',
    Random? rng,
    int maxAttempts = 3,
    int? faceValidAtMs,
    String verifierVer = '',
    Uint8List? pkD,
    Future<Uint8List> Function(
            Uint8List faceTicketHashBytes, int j, String integrityHash)?
        dSigFor,
    String attestationLevel = 'NONE',
    int attestedUntilMs = 0,
    String faceVecB64 = '',
    double livenessScore = 0.0,
    String livenessVer = '',
    String integrityFlag = '',
    String integrityHash = '',
    List<String> attestationChain = const [],
    String installId = '',
    String appAttestRaw = '',
    String appAttestCredKey = '',
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
          pkS: pkS,
          sigSFor: sigSFor,
          sigBindFor: sigBindFor,
          org: org,
          faceValidAtMs: faceValidAtMs,
          verifierVer: verifierVer,
          pkD: pkD,
          dSigFor: dSigFor,
          attestationLevel: attestationLevel,
          attestedUntilMs: attestedUntilMs,
          faceVecB64: faceVecB64,
          livenessScore: livenessScore,
          livenessVer: livenessVer,
          integrityFlag: integrityFlag,
          integrityHash: integrityHash,
          attestationChain: attestationChain,
          installId: installId,
          appAttestRaw: appAttestRaw,
          appAttestCredKey: appAttestCredKey,
        ).timeout(const Duration(seconds: 14));
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
    required Uint8List pkS,
    required Uint8List Function(Uint8List challenge, int j) sigSFor,
    required Uint8List Function(Uint8List tlsFp, int j) sigBindFor,
    String org = '',
    int? faceValidAtMs,
    String verifierVer = '',
    Uint8List? pkD,
    Future<Uint8List> Function(
            Uint8List faceTicketHashBytes, int j, String integrityHash)?
        dSigFor,
    String attestationLevel = 'NONE',
    int attestedUntilMs = 0,
    String faceVecB64 = '',
    double livenessScore = 0.0,
    String livenessVer = '',
    String integrityFlag = '',
    String integrityHash = '',
    List<String> attestationChain = const [],
    String installId = '',
    String appAttestRaw = '',
    String appAttestCredKey = '',
  }) async {
    // Channel binding signs the fingerprint from the verified descriptor
    // fetch (Sig_p already proved the server owns windowId): the POST
    // pin-check below + the server's tlsFp comparison both gate on it.
    final tlsFp = desc.tlsFp;
    // Bound ticket (Tracks 2+3 + security §4 liveness): stamp + tag +
    // device binding + liveness. Legacy callers leave verifierVer/
    // livenessVer empty → legacy body, legacy server path.
    final bound = verifierVer.isNotEmpty ||
        livenessVer.isNotEmpty ||
        livenessScore != 0.0;
    final stampMs = faceValidAtMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final ticket = bound
        ? ProxCrypto.faceTicketHash(
            faceScore: faceScore,
            faceValidAtMs: stampMs,
            verifierVer: verifierVer,
            livenessScore: livenessScore,
            livenessVer: livenessVer)
        : null;
    // Security §5: the closure signs with the SAME hash the body carries
    // (server recomputes the identical bound preimage — claim/sign
    // mismatch fails dSig verify, never a silent downgrade).
    final dSig = (bound && dSigFor != null && ticket != null)
        ? await dSigFor(ticket, j, integrityHash)
        : null;
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
      pkS: pkS,
      org: org,
      faceValidAtMs: bound ? stampMs : null,
      verifierVer: verifierVer,
      pkD: pkD,
      dSig: dSig,
      attestationLevel: attestationLevel,
      attestedUntilMs: attestedUntilMs,
      faceVecB64: faceVecB64,
      livenessScore: livenessScore,
      livenessVer: livenessVer,
      integrityFlag: integrityFlag,
      integrityHash: integrityHash,
      attestationChain: attestationChain,
      installId: installId,
      appAttestRaw: appAttestRaw,
      appAttestCredKey: appAttestCredKey,
    ));
    _http.badCertificateCallback = (cert, h, p) {
      final fp =
          Uint8List.fromList(ProxCrypto.sha256Sync(cert.der));
      // Pin to the fingerprint from the verified descriptor fetch.
      return bytesEqual(fp, desc.tlsFp);
    };
    final req = await _http
        .postUrl(_uri('/prove'))
        .timeout(const Duration(seconds: 8));
    req.headers.contentType = ContentType.json;
    req.write(body);
    // Generous single-shot timeout (loose classroom WiFi): the driver
    // loop retries across tokens anyway — one slow POST must not kill it.
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final text =
        await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
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
      flags: [
        for (final f in (m['flags'] as List? ?? const [])) '$f',
      ],
    );
  }
}
