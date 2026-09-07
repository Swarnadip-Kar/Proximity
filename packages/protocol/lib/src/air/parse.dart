// Pure-Dart over-the-air scan parser (v2 + legacy v1).
//
// Moved verbatim out of the app's ble_radio.dart: the same v2
// manufacturer/service-data path, legacy v1 single-UUID path, and
// split-packet probe logs — now operating on the platform-free [AirScan]
// record and returning the platform-free [AirSighting], so protocol tests
// cover it. The app keeps only a thin adapter (platform BleDevice ->
// [AirScan] -> [AirParser] -> BleSighting) which wires [BleLog.log] as the
// [AirLogFn] sink, keeping every emitted log line byte-identical.
//
// Crypto/security semantics untouched: this only decodes bytes into
// sightings; challenge freshness, single-use, signature verification,
// face-match gating, and replay/relay defenses all live downstream.
library;

import 'dart:typed_data';

import '../air.dart';
import '../uuid_codec.dart';

/// One manufacturer-data entry of a scan record (company ID + payload).
class AirMfg {
  final int companyId;
  final Uint8List payload;
  const AirMfg(this.companyId, this.payload);
}

/// Platform-independent scan record: everything [AirParser] reads from a
/// platform advertisement (services, manufacturer data, service data, RSSI).
class AirScan {
  final List<String> services;
  final List<AirMfg> manufacturerData;
  final Map<String, Uint8List> serviceData;
  final int? rssi;
  const AirScan({
    this.services = const [],
    this.manufacturerData = const [],
    this.serviceData = const {},
    this.rssi,
  });
}

/// Parsed air sighting: v2 (FCD2 service + manufacturer payload) or legacy
/// v1 (single rotating 128-bit UUID). Field-for-field mirrors the app's
/// BleSighting so the adapter maps 1:1 (ttl defaults + peerW stay on the
/// app side).
class AirSighting {
  final int version; // kAirVer | kAirVerV3
  final int type; // kAirTypeChallenge | kAirTypeResponse | kAirTypeIpHint
  final Uint8List token8;
  final String ipHost; // HTTPS server ('' when unknown, e.g. v1 sightings)
  final int ipPort; // 0 when unknown
  final bool legacy; // true = v1 128-bit-UUID packet (Apple-TX compatible)
  final String? legacyUuid; // normalized UUID when [legacy]
  final bool relayed; // v3 b0 (false on v2/v1 — no flags byte there)
  final bool denseHint; // v3 b1
  final int rssiDbm;
  final DateTime at;
  const AirSighting({
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
  }) : assert(token8.length == 8);

  bool get isChallenge => type == kAirTypeChallenge;
  bool get isResponse => type == kAirTypeResponse;
  bool get isIpHint => type == kAirTypeIpHint;
}

/// Process-wide counted air-packet drops by cause (`unknown-ver:3`,
/// `bad-len:2:19`, …). Counted HERE (the live scan path) so unknown
/// ver/type on air is never silent: every drop emits one visible log line
/// carrying its running count. Tests reset via [AirDrops.reset].
class AirDrops {
  static final Map<String, int> _counts = {};
  static int note(String cause) =>
      _counts[cause] = (_counts[cause] ?? 0) + 1;
  static int count(String cause) => _counts[cause] ?? 0;
  static Map<String, int> get counts => Map.unmodifiable(_counts);
  static void reset() => _counts.clear();
}

/// Log sink for the parser's probe lines. The app passes BleLog.log so the
/// 'air unparseable' / 'FCD2 without v2 payload' / 'mfg-without-svc' lines
/// stay verbatim; defaults to silent for pure-Dart callers.
typedef AirLogFn = void Function(String tag, String msg);

void _silentLog(String tag, String msg) {}

/// Maps scan records to air sightings (v2 and legacy v1).
class AirParser {
  const AirParser();

  AirSighting? map(AirScan d, {AirLogFn log = _silentLog, DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    // --- v2 path: FCD2 service + 18B payload in manufacturer data
    // (company FFFF) or service data under the air UUID.
    var hasAirSvc = false;
    for (final s in d.services) {
      if (UuidCodec.normalize(s) == UuidCodec.normalize(kAirSvc)) {
        hasAirSvc = true;
        break;
      }
    }
    if (hasAirSvc) {
      final candidates = <Uint8List>[];
      for (final m in d.manufacturerData) {
        if (m.companyId != kAirCompanyId) continue;
        candidates.add(m.payload);
      }
      for (final e in d.serviceData.entries) {
        final k = UuidCodec.normalize(e.key);
        if (k == UuidCodec.normalize(kAirSvc) || k == 'fcd2') {
          candidates.add(e.value);
        }
      }
      for (final c in candidates) {
        final parsed = unpackAirDetailed(c);
        final pdu = parsed.pdu;
        if (pdu == null) {
          // Unknown ver/type is dropped, never parsed — and never silent:
          // one visible line per drop carrying the running per-cause count.
          final cause = parsed.drop ?? 'unknown';
          final n = AirDrops.note(cause);
          log('BLE', 'air drop $cause len=${c.length} (n=$n)');
          continue;
        }
        return AirSighting(
          version: pdu.version,
          type: pdu.type,
          token8: pdu.token8,
          ipHost: pdu.host,
          ipPort: pdu.port,
          relayed: pdu.relayed,
          denseHint: pdu.denseHint,
          rssiDbm: d.rssi ?? -127,
          at: at,
        );
      }
      log('BLE', 'air FCD2 without v2 payload');
      return null;
    }
    // Split-packet probe (Samsung extended-scan may deliver ADV and
    // scan-response in separate callbacks): a FFFF manufacturer payload
    // arriving WITHOUT the FCD2 service belongs to the other half. Logged
    // (not parsed) so live tests can tell displacement apart from split —
    // a merge cache only helps the latter.
    for (final m in d.manufacturerData) {
      if (m.companyId == kAirCompanyId) {
        log('BLE',
            'air mfg FFFF without FCD2 svc len=${m.payload.length} rssi=${d.rssi}');
        break;
      }
    }
    // --- legacy v1 path (Apple-TX compatible): rotating 128-bit UUIDs —
    // challenge (token in low 8 bytes), response, or server-address hint
    // (IP-hint ticks alternate with challenge ticks so Apple-originated
    // classes publish their HTTPS address through the mesh).
    for (final s in d.services) {
      final u = UuidCodec.normalize(s);
      if (UuidCodec.isChallengeUuid(u)) {
        return AirSighting(
          type: kAirTypeChallenge,
          token8: Uint8List.fromList(UuidCodec.lo8Of(s)),
          legacy: true,
          legacyUuid: u,
          rssiDbm: d.rssi ?? -127,
          at: at,
        );
      }
      if (UuidCodec.isResponseUuid(u)) {
        return AirSighting(
          type: kAirTypeResponse,
          token8: Uint8List.fromList(UuidCodec.lo8Of(s)),
          legacy: true,
          legacyUuid: u,
          rssiDbm: d.rssi ?? -127,
          at: at,
        );
      }
      if (UuidCodec.isIpHintUuid(u)) {
        final ip = UuidCodec.unpackIpHint(s);
        if (ip == null) continue;
        return AirSighting(
          type: kAirTypeIpHint,
          token8: Uint8List(8),
          ipHost: ip.host,
          ipPort: ip.port,
          legacy: true,
          legacyUuid: u,
          rssiDbm: d.rssi ?? -127,
          at: at,
        );
      }
    }
    return null;
  }
}
