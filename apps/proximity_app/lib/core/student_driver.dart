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

enum StudentResult { marked, late, faceFailed, noSignal, error }

class MarkedReceipt {
  final String detail; // display code · server time
  final StudentResult result;
  const MarkedReceipt({required this.detail, required this.result});
}

abstract class StudentDriver {
  /// Face gate against the enrolled template. Returns match score, or null
  /// when the holder check fails (→ needs-review path, SK stays locked).
  Future<double?> checkFace(Uint8List frameBytes);

  /// 30s window: calls [onProgress] 0..1 as the radar sweeps.
  /// [hearChallenge] resolves with the live C_j heard over BLE radio
  /// (null on timeout). Never marks without radio + signed ACK.
  Future<MarkedReceipt> listenAndProve({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(double progress) onProgress,
    required Future<Uint8List?> Function() hearChallenge,
  });
}

class RealStudentDriver implements StudentDriver {
  final DeviceStore _store;
  final FaceEmbedder _embedder;
  final ProxBleEngine _engine;
  RealStudentDriver({
    required DeviceStore store,
    required FaceEmbedder embedder,
    required ProxBleEngine engine,
  })  : _store = store,
        _embedder = embedder,
        _engine = engine;

  @override
  Future<double?> checkFace(Uint8List frameBytes) async {
    final stored = await _store.readEnrollment();
    if (stored == null) return null;
    final session = FaceSession(embedder: _embedder);
    session.enroll(stored.template);
    try {
      final res = await session.verify(frameBytes,
          challenge: Uint8List.fromList(const [0, 0, 0, 0, 0, 0, 0, 0]),
          now: DateTime.now().toUtc());
      return res.decision == FaceDecision.pass ? res.score : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<MarkedReceipt> listenAndProve({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(double progress) onProgress,
    required Future<Uint8List?> Function() hearChallenge,
  }) async {
    final stored = await _store.readEnrollment();
    if (stored == null ||
        stored.email.toLowerCase() != identity.gmail.toLowerCase()) {
      return const MarkedReceipt(
          detail: 'Not enrolled on this device', result: StudentResult.error);
    }
    Uint8List? challenge;
    var heard = false;
    _engine.relayEnabled = true;
    final hear = hearChallenge().then((c) {
      if (c != null && c.length == kChallengeBytes) {
        challenge = c;
        heard = true;
      }
    });
    for (var sec = 1; sec <= kWindowSeconds; sec++) {
      await Future.delayed(const Duration(seconds: 1));
      onProgress(sec / kWindowSeconds);
      if (heard) break;
    }
    try {
      await hear.timeout(const Duration(seconds: 2));
    } catch (_) {}
    _engine.relayEnabled = false;
    final cj = challenge;
    if (!heard || cj == null) {
      return const MarkedReceipt(
          detail: 'No class signal heard — stay in the room, keep the app open',
          result: StudentResult.noSignal);
    }
    try {
      return await _prove(
        target: target,
        identity: identity,
        faceScore: faceScore,
        challenge: cj,
        seedHex: stored.seedHex,
      );
    } catch (e) {
      return MarkedReceipt(
          detail: 'Prove failed: $e', result: StudentResult.error);
    }
  }

  Future<MarkedReceipt> _prove({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required Uint8List challenge,
    required String seedHex,
  }) async {
    final sk = ed.newKeyFromSeed(hexDecode(seedHex));
    final pk = ed.public(sk);
    final pk32 = Uint8List.fromList(pk.bytes.sublist(0, 32));
    final client = ProxClient(host: target.host, port: target.port);
    try {
      // Verifies Sig_p against the RADIO-heard challenge: fake professors
      // throw here before anything is signed.
      final desc = await client.fetchWindow(challenge);
      final j = desc.jNow;
      final peerW = ProxCrypto.peerAlias(pk32, desc.windowId);
      // Answer over radio first so the professor's sighting exists, then
      // POST over WiFi. Best-effort: the server is the judge.
      try {
        await _engine.startScanning();
        await _engine.advertiseStudentResponse(
            identity.gmail.toLowerCase(), challenge, j, peerW);
      } catch (_) {}
      final res = await client.prove(
        desc: desc,
        studentId: identity.gmail.toLowerCase(),
        challenge: challenge,
        j: j,
        faceScore: faceScore,
        peerW: peerW,
        name: identity.name,
        roll: identity.roll,
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
      final ok = res.verifyAck(
        profPk: desc.profPk,
        sessionId: desc.sessionId,
        windowId: desc.windowId,
        j: j,
        studentId: identity.gmail.toLowerCase(),
      );
      if (!ok) {
        return const MarkedReceipt(
            detail: 'Bad professor signature',
            result: StudentResult.error);
      }
      final time = res.serverTime;
      final stamp =
          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
      return switch (res.decision) {
        ProveDecision.confirmed => MarkedReceipt(
            detail: '${desc.display} · $stamp',
            result: StudentResult.marked),
        ProveDecision.late => MarkedReceipt(
            detail: 'Late · $stamp', result: StudentResult.late),
        ProveDecision.invalid => MarkedReceipt(
            detail: res.reason, result: StudentResult.error),
      };
    } finally {
      client.close();
    }
  }
}

class FakeStudentDriver implements StudentDriver {
  final String ackDetail;
  FakeStudentDriver({this.ackDetail = 'KQ7 · 10:04:12'});

  @override
  Future<double?> checkFace(Uint8List frameBytes) async => 0.95;

  @override
  Future<MarkedReceipt> listenAndProve({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(double progress) onProgress,
    required Future<Uint8List?> Function() hearChallenge,
  }) async {
    for (var sec = 1; sec <= kWindowSeconds; sec++) {
      await Future.delayed(const Duration(seconds: 1));
      onProgress(sec / kWindowSeconds);
    }
    return MarkedReceipt(detail: ackDetail, result: StudentResult.marked);
  }
}

final studentDriverProvider = Provider<StudentDriver>((ref) {
  throw UnimplementedError('Override in main / tests');
});
