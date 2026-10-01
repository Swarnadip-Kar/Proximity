// Covers the pure AirParser extracted from the app's ble_radio.dart:
// single mfg format, legacy v1 UUID paths, and the three probe
// log lines verbatim.
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  setUp(AirDrops.reset);
  Uint8List mfgPayload() => packAir(
        type: kAirTypeChallenge,
        token8: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        host: '10.50.19.107',
        port: 8443,
      )!;

  test('mfg manufacturer payload parses', () {
    final s = const AirParser().map(AirScan(
      services: [kAirSvc],
      manufacturerData: [AirMfg(kAirCompanyId, mfgPayload())],
      rssi: -60,
    ))!;
    expect(s.type, kAirTypeChallenge);
    expect(s.token8, [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(s.ipHost, '10.50.19.107');
    expect(s.ipPort, 8443);
    expect(s.legacy, isFalse);
    expect(s.rssiDbm, -60);
  });

  test('service-data payload parses (short + canonical key)', () {
    for (final key in ['fcd2', kAirSvc]) {
      final s = const AirParser().map(AirScan(
        services: [kAirSvc],
        serviceData: {key: mfgPayload()},
        rssi: -70,
      ))!;
      expect(s.ipHost, '10.50.19.107');
      expect(s.rssiDbm, -70);
    }
  });

  test('probe logs verbatim, null sighting', () {
    final lines = <String>[];
    void log(String tag, String msg) => lines.add('[$tag] $msg');
    // Unparseable candidate is skipped with its length logged.
    expect(
        const AirParser().map(
          AirScan(
            services: [kAirSvc],
            manufacturerData: [
              AirMfg(kAirCompanyId, Uint8List.fromList([9, 9, 9])),
              AirMfg(kAirCompanyId, mfgPayload()),
            ],
          ),
          log: log,
        )!.ipHost,
        '10.50.19.107');
    expect(lines.first, '[BLE] air drop short:3 len=3 (n=1)');
    // FCD2 service with no payload at all.
    lines.clear();
    expect(
        const AirParser().map(
          const AirScan(services: [kAirSvc]),
          log: log,
        ),
        isNull);
    expect(lines, ['[BLE] air FCD2 without payload']);
    // Split-packet probe: FFFF mfg without the FCD2 service.
    lines.clear();
    expect(
        const AirParser().map(
          AirScan(
            manufacturerData: [
              AirMfg(kAirCompanyId, Uint8List.fromList([1, 2]))
            ],
            rssi: -80,
          ),
          log: log,
        ),
        isNull);
    expect(lines,
        ['[BLE] air mfg FFFF without FCD2 svc len=2 rssi=-80']);
  });

  test('unknown ver/type drop with counted visible log', () {
    final lines = <String>[];
    void log(String tag, String msg) => lines.add('[$tag] $msg');
    // Unknown version 0x04 (same 19B shape): dropped, counted, visible.
    final badVer = Uint8List.fromList(
        [0x50, 0x58, 0x04, 0x01, 1, 2, 3, 4, 5, 6, 7, 8, 10, 0, 0, 1, 0x20, 0xFB, 0x00]);
    expect(
        const AirParser().map(
          AirScan(
            services: [kAirSvc],
            manufacturerData: [AirMfg(kAirCompanyId, badVer)],
          ),
          log: log,
        ),
        isNull);
    expect(lines, [
      '[BLE] air drop unknown-ver:4 len=19 (n=1)',
      '[BLE] air FCD2 without payload',
    ]);
    expect(AirDrops.count('unknown-ver:4'), 1);
    // Second identical drop bumps the running count on the line.
    lines.clear();
    expect(
        const AirParser().map(
          AirScan(
            services: [kAirSvc],
            manufacturerData: [AirMfg(kAirCompanyId, badVer)],
          ),
          log: log,
        ),
        isNull);
    expect(lines, [
      '[BLE] air drop unknown-ver:4 len=19 (n=2)',
      '[BLE] air FCD2 without payload',
    ]);
    // Unknown type 0x09 with good framing: dropped, not parsed.
    lines.clear();
    final badType = Uint8List.fromList(
        [0x50, 0x58, 0x03, 0x09, 1, 2, 3, 4, 5, 6, 7, 8, 10, 0, 0, 1, 0x20, 0xFB, 0x00]);
    expect(
        const AirParser().map(
          AirScan(
            services: [kAirSvc],
            manufacturerData: [AirMfg(kAirCompanyId, badType)],
          ),
          log: log,
        ),
        isNull);
    expect(lines, [
      '[BLE] air drop unknown-type:9 len=19 (n=1)',
      '[BLE] air FCD2 without payload',
    ]);
  });

  test('flags + hop parse; token identity ignores flags', () {
    final flagged = packAir(
      type: kAirTypeChallenge,
      token8: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      host: '10.50.19.107',
      port: 8443,
      relayed: true,
      denseHint: true,
    )!;
    expect(flagged.length, kAirPayloadLen);
    final s = const AirParser().map(AirScan(
      services: [kAirSvc],
      manufacturerData: [AirMfg(kAirCompanyId, flagged)],
      rssi: -60,
    ))!;
    expect(s.version, kAirVer);
    expect(s.type, kAirTypeChallenge);
    expect(s.token8, [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(s.ipHost, '10.50.19.107');
    expect(s.relayed, isTrue);
    expect(s.denseHint, isTrue);
    expect(s.hop, 0);
    // Hop rides the parser too.
    final hopped = packAir(
      type: kAirTypeChallenge,
      token8: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      host: '10.50.19.107',
      port: 8443,
      relayed: true,
      hop: 2,
    )!;
    final sh = const AirParser().map(AirScan(
      services: [kAirSvc],
      manufacturerData: [AirMfg(kAirCompanyId, hopped)],
      rssi: -60,
    ))!;
    expect(sh.hop, 2);
    expect(sh.relayed, isTrue);
    // Token-keyed identity ignores version/flags: same rotation token heard
    // direct and relayed is ONE packet for relay dedup.
    expect(unpackAir(mfgPayload())!.key, unpackAir(flagged)!.key);
  });

  test('cross-platform: each originator parses on the other path', () {
    // Android/Linux-originated mfg (packAir) and Apple-originated v1
    // (packChallenge) cross-parse through the SAME platform-free parser —
    // the wire stays identical bytes/preimages on all OS, scan unfiltered,
    // parse in-app. Both directions, one test.
    final tok = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    final mfgSight = const AirParser().map(AirScan(
      services: [kAirSvc],
      manufacturerData: [
        AirMfg(
            kAirCompanyId,
            packAir(
                type: kAirTypeChallenge,
                token8: tok,
                host: '10.50.19.107',
                port: 8443)!)
      ],
      rssi: -60,
    ))!;
    final v1sight = const AirParser().map(AirScan(
      services: [UuidCodec.packChallenge(tok)],
      rssi: -61,
    ))!;
    expect(mfgSight.legacy, isFalse);
    expect(v1sight.legacy, isTrue);
    expect(mfgSight.token8, v1sight.token8); // same preimage both ways
    expect(mfgSight.type, kAirTypeChallenge);
    expect(v1sight.type, kAirTypeChallenge);
  });

  test('legacy v1 challenge / response / ip-hint parse', () {
    final cj = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    final c = const AirParser().map(AirScan(
      services: [UuidCodec.packChallenge(cj)],
      rssi: -61,
    ))!;
    expect(c.type, kAirTypeChallenge);
    expect(c.token8, cj);
    expect(c.legacy, isTrue);
    expect(c.legacyUuid, UuidCodec.normalize(UuidCodec.packChallenge(cj)));

    final rid = Uint8List.fromList([9, 9, 9, 9, 9, 9, 9, 9]);
    final r = const AirParser().map(AirScan(
      services: [UuidCodec.packResponse(rid)],
    ))!;
    expect(r.type, kAirTypeResponse);
    expect(r.token8, rid);
    expect(r.legacy, isTrue);
    expect(r.rssiDbm, -127); // null rssi default, as in the app adapter

    final hint = UuidCodec.packIpHint('10.50.19.107', 8443)!;
    final h = const AirParser().map(AirScan(services: [hint]))!;
    expect(h.type, kAirTypeIpHint);
    expect(h.token8, Uint8List(8));
    expect(h.ipHost, '10.50.19.107');
    expect(h.ipPort, 8443);
    expect(h.legacy, isTrue);
  });

  test('unrelated scan parses to null silently', () {
    final lines = <String>[];
    expect(
        const AirParser().map(
          const AirScan(services: ['0000180d-0000-1000-8000-00805f9b34fb']),
          log: (t, m) => lines.add(m),
        ),
        isNull);
    expect(lines, isEmpty);
  });

  test('parseIpv4 is the single shared helper', () {
    expect(parseIpv4('10.50.19.107'), [10, 50, 19, 107]);
    expect(parseIpv4(' 10.0.0.1 '), [10, 0, 0, 1]);
    expect(parseIpv4('not-an-ip'), isNull);
    expect(parseIpv4('10.0.0'), isNull);
    expect(parseIpv4('10.0.0.256'), isNull);
    // Both codecs route through it: same accept/reject surface as before.
    expect(
        packAir(
          type: kAirTypeChallenge,
          token8: Uint8List(8),
          host: 'not-an-ip',
          port: 8443,
        ),
        isNull);
    expect(UuidCodec.packIpHint('not-an-ip', 8443), isNull);
    expect(UuidCodec.packIpHint('10.50.19.107', 8443), isNotNull);
  });
}
