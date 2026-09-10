// Observed air packet: v2 (FCD2 service + manufacturer payload) or
// legacy v1 (single rotating 128-bit UUID, challenge in low bytes).
//
// Split from ble.dart (M4 radio slim): pure value type, no radio logic.
library;

import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';

/// Observed air packet: v2 (FCD2 service + manufacturer payload) or
/// legacy v1 (single rotating 128-bit UUID, challenge in low bytes).
class BleSighting {
  final int version; // kAirVer | kAirVerV3 (v2 default; v1 UUIDs report v2)
  final int type; // kAirTypeChallenge | kAirTypeResponse
  final Uint8List token8;
  final String ipHost; // HTTPS server ('' when unknown, e.g. v1 sightings)
  final int ipPort; // 0 when unknown
  final bool legacy; // true = v1 128-bit-UUID packet (Apple-TX compatible)
  final String? legacyUuid; // normalized UUID when [legacy]
  final bool relayed; // v3 b0 heard on air (a relay re-aired this packet)
  final bool denseHint; // v3 b1 heard on air (dense graph signal)
  final Uint8List? peerW; // 8B alias when present (response path)
  final int rssiDbm;
  final DateTime at;
  /// Relay budget left. Air packets carry no TTL byte, so direct
  /// sightings default to [kTtlOriginate]; an explicit 0 means TTL spent
  /// (never relay). The relay storm-guard set still bounds each packet to
  /// one re-advertise per device.
  final int ttl;
  BleSighting({
    this.version = kAirVer,
    required this.type,
    required this.token8,
    this.ipHost = '',
    this.ipPort = 0,
    this.legacy = false,
    this.legacyUuid,
    this.relayed = false,
    this.denseHint = false,
    required this.rssiDbm,
    required this.at,
    this.peerW,
    this.ttl = kTtlOriginate,
  }) : assert(token8.length == 8);

  bool get isChallenge => type == kAirTypeChallenge;
  bool get isResponse => type == kAirTypeResponse;
  bool get isIpHint => type == kAirTypeIpHint;
  bool get hasServer => ipHost.isNotEmpty && ipPort > 0;

  /// Dedup / split-horizon key, format-aware for v1 UUIDs, token-keyed
  /// for v2/v3 (version + relay flags EXCLUDED: the same rotation token
  /// heard direct and re-aired is ONE packet — otherwise each re-air would
  /// relay again. Sender-keyed [LruDedup] is the OTHER dedup domain: it
  /// keys mesh PDUs by sender+ts+type+digest for BitChat parity, while
  /// this key + tokenRelayGuard bound re-airs to one per token per device).
  String get key => legacy
      ? 'uuid:${legacyUuid ?? ''}'
      : '$type:${token8.map((e) => e.toRadixString(16).padLeft(2, '0')).join()}';

  /// Short token for logs.
  String get shortToken =>
      token8.sublist(0, 4).map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  /// Human log label: server address for IP hints (whose token bytes are
  /// unused), short token otherwise.
  String get label => isIpHint && hasServer ? '$ipHost:$ipPort' : '${shortToken}…';
}
