// Covers the pure AirParser extracted from the app's ble_radio.dart:
// v2 mfg/service-data paths, legacy v1 UUID paths, and the three probe
// log lines verbatim.
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  Uint8List v2Payload() => packAir(
        type: kAirTypeChallenge,
        token8: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        host: '10.50.19.107',
        port: 8443,
      )!;

  test('v2 manufacturer payload parses', () {
    final s = const AirParser().map(AirScan(
      services: [kAirSvc],
      manufacturerData: [AirMfg(kAirCompanyId, v2Payload())],
      rssi: -60,
    ))!;
    expect(s.type, kAirTypeChallenge);
    expect(s.token8, [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(s.ipHost, '10.50.19.107');
    expect(s.ipPort, 8443);
    expect(s.legacy, isFalse);
    expect(s.rssiDbm, -60);
  });

  test('v2 service-data payload parses (short + canonical key)', () {
    for (final key in ['fcd2', kAirSvc]) {
      final s = const AirParser().map(AirScan(
        services: [kAirSvc],
        serviceData: {key: v2Payload()},
        rssi: -70,
      ))!;
      expect(s.ipHost, '10.50.19.107');
      expect(s.rssiDbm, -70);
    }
  });

  test('v2 probe logs verbatim, null sighting', () {
    final lines = <String>[];
    void log(String tag, String msg) => lines.add('[$tag] $msg');
    // Unparseable candidate is skipped with its length logged.
    expect(
        const AirParser().map(
          AirScan(
            services: [kAirSvc],
            manufacturerData: [
              AirMfg(kAirCompanyId, Uint8List.fromList([9, 9, 9])),
              AirMfg(kAirCompanyId, v2Payload()),
            ],
          ),
          log: log,
        )!.ipHost,
        '10.50.19.107');
    expect(lines.first, '[BLE] air unparseable payload len=3');
    // FCD2 service with no v2 payload at all.
    lines.clear();
    expect(
        const AirParser().map(
          const AirScan(services: [kAirSvc]),
          log: log,
        ),
        isNull);
    expect(lines, ['[BLE] air FCD2 without v2 payload']);
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
