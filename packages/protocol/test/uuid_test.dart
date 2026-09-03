import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('UUID pack/unpack golden vectors', () {
    test('packChallenge embeds BaseP64 || C_j', () {
      final cj = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
      final uuid = UuidCodec.packChallenge(cj);
      expect(UuidCodec.isChallengeUuid(uuid), isTrue);
      expect(UuidCodec.isResponseUuid(uuid), isFalse);
      expect(UuidCodec.hi64Of(uuid), kBaseP64);
      expect(UuidCodec.lo8Of(uuid), cj);
      // canonical form 8-4-4-4-12 lowercase hex
      expect(
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
              .hasMatch(uuid),
          isTrue);
    });

    test('packResponse embeds BaseS64 || R_IDj', () {
      final r = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22]);
      final uuid = UuidCodec.packResponse(r);
      expect(UuidCodec.isResponseUuid(uuid), isTrue);
      expect(UuidCodec.isChallengeUuid(uuid), isFalse);
      expect(UuidCodec.hi64Of(uuid), kBaseS64);
      expect(UuidCodec.lo8Of(uuid), r);
    });

    test('roundtrip unpack(pack) == bytes', () {
      final cj = Uint8List.fromList([9, 8, 7, 6, 5, 4, 3, 2]);
      final u = UuidCodec.packChallenge(cj);
      final raw = UuidCodec.unpack(u);
      expect(raw.length, 16);
      expect(UuidCodec.hi64Of(u), kBaseP64);
      expect(raw.sublist(8), cj);
    });

    test('challenge/response prefixes differ; PROX_SVC fixed', () {
      expect(kBaseP64, isNot(kBaseS64));
      expect(
          RegExp(r'^[0-9a-f-]{36}$').hasMatch(kProxSvc.toLowerCase()), isTrue);
      expect(
          RegExp(r'^[0-9a-f-]{36}$').hasMatch(kProxChr.toLowerCase()), isTrue);
      expect(kProxSvc.toLowerCase(), isNot(kProxChr.toLowerCase()));
    });

    test('end-to-end: C_j -> UUID_P, R_IDj -> UUID_S, verify match', () {
      final sw = randBytes(32);
      final wid = randBytes(6);
      const j = 3;
      const id = '12342210';
      final cj = ProxCrypto.challengeForSubEpoch(sw, wid, j);
      final rid = ProxCrypto.responseToken(cj, id);
      final up = UuidCodec.packChallenge(cj);
      final us = UuidCodec.packResponse(rid);
      // Professor side recomputes:
      final expectedCj = ProxCrypto.challengeForSubEpoch(sw, wid, j);
      final expectedUs =
          UuidCodec.packResponse(ProxCrypto.responseToken(expectedCj, id));
      expect(up, UuidCodec.packChallenge(expectedCj));
      expect(us, expectedUs);
    });

    test('invalid strings not misclassified', () {
      expect(UuidCodec.isChallengeUuid('not-a-uuid'), isFalse);
      expect(UuidCodec.isResponseUuid('not-a-uuid'), isFalse);
      expect(UuidCodec.isChallengeUuid(kProxSvc), isFalse);
    });
  });
}
