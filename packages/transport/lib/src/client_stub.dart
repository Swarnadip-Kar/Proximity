// Web records-build stub for client.dart: identical public API, every call
// throws. The web app never hosts or proves (records only); this exists so
// the shared drivers compile for web. Native builds use client.dart
// (dart:io HttpClient). If client.dart gains members used by shared code,
// mirror them here or the web build fails loudly (by design).
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:proximity_protocol/protocol.dart';

Never _web() =>
    throw UnsupportedError('records-only web build: no HTTPS client');

class WindowDescriptor {
  final String classLabel;
  final Uint8List sessionId;
  final Uint8List windowId;
  final int jNow;
  final ed.PublicKey profPk;
  final Uint8List sigP;
  final Uint8List tlsFp;
  final String display;
  final String org;
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
  });
}

class ProveResult {
  final ProveDecision decision;
  final String reason;
  final DateTime serverTime;
  final Uint8List sigAck;
  /// Attestation anomaly flags from the host (mirror of client.dart).
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
      _web();
}

class ProxClient {
  final String host;
  final int port;
  ProxClient({required this.host, required this.port});

  void close() {}

  Future<
      ({
        bool reachable,
        bool windowOpen,
        String classLabel,
        int waiting,
        String display,
        String org
      })> probeWindow({Duration timeout = const Duration(seconds: 4)}) =>
          _web();

  Future<void> postWaiting(
          {required String email,
          required String name,
          String roll = '',
          String org = ''}) =>
      _web();

  Future<void> postLeave({required String email}) => _web();

  Future<void> postManualRequest(
          {required String email,
          required String name,
          String roll = '',
          String org = ''}) =>
      _web();

  Future<String> fetchManualStatus(String email) => _web();

  Future<WindowDescriptor> fetchWindow(Uint8List radioChallenge) => _web();

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
    Future<Uint8List> Function(Uint8List faceTicketHashBytes, int j)? dSigFor,
    String attestationLevel = 'NONE',
    int attestedUntilMs = 0,
  }) =>
      _web();
}
