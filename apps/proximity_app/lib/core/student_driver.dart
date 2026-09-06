// Student prove driver: face check against the enrolled template, then a
// 30s radio wait for the professor's rotating challenge, then HTTPS prove
// with channel binding. Full gate, no fake success:
//
//   no fresh face  → faceFailed (SK never signs)
//   no radio heard → noSignal (screenshot codes can't mark)
//   ACK invalid    → error
//
// [FakeStudentDriver] replays the happy path for widget tests / UI polish.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_face/face.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';

import '../mode.dart';
import 'device_store.dart';
import 'edgeface.dart';

enum StudentResult { marked, late, faceFailed, noSignal, error }

/// Holder-check verdict. Only [mismatch] consumes one of the 4 attempts: a
/// readable session matched somebody else. [inconclusive] (no enrollment, no
/// face, unreadable bytes) never consumes an attempt — the verify session
/// keeps scanning for a readable frame across its 10s window. [staleTemplate] means the
/// enrolled template predates the current face pipeline ([kFacePipelineVer])
/// and is incomparable — the holder must re-enroll, never match against it.
enum FaceMatch { pass, mismatch, inconclusive, staleTemplate }

class FaceCheckResult {
  final FaceMatch match;
  final double score; // cosine for pass/mismatch, 0 for inconclusive
  const FaceCheckResult(this.match, [this.score = 0]);
}

class MarkedReceipt {
  final String detail; // display code · server time
  final StudentResult result;
  /// Window display code at mark time (round identity for rewait: the
  /// next window carries a fresh code, so the student never re-faces the
  /// same open window).
  final String display;
  const MarkedReceipt(
      {required this.detail, required this.result, this.display = ''});
}

class WindowProbe {
  final bool reachable;
  final bool windowOpen;
  final String classLabel;
  final int waiting;
  final String display; // window code when open (round identity)
  const WindowProbe(
      {required this.reachable,
      required this.windowOpen,
      required this.classLabel,
      this.waiting = 0,
      this.display = ''});
}

abstract class StudentDriver {
  /// Face gate against the enrolled template. [FaceMatch.pass] carries the
  /// match score; [FaceMatch.mismatch] means a readable frame matched
  /// somebody else (consumes one attempt); [FaceMatch.inconclusive] means
  /// no readable verdict (keep scanning, never consumes an attempt).
  Future<FaceCheckResult> checkFace(Uint8List frameBytes);

  /// Listens until marked. There is no round clock: the window stays open
  /// until the professor stops it, so every fresh challenge is signed,
  /// announced and POSTed until a verdict lands. [onStatus] reports the
  /// current step (waiting/proving/confirming) for the UI — the student
  /// never sees a countdown. Never marks without radio + signed ACK.
  Future<MarkedReceipt> listenAndProve({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(ListenStatus s) onStatus,
  });

  /// Waiting-room LAN probe: reachable + windowOpen without radio.
  Future<WindowProbe> probeWindow(ClassBeacon target);

  /// Registers presence in the professor's waiting room (heartbeat).
  Future<void> sendPresence(
      {required ClassBeacon target, required LinkedIdentity identity});

  /// Explicit waiting-room leave so the prof's count drops immediately.
  /// Best-effort (never throws).
  Future<void> leaveWaiting(
      {required ClassBeacon target, required String email});

  /// Requests manual attendance over LAN; prof approves selectively.
  Future<void> requestManual(
      {required ClassBeacon target, required LinkedIdentity identity});

  /// Polls manual decision: pending|approved|rejected|none.
  Future<String> pollManualStatus(
      {required ClassBeacon target, required String email});

  /// Starts BLE scanning early so face capture and mesh listen overlap.
  Future<void> prewarmRadio();
}

/// Listen step reported to the UI (no countdowns — the student never
/// sees round timing, only what is happening right now).
enum ListenStatus { waiting, proving, confirming }

/// Internal signal: this attempt produced no verdict — prove the next
/// fresh challenge instead of failing. [suspicious] marks attempts that
/// never verified against the professor (stale token or fake): several in
/// a row means no valid class signal, not a flaky network.
class _TryNext implements Exception {
  final String why;
  final bool suspicious;
  const _TryNext(this.why, {this.suspicious = false});
  @override
  String toString() => why;
}

class RealStudentDriver implements StudentDriver {  final DeviceStore _store;
  final FaceEmbedder _embedder;
  final ProxBleEngine _engine;
  RealStudentDriver({
    required DeviceStore store,
    required FaceEmbedder embedder,
    required ProxBleEngine engine,
  })  : _store = store,
        _embedder = embedder,
        _engine = engine;

  /// Dead-air bound per wait: 45s of no new challenge, then one cheap
  /// window probe decides "round ended" vs "still open". Tests shrink it.
  Duration silenceCap = const Duration(seconds: 45);

  /// SK-use gate: stamped by [checkFace] on pass, enforced by [_prove].
  /// Guards the idle-5-minutes-on-waiting-screen edge — signing without a
  /// fresh holder check is refused before anything touches the network.
  final FaceGate _faceGate = FaceGate();

  /// Quiet slice inside [silenceCap]: a platform scan can die silently
  /// while reporting active (observed live: zero sightings for minutes
  /// with an open window on air, revived only by a fresh start). Every
  /// quiet slice re-arms the scan, then waiting continues to the cap.
  /// Tests shrink it.
  Duration scanRestartSlice = const Duration(seconds: 15);

  /// Re-entry guard: rapid rejoins must not run two listen loops on the
  /// shared engine + linger timer (UI also carries a runId; the driver
  /// enforces it so programmatic callers are safe too).
  bool _listening = false;

  @override
  Future<FaceCheckResult> checkFace(Uint8List frameBytes) async {
    final stored = await _store.readEnrollment();
    if (stored == null) {
      BleLog.log('SEC', 'face check: no enrollment');
      return const FaceCheckResult(FaceMatch.inconclusive);
    }
    if (stored.modelVer != kFacePipelineVer) {
      BleLog.log('SEC',
          'face check: stale template ${stored.modelVer} vs $kFacePipelineVer — re-enroll, never match');
      return const FaceCheckResult(FaceMatch.staleTemplate);
    }
    final session = FaceSession(embedder: _embedder);
    try {
      // Enroll inside try: a corrupt stored template (bad parse) must fail
      // closed as inconclusive, never throw out of the verifier.
      session.enroll(stored.template);
      final res = await session.verify(frameBytes,
          challenge: Uint8List.fromList(const [0, 0, 0, 0, 0, 0, 0, 0]),
          now: DateTime.now().toUtc());
      final pass = res.decision == FaceDecision.pass;
      BleLog.log('SEC',
          pass ? 'face check pass score=${res.score.toStringAsFixed(2)}' : 'face check FAIL');
      if (pass) {
        // Stamp the SK-use gate: the private key signs ONLY within a
        // fresh face window (kFaceValidWindow). _prove enforces it —
        // idling past expiry on the waiting screen can never sign.
        _faceGate.evaluate(
            score: res.score,
            livenessPass: true,
            now: DateTime.now().toUtc());
        return FaceCheckResult(FaceMatch.pass, res.score);
      }
      return FaceCheckResult(FaceMatch.mismatch, res.score);
    } catch (e) {
      BleLog.log('SEC', 'face check ERROR: $e');
      return const FaceCheckResult(FaceMatch.inconclusive);
    }
  }

  @override
  Future<WindowProbe> probeWindow(ClassBeacon target) async {
    final client = ProxClient(host: target.host, port: target.port);
    try {
      final r = await client.probeWindow();
      if (!r.reachable) {
        BleLog.log('LAN', 'probe ${target.host}:${target.port} unreachable');
      }
      return WindowProbe(
          reachable: r.reachable,
          windowOpen: r.windowOpen,
          classLabel: r.classLabel,
          waiting: r.waiting,
          display: r.display);
    } finally {
      client.close();
    }
  }

  @override
  Future<void> sendPresence(
      {required ClassBeacon target,
      required LinkedIdentity identity}) async {
    final client = ProxClient(host: target.host, port: target.port);
    try {
      await client.postWaiting(
          email: identity.gmail, name: identity.name, roll: identity.roll);
      BleLog.log('LAN', 'presence sent → waiting room (${target.host})');
    } catch (e) {
      BleLog.log('LAN', 'presence FAILED (${target.host}): $e');
      // Presence is best-effort; window-open polling still drives the flow.
    } finally {
      client.close();
    }
  }

  @override
  Future<void> requestManual(
      {required ClassBeacon target,
      required LinkedIdentity identity}) async {
    BleLog.log('LAN', 'manual request sending → ${target.host}');
    final client = ProxClient(host: target.host, port: target.port);
    try {
      await client.postManualRequest(
          email: identity.gmail, name: identity.name, roll: identity.roll);
      BleLog.log('LAN', 'manual request sent, waiting for prof decision');
    } finally {
      client.close();
    }
  }

  @override
  Future<void> leaveWaiting(
      {required ClassBeacon target, required String email}) async {
    BleLog.log('LAN', 'leaving waiting room (${target.host})');
    final client = ProxClient(host: target.host, port: target.port);
    try {
      await client.postLeave(email: email);
      BleLog.log('LAN', 'leave sent — prof count drops');
    } finally {
      client.close();
    }
  }

  @override
  Future<String> pollManualStatus(
      {required ClassBeacon target, required String email}) async {
    final client = ProxClient(host: target.host, port: target.port);
    try {
      return await client.fetchManualStatus(email);
    } finally {
      client.close();
    }
  }

  @override
  Future<void> prewarmRadio() async {
    BleLog.log('BLE', 'prewarm radio (scan early, overlap camera)');
    try {
      await _engine.startScanning(deferIfNotReady: true);
    } catch (e) {
      BleLog.log('BLE', 'prewarm scan FAILED: $e');
    }
    // Front-row relay must be armed from the moment we start listening —
    // the window can open while the camera UI is up (face capture), and
    // back rows starve if we wait until listenAndProve to enable it.
    // Professors never call prewarm (they originate), so this is student-only.
    _engine.relayEnabled = true;
    BleLog.log('MESH', 'mesh on (front-row relay armed, prewarm)');
  }

  @override
  Future<MarkedReceipt> listenAndProve({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(ListenStatus s) onStatus,
  }) async {
    if (_listening) {
      return const MarkedReceipt(
          detail: 'Already proving — wait for the current round',
          result: StudentResult.error);
    }
    _listening = true;
    try {
      return await _listenAndProveInner(
          target: target,
          identity: identity,
          faceScore: faceScore,
          onStatus: onStatus);
    } finally {
      _listening = false;
    }
  }

  Future<MarkedReceipt> _listenAndProveInner({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(ListenStatus s) onStatus,
  }) async {
    final stored = await _store.readEnrollment();
    if (stored == null ||
        stored.email.toLowerCase() != identity.gmail.toLowerCase()) {
      return const MarkedReceipt(
          detail: 'Not enrolled on this device', result: StudentResult.error);
    }
    // The face score is the holder evidence for THIS listen (the face
    // screen verified liveness just before calling): stamp the SK-use
    // gate now, so _prove can time-bound marathon listens — a face pass
    // older than kFaceValidWindow refuses to sign and the student
    // re-scans instead of marking on a stale check.
    if (faceScore >= kFaceThreshold) {
      _faceGate.evaluate(
          score: faceScore, livenessPass: true, now: DateTime.now().toUtc());
    }
    // No round clock: the window stays open until the professor stops it,
    // so a slow prover (face retries, weak corner signal) simply proves a
    // later rotation instead of racing a countdown. Loop until a verdict.
    _engine.clearSightings();
    BleLog.log('BLE', 'stale sightings cleared (listen start)');
    _engine.relayEnabled = true;
    BleLog.log('MESH', 'mesh on (front-row relay armed)');
    BleLog.log('BLE', 'listening until marked (no round clock)…');
    Uint8List? lastTried;
    DateTime? firstHeardAt;
    // Consecutive attempts that never verified against the professor
    // (stale tokens or a fake): a live round verifies within a couple of
    // rotations, so a streak means no valid signal, not a blip.
    var spookStreak = 0;
    while (true) {
      onStatus(ListenStatus.waiting);
      final cj = await _waitNewChallenge(lastTried);
      if (cj == null) {
        // Dead air: is the round still open or did it end? One cheap
        // unicast probe decides — no guessing, no countdown.
        WindowProbe probe;
        try {
          probe = await probeWindow(target);
        } catch (_) {
          BleLog.log('LAN', 'silence probe flaked — kept waiting…');
          continue;
        }
        if (probe.windowOpen) {
          BleLog.log('LAN', 'round still open — kept waiting…');
          continue;
        }
        _engine.relayEnabled = false;
        BleLog.log('MESH', 'mesh off (round ended)');
        BleLog.log('BLE', 'dead air + window closed → noSignal');
        return const MarkedReceipt(
            detail: 'Round ended — stay put for the next one',
            result: StudentResult.noSignal);
      }
      lastTried = cj;
      firstHeardAt ??= DateTime.now().toUtc();
      // Token heard: keep meshing so back rows still receive it. The
      // instant prove below is unaffected (fire-and-forget arming).
      _lingerRelay20sAfter(firstHeardAt);
      onStatus(ListenStatus.proving);
      try {
        return await _prove(
          target: target,
          identity: identity,
          faceScore: faceScore,
          challenge: cj,
          seedHex: stored.seedHex,
          onStatus: onStatus,
        );
      } on _TryNext catch (t) {
        if (t.suspicious) {
          spookStreak++;
          if (spookStreak >= 6) {
            BleLog.log('NET', 'no verifiable signal ×$spookStreak: ${t.why}');
            return MarkedReceipt(
                detail: 'No valid class signal — ${t.why}',
                result: StudentResult.error);
          }
        } else {
          spookStreak = 0; // real server contact: not a fake, just unlucky
        }
        BleLog.log('NET', '${t.why} — next signal…');
      } catch (e) {
        // Loose WiFi (dropped POST, timeout, reset): the server answered
        // before, so hold on and prove the next token. Refused means
        // wrong IP / dead server and fails fast; anything else is a real
        // failure, not a blip.
        if (_isRefused(e)) {
          BleLog.log('NET', 'prove FAILED (refused): $e');
          return MarkedReceipt(
              detail:
                  'Professor unreachable at ${target.host}:${target.port} — check the IP',
              result: StudentResult.error);
        }
        if (!_isTransientNetError(e)) {
          BleLog.log('NET', 'prove FAILED: $e');
          return MarkedReceipt(
              detail: 'Prove failed: $e', result: StudentResult.error);
        }
        spookStreak = 0;
        BleLog.log('NET', 'transient net ($e) — next signal…');
      }
    }
  }

  /// Refused is NOT transient: nothing listens there (wrong IP or dead
  /// server) — fails fast instead of waiting out rotations.
  static bool _isRefused(Object e) => '$e'.contains('Connection refused');

  /// Dropped POSTs, timeouts, resets on loose WiFi: the network flaked,
  /// not the verdict. Refused is NOT transient (nothing listens there —
  /// wrong IP or dead server) and fails fast. Message-based on purpose:
  /// transport wraps retries in StateError text, and this stays
  /// dart:io-free so the shared driver compiles for the web records build.
  static bool _isTransientNetError(Object e) {
    if ('$e'.contains('Connection refused')) return false;
    if (e is TimeoutException) return true;
    final m = '$e';
    return m.contains('SocketException') ||
        m.contains('TimeoutException') ||
        m.contains('HttpException') ||
        m.contains('HandshakeException') ||
        m.contains('Connection reset') ||
        m.contains('Network is unreachable') ||
        m.contains('No route to host');
  }

  /// Waits for a live challenge different from [lastTried], clearing the
  /// cache first so an already-seen relay echo can never resolve
  /// immediately. Null after [silenceCap] of dead air (caller probes the
  /// window to tell "round ended" apart from "still open, keep waiting").
  Future<Uint8List?> _waitNewChallenge(Uint8List? lastTried) async {
    final until = DateTime.now().toUtc().add(silenceCap);
    while (true) {
      final remaining = until.difference(DateTime.now().toUtc());
      if (remaining <= Duration.zero) return null;
      _engine.clearSightings();
      Uint8List? t;
      try {
        final slice =
            remaining < scanRestartSlice ? remaining : scanRestartSlice;
        t = await _engine.nextChallenge(timeout: slice);
      } catch (e) {
        // Engine/BT failure is not dead air: log it so the terminal shows
        // the cause instead of silently ending as no-signal.
        BleLog.log('BLE', 'challenge wait ERROR: $e');
        return null;
      }
      if (t == null) {
        // Quiet slice with an awaited signal: the platform scan may have
        // died underneath (reports active, delivers nothing) — re-arm it
        // and keep waiting to the cap.
        BleLog.log('BLE', 'quiet while listening — re-arming scan…');
        await _engine.restartScan();
        continue;
      }
      if (t.length != kChallengeBytes) return null;
      if (lastTried == null || hexEncode(t) != hexEncode(lastTried)) {
        BleLog.log('BLE', 'new challenge tok=${hexEncode(t).substring(0, 8)}…');
        return t;
      }
      // Same-token echo (own relay, professor repeat): keep waiting for
      // the rotation — the cap above still bounds the wait.
    }
  }

  /// Keeps challenge relay alive until 20s after the token was first
  /// received, then switches the mesh off. Single reschedulable timer:
  /// a newer challenge extends the linger instead of an older timer
  /// cutting the mesh early for back rows.
  Timer? _lingerTimer;
  void _lingerRelay20sAfter(DateTime firstHeardAt) {
    const linger = Duration(seconds: 20);
    final elapsed = DateTime.now().toUtc().difference(firstHeardAt);
    if (elapsed >= linger) {
      _lingerTimer?.cancel();
      _lingerTimer = null;
      _engine.relayEnabled = false;
      BleLog.log('MESH', 'mesh off (20s linger elapsed)');
      return;
    }
    _lingerTimer?.cancel();
    _lingerTimer = Timer(linger - elapsed, () {
      _lingerTimer = null;
      try {
        _engine.relayEnabled = false;
        BleLog.log('MESH', 'mesh off (20s linger done)');
      } catch (_) {}
    });
  }

  /// One prove attempt for one heard challenge. Returns a terminal
  /// receipt (marked/late/error), or throws [_TryNext] to prove the next
  /// fresh challenge. POST transport failures propagate to the caller
  /// (transient → next token, refused → fast fail).
  Future<MarkedReceipt> _prove({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required Uint8List challenge,
    required String seedHex,
    required void Function(ListenStatus s) onStatus,
  }) async {
    final client = ProxClient(host: target.host, port: target.port);
    try {
      // Key decode inside try: a corrupt seed fails as a terminal error
      // receipt, never an uncaught throw mislabeled by outer handlers.
      final sk = ed.newKeyFromSeed(hexDecode(seedHex));
      final pk = ed.public(sk);
      final pk32 = Uint8List.fromList(pk.bytes.sublist(0, 32));
      // Verifies Sig_p against the RADIO-heard challenge: fake professors
      // fail here before anything is signed. Only a genuine signature
      // mismatch is suspicious (never verified); every other fetch failure
      // — closed window, rate limit, missing descriptor — is PROOF the
      // server is real, so it resets the streak instead of feeding it.
      BleLog.log('NET', 'fetching window (verify prof sig)…');
      late final WindowDescriptor desc;
      try {
        desc = await client.fetchWindow(challenge);
      } on StateError catch (e) {
        final msg = '$e';
        // Only an unverifiable signature means "never verified".
        final suspicious = msg.contains('prof signature mismatch');
        throw _TryNext('window fetch ($e)', suspicious: suspicious);
      }
      BleLog.log('NET', 'window ok code=${desc.display} j=${desc.jNow}');
      final j = desc.jNow;
      // Holder gate: the face pass that authorized THIS listen must still
      // be fresh — otherwise the key stays locked and the student re-scans
      // (terminal, never a silent retry loop: re-proving cannot fix it).
      try {
        _faceGate.requireFreshForSign();
      } on StateError catch (e) {
        BleLog.log('SEC', 'sign refused: $e');
        return const MarkedReceipt(
            detail: 'Face check expired — scan again',
            result: StudentResult.faceFailed);
      }
      final peerW = ProxCrypto.peerAlias(pk32, desc.windowId);
      // Answer over radio first so the professor's sighting exists, then
      // POST over WiFi. Best-effort: the server is the judge. The scan
      // itself is held continuously from browse/prewarm (re-armed by the
      // watchdog on quiet spells) — restarting it here every attempt
      // thrashed the platform stack, so this only announces.
      try {
        await _engine.advertiseStudentResponse(
            identity.gmail.toLowerCase(), challenge, j, peerW);
        BleLog.log('BLE', 'response on air (UUID_S j=$j)');
      } catch (e) {
        BleLog.log('BLE', 'response ADV FAILED: $e');
      }
      BleLog.log('SEC', 'signing token (Ed25519 + channel binding)…');
      final res = await client.prove(
        desc: desc,
        studentId: identity.gmail.toLowerCase(),
        challenge: challenge,
        j: j,
        faceScore: faceScore,
        peerW: peerW,
        name: identity.name,
        roll: identity.roll,
        pkS: pk32,
        sigSFor: (c, jj) => ProxCrypto.signStudentProve(
          studentSk: sk,
          sessionId: desc.sessionId,
          windowId: desc.windowId,
          j: jj,
          challenge: c,
          studentId: identity.gmail.toLowerCase(),
          faceScore: faceScore,
        ),
        sigBindFor: (fp, jj) => ProxCrypto.sign(
            sk,
            bindPreimage(
                sessionId: desc.sessionId,
                windowId: desc.windowId,
                j: jj,
                tlsFingerprint: fp)),
      );
      // Verdicts that only a fresh token fixes (round changed under us,
      // token aged out, professor never heard the response): prove the
      // next rotation — the server was real and answering.
      if (res.decision == ProveDecision.invalid &&
          (res.reason == 'window-mismatch' ||
              res.reason == 'bad-challenge' ||
              res.reason == 'no-ble-sighting')) {
        throw _TryNext('prove ${res.reason}');
      }
      if (res.decision == ProveDecision.late &&
          res.reason == 'stale-sub-epoch') {
        throw _TryNext('prove stale-sub-epoch (token aged out)');
      }
      final ok = res.verifyAck(
        profPk: desc.profPk,
        sessionId: desc.sessionId,
        windowId: desc.windowId,
        j: j,
        studentId: identity.gmail.toLowerCase(),
      );
      if (!ok) {
        BleLog.log('NET', 'ACK received but BAD prof signature');
        return const MarkedReceipt(
            detail: 'Bad professor signature',
            result: StudentResult.error);
      }
      BleLog.log(
          'NET', 'waiting for ACK… got ${res.decision.name} (${res.reason})');
      final time = res.serverTime;
      final stamp =
          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
      return switch (res.decision) {
        ProveDecision.confirmed => MarkedReceipt(
            detail: '${desc.display} · $stamp',
            result: StudentResult.marked,
            display: desc.display),
        ProveDecision.late => MarkedReceipt(
            detail: 'Late · $stamp',
            result: StudentResult.late,
            display: desc.display),
        ProveDecision.invalid => MarkedReceipt(
            // Terminal rejection (bad-sig, bad-bind, replay…): the raw
            // reason matches the professor-side `prove <email> -> invalid
            // (<reason>)` log line for support.
            detail: 'Not marked [${res.reason}]',
            result: StudentResult.error),
      };
    } finally {
      client.close();
    }
  }
}

class FakeStudentDriver implements StudentDriver {
  final String ackDetail;
  bool windowOpenProbe;
  String manualStatus;
  FakeStudentDriver(
      {this.ackDetail = 'KQ7 · 10:04:12',
      this.windowOpenProbe = false,
      this.manualStatus = 'pending'});

  @override
  Future<FaceCheckResult> checkFace(Uint8List frameBytes) async =>
      const FaceCheckResult(FaceMatch.pass, 0.95);

  @override
  Future<WindowProbe> probeWindow(ClassBeacon target) async => WindowProbe(
      reachable: true,
      windowOpen: windowOpenProbe,
      classLabel: target.classLabel);

  @override
  Future<void> sendPresence(
          {required ClassBeacon target,
          required LinkedIdentity identity}) async {}

  @override
  Future<void> leaveWaiting(
          {required ClassBeacon target, required String email}) async {}

  @override
  Future<void> requestManual(
          {required ClassBeacon target,
          required LinkedIdentity identity}) async {}

  @override
  Future<String> pollManualStatus(
          {required ClassBeacon target, required String email}) async =>
      manualStatus;

  @override
  Future<void> prewarmRadio() async {}

  @override
  Future<MarkedReceipt> listenAndProve({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(ListenStatus s) onStatus,
  }) async {
    onStatus(ListenStatus.confirming);
    return MarkedReceipt(detail: ackDetail, result: StudentResult.marked);
  }
}

final studentDriverProvider = Provider<StudentDriver>((ref) {
  throw UnimplementedError('Override in main / tests');
});
