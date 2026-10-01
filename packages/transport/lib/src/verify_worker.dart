// Warm crypto worker for the professor's verify burst (transport-local).
//
// A 500-seat window lands hundreds of POST /prove in seconds; each runs
// Ed25519 Sig_s + P-256 dSig BigInt math that wedges a low-end professor
// phone's UI isolate for seconds. This worker is ONE persistent isolate
// (spawned lazily on the first prove, reused for the session) that runs
// the pure-crypto half of /prove — dSig gate + verifyProve — off the
// main thread. Single-use claiming, tally, chain pin, TLS binding and all
// orchestration stay on the caller; only number-crunching moves.
//
// Messages are isolate-safe primitives only (maps/lists/typed-data).
// Any worker failure throws to the caller, which falls back to the
// synchronous path — same verdicts, never a dropped prove.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:proximity_protocol/protocol.dart';

/// Isolate entry: [mainSend] receives our SendPort first, then
/// `[id, resultMap]` replies. Never throws out (errors reply as strings).
void _verifyWorkerEntry(SendPort mainSend) {
  final inbox = ReceivePort();
  mainSend.send(inbox.sendPort);
  inbox.listen((msg) {
    if (msg is! List || msg.length != 3 || msg[0] is! int) return;
    final id = msg[0] as int;
    try {
      mainSend.send([id, _proveCrypto(Map<String, Object?>.from(msg[2] as Map))]);
    } catch (e) {
      mainSend.send([id, 'worker-error: $e']);
    }
  });
}

/// Pure-crypto half of POST /prove, mirroring ProxServer._postProve's
/// dSig gate + runVerify exactly (same functions, same order):
/// P-256 dSig over the recomputed preimage, then verifyProve. Returns
/// `{decision, reason, dSigValid, flags}` with decision as a
/// ProveDecision index.
Map<String, Object?> _proveCrypto(Map<String, Object?> a) {
  List<int> bytes(Object? v) => List<int>.from(v as List);
  Uint8List u8(Object? v) => Uint8List.fromList(bytes(v));

  final bound = a['bound'] as bool;
  final ticket = u8(a['ticket']);
  final pkD = u8(a['pkD']);
  final dSig = u8(a['dSig']);
  final integrityHash = a['integrityHash'] as String;

  // dSig gate (server lines: hwClaimed + hash form, then P-256 verify).
  var dSigValidReal = false;
  if (bound && ticket.isNotEmpty) {
    final hwClaimed = pkD.isNotEmpty && dSig.isNotEmpty;
    final hashOk = RegExp(r'^[0-9a-f]{8}$').hasMatch(integrityHash);
    if (!hwClaimed || hashOk) {
      if (hwClaimed) {
        dSigValidReal = verifyDeviceSignature(
          pkDRaw64: pkD,
          preimage: ProxCrypto.deviceProvePreimage(
            sessionId: u8(a['sessionId']),
            windowId: u8(a['windowId']),
            j: a['j'] as int,
            challenge: u8(a['expectedCj']),
            faceTicketHashBytes: ticket,
            pkS: u8(a['presentedPk']),
            integrityHash: hashOk ? integrityHash : '',
          ),
          sig64: dSig,
        );
      }
    }
  }

  final faceValidAtMs = a['ticketStampMs'] as int;
  final out = verifyProve(
    req: VerifyRequest(
      id: a['id'] as String,
      windowId: u8(a['windowId']),
      j: a['j'] as int,
      cClaimed: u8(a['cClaimed']),
      sigS: u8(a['sigS']),
      faceScore: bound ? (a['ticketScore'] as double) : (a['faceScore'] as double),
      faceValidAt: bound
          ? DateTime.fromMillisecondsSinceEpoch(faceValidAtMs, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(a['nowMillis'] as int,
              isUtc: true),
      peerW: u8(a['peerW']),
      rssiDbm: a['rssiDbm'] as int,
      relayHop: a['relayHop'] as int,
      now: DateTime.fromMillisecondsSinceEpoch(a['nowMillis'] as int,
          isUtc: true),
      verifierVer: a['verifierVer'] as String,
      faceValidAtMs: faceValidAtMs,
      pkD: pkD,
      faceTicketHashBytes: ticket,
      livenessScore: a['livenessScore'] as double,
      livenessVer: a['livenessVer'] as String,
      attestationLevel: attestationLevelOf(a['attLevel'] as String),
      attestedUntil: DateTime.fromMillisecondsSinceEpoch(
          a['attUntilMillis'] as int,
          isUtc: true),
      dSigValid: bound && dSigValidReal,
      seenFaceValidAtMs: const {},
      priorScores:
          (a['priorScores'] as List).map((e) => (e as num).toDouble()).toList(),
      lastVerifierVer: a['lastVerifierVer'] as String,
    ),
    expectedCj: u8(a['expectedCj']),
    sessionId: u8(a['sessionId']),
    windowIdExpected: u8(a['windowIdExpected']),
    studentPk: ed.PublicKey(u8(a['presentedPk'])),
    revoked: false,
    freshWindow: a['freshWindow'] as bool,
    singleUseOk: a['singleUseOk'] as bool,
    requireBoundTicket: bound,
  );
  return <String, Object?>{
    'decision': ProveDecision.values.indexOf(out.decision),
    'reason': out.reason,
    'dSigValid': dSigValidReal,
    'flags': out.attestationFlags,
  };
}

/// Persistent off-main-thread prover. Spawn lazily, reuse per session,
/// kill on dispose. Every method throws on worker failure so callers can
/// fall back to the synchronous path.
class VerifyWorker {
  Isolate? _iso;
  SendPort? _port;
  Future<void>? _starting;
  Completer<void>? _ready;
  int _nextId = 0;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  bool _dead = false;

  /// Budget for one crypto call: pure math must answer far inside the
  /// client's 8 s POST timeout, else the caller falls back to sync.
  Duration callBudget = const Duration(seconds: 5);

  Future<void> _ensureStarted() {
    if (_port != null) return Future.value();
    final running = _starting;
    if (running != null) return running;
    final ready = Completer<void>();
    _ready = ready;
    _starting = _start(ready);
    return _starting!.whenComplete(() => _starting = null);
  }

  Future<void> _start(Completer<void> ready) async {
    final inbox = ReceivePort();
    inbox.listen((msg) {
      if (msg is SendPort && _port == null) {
        _port = msg;
        if (!ready.isCompleted) ready.complete();
        return;
      }
      if (msg is List && msg.length == 2 && msg[0] is int) {
        final c = _pending.remove(msg[0] as int);
        if (c == null || c.isCompleted) return;
        if (msg[1] is Map) {
          c.complete(Map<String, Object?>.from(msg[1] as Map));
        } else {
          c.completeError(StateError('${msg[1]}'));
        }
      }
    });
    try {
      _iso = await Isolate.spawn(_verifyWorkerEntry, inbox.sendPort);
      await ready.future;
    } catch (e) {
      inbox.close();
      _port = null;
      rethrow;
    }
  }

  void _failAll(Object e) {
    _dead = true;
    _port = null;
    try {
      _iso?.kill(priority: Isolate.immediate);
    } catch (_) {}
    _iso = null;
    final pending = Map<int, Completer<Map<String, Object?>>>.of(_pending);
    _pending.clear();
    for (final c in pending.values) {
      if (!c.isCompleted) c.completeError(e);
    }
  }

  /// Runs the dSig gate + verifyProve off-thread. [args] are the
  /// `_proveCrypto` primitives. Throws on worker/timeout failure —
  /// caller falls back to sync.
  Future<Map<String, Object?>> proveCrypto(
      Map<String, Object?> args) async {
    if (_dead) throw StateError('verify worker dead');
    await _ensureStarted().timeout(callBudget);
    final port = _port;
    if (port == null) throw StateError('verify worker not started');
    final id = _nextId++;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    try {
      port.send([id, 'proveCrypto', args]);
    } catch (e) {
      _pending.remove(id);
      _failAll(e);
      rethrow;
    }
    try {
      return await c.future.timeout(callBudget);
    } catch (e) {
      _pending.remove(id);
      _failAll(e);
      rethrow;
    }
  }

  /// Kills the isolate and drops pending calls (callers already fell
  /// back). Safe to call twice; call from server stop paths.
  void dispose() {
    _failAll(StateError('verify worker disposed'));
    _dead = false;
  }
}
