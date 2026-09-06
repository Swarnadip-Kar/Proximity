import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('roundtrip challenge with IP:port', () {
    final mfg = packAir(
      type: kAirTypeChallenge,
      token8: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      host: '10.50.19.107',
      port: 8443,
    )!;
    expect(mfg.length, kAirPayloadLen);
    expect(mfg.sublist(0, 3), [0x50, 0x58, kAirVer]);
    final pdu = unpackAir(mfg)!;
    expect(pdu.type, kAirTypeChallenge);
    expect(pdu.isChallenge, isTrue);
    expect(pdu.token8, [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(pdu.host, '10.50.19.107');
    expect(pdu.port, 8443);
  });

  test('response type + port edges', () {
    final mfg = packAir(
      type: kAirTypeResponse,
      token8: Uint8List.fromList(List.filled(8, 7)),
      host: '192.168.1.2',
      port: 1,
    )!;
    expect(unpackAir(mfg)!.isResponse, isTrue);
    expect(
        unpackAir(packAir(
          type: kAirTypeResponse,
          token8: Uint8List.fromList(List.filled(8, 7)),
          host: '192.168.1.2',
          port: 65535,
        )!)!
            .port,
        65535);
    expect(
        packAir(
          type: kAirTypeResponse,
          token8: Uint8List.fromList(List.filled(8, 7)),
          host: '192.168.1.2',
          port: 0,
        ),
        isNull);
  });

  test('rejects garbage', () {
    expect(
        packAir(
          type: 0x09,
          token8: Uint8List.fromList(List.filled(8, 1)),
          host: '10.0.0.1',
          port: 8443,
        ),
        isNull); // bad type
    expect(
        packAir(
          type: kAirTypeChallenge,
          token8: Uint8List.fromList([1, 2, 3]),
          host: '10.0.0.1',
          port: 8443,
        ),
        isNull); // bad token len
    expect(
        packAir(
          type: kAirTypeChallenge,
          token8: Uint8List.fromList(List.filled(8, 1)),
          host: 'not-an-ip',
          port: 8443,
        ),
        isNull);
    expect(
        packAir(
          type: kAirTypeChallenge,
          token8: Uint8List.fromList(List.filled(8, 1)),
          host: '127.0.0.1',
          port: 8443,
        ),
        isNull); // loopback helps nobody
    expect(unpackAir(const [0, 0, 0]), isNull);
    expect(
        unpackAir(
            Uint8List.fromList([0x41, 0x42, 0x02, 1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 0x20, 0xFB, 0])),
        isNull); // bad magic
    expect(
        unpackAir(
            Uint8List.fromList([0x50, 0x58, 0x01, 1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 0x20, 0xFB, 0])),
        isNull); // bad version
  });

  test('fixed air service UUID is 16-bit', () {
    expect(kAirSvc16, 0xFCD2);
    expect(kAirSvc, contains('fcd2'));
  });
}
