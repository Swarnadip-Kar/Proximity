import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  Uint8List v2GoldenLike(Uint8List tok) => Uint8List.fromList([
        0x50, 0x58, 0x02, 0x01, //
        ...tok, //
        10, 50, 19, 107, //
        0x20, 0xFB, //
      ]);
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

  test('v2 18B layout frozen byte-for-byte', () {
    // Golden vector: token 01..08, 10.50.19.107:8443.
    final golden = Uint8List.fromList([
      0x50, 0x58, 0x02, 0x01, //
      0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, //
      10, 50, 19, 107, //
      0x20, 0xFB, // 8443 BE
    ]);
    final packed = packAir(
      type: kAirTypeChallenge,
      token8: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      host: '10.50.19.107',
      port: 8443,
    )!;
    expect(packed, golden);
    final pdu = unpackAir(golden)!;
    expect(pdu.version, kAirVer);
    expect(pdu.type, kAirTypeChallenge);
    expect(pdu.token8, [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(pdu.host, '10.50.19.107');
    expect(pdu.port, 8443);
    expect(pdu.relayed, isFalse);
    expect(pdu.denseHint, isFalse);
  });

  test('v1 UUID formats frozen byte-for-byte', () {
    final cj = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    // hi64 prefixes are fixed allocations; lo8 carries the token verbatim.
    final cu = UuidCodec.packChallenge(cj);
    expect(UuidCodec.hi64Of(cu), kBaseP64);
    expect(UuidCodec.lo8Of(cu), cj);
    final rid = Uint8List.fromList([9, 9, 9, 9, 9, 9, 9, 9]);
    final ru = UuidCodec.packResponse(rid);
    expect(UuidCodec.hi64Of(ru), kBaseS64);
    expect(UuidCodec.lo8Of(ru), rid);
    expect(kBaseP64 == kBaseS64, isFalse);
  });

  test('v3 opt-in flags never steal token bytes', () {
    final tok = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    final v3 = packAirV3(
      type: kAirTypeChallenge,
      token8: tok,
      host: '10.50.19.107',
      port: 8443,
      relayed: true,
      denseHint: true,
    )!;
    expect(v3.length, kAirV3PayloadLen);
    // Same 18B field layout (only the version byte differs); the token,
    // IP and port bytes are untouched — flags live in the appended byte.
    expect(v3[2], kAirVerV3);
    expect(v3.sublist(3, 18), v2GoldenLike(tok).sublist(3, 18));
    expect(v3[18], kAirFlagRelayed | kAirFlagDenseHint);
    final pdu = unpackAir(v3)!;
    expect(pdu.version, kAirVerV3);
    expect(pdu.token8, tok);
    expect(pdu.relayed, isTrue);
    expect(pdu.denseHint, isTrue);
    // Flag-off v3 still parses (flags byte zero).
    final plain = packAirV3(
      type: kAirTypeResponse,
      token8: tok,
      host: '192.168.1.2',
      port: 8443,
    )!;
    final pp = unpackAir(plain)!;
    expect(pp.relayed, isFalse);
    expect(pp.denseHint, isFalse);
    // Non-zero reserved bits drop (strict).
    final reserved = Uint8List.fromList(plain)..[18] = 0x04;
    expect(unpackAir(reserved), isNull);
    expect(airDropCause(reserved), 'v3-reserved:4');
  });

  test('strict lengths + unknown ver/type drop with causes', () {
    final good = packAir(
      type: kAirTypeChallenge,
      token8: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      host: '10.50.19.107',
      port: 8443,
    )!;
    // Trailing garbage on a v2 payload drops (strict 18B).
    final trailed = Uint8List.fromList([...good, 0x00]);
    expect(unpackAir(trailed), isNull);
    expect(airDropCause(trailed), 'bad-len:2:19');
    // Truncated v3 (18B with ver 0x03) drops.
    final truncV3 = Uint8List.fromList(good)..[2] = kAirVerV3;
    expect(unpackAir(truncV3), isNull);
    expect(airDropCause(truncV3), 'bad-len:3:18');
    // Unknown version drops.
    final badVer = Uint8List.fromList(good)..[2] = 0x04;
    expect(unpackAir(badVer), isNull);
    expect(airDropCause(badVer), 'unknown-ver:4');
    // Unknown type drops.
    final badType = Uint8List.fromList(good)..[3] = 0x09;
    expect(unpackAir(badType), isNull);
    expect(airDropCause(badType), 'unknown-type:9');
    // Legacy bad-version fixture from the old suite still drops.
    expect(
        unpackAir(Uint8List.fromList(
            [0x50, 0x58, 0x01, 1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 0x20, 0xFB, 0])),
        isNull);
  });
}
