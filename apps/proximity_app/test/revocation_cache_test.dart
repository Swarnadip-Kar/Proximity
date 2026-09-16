// sec-revoke: offline CRL snapshot cache tests (no network — injected
// fetchers + memory store only; production HTTPS is never exercised here).
import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/security/chain_serial.dart';
import 'package:proximity_app/core/security/revocation_cache.dart';
import 'package:proximity_app/core/sync/claim.dart';

RevocationSnapshot snap(String body, int fetchedAtMillis) =>
    RevocationSnapshot(
      rawBody: body,
      fetchedAt:
          DateTime.fromMillisecondsSinceEpoch(fetchedAtMillis, isUtc: true),
    );

void main() {
  group('flagFor (fail-open, never blocks)', () {
    test('empty snapshot flags revocation-stale', () {
      final now = DateTime.utc(2026, 9, 13);
      expect(RevocationSnapshot.empty().isStale(now), isTrue);
      expect(
          RevocationCache.flagFor(RevocationSnapshot.empty(), now: now),
          kRevocationStaleFlag);
    });

    test('fresh snapshot is clean', () {
      final now = DateTime.utc(2026, 9, 13);
      final s = snap('{"entries":{}}',
          now.millisecondsSinceEpoch - const Duration(days: 1).inMilliseconds);
      expect(s.isStale(now), isFalse);
      expect(RevocationCache.flagFor(s, now: now), '');
    });

    test('7d TTL boundary: 8d-old snapshot is stale', () {
      final now = DateTime.utc(2026, 9, 13);
      final s = snap('{"entries":{}}',
          now.millisecondsSinceEpoch - const Duration(days: 8).inMilliseconds);
      expect(s.isStale(now), isTrue);
      expect(RevocationCache.flagFor(s, now: now), kRevocationStaleFlag);
    });
  });

  group('reviewFlagsFor (professor review companion)', () {
    test('stale snapshot reports only revocation-stale (never accuses)', () {
      final now = DateTime.utc(2026, 9, 13);
      // Even a serial that WOULD match must not accuse from a stale CRL.
      final s = snap('{"entries":{"AB12":{"status":"REVOKED"}}}',
          now.millisecondsSinceEpoch - const Duration(days: 30).inMilliseconds);
      expect(
          RevocationCache.reviewFlagsFor(s, now: now, serialHex: 'ab12'),
          [kRevocationStaleFlag]);
    });

    test('fresh snapshot with revoked serial reports revocation-revoked', () {
      final now = DateTime.utc(2026, 9, 13);
      final s = snap('{"entries":{"AB12":{"status":"REVOKED"}}}',
          now.millisecondsSinceEpoch);
      expect(
          RevocationCache.reviewFlagsFor(s, now: now, serialHex: 'ab12'),
          [kRevocationRevokedFlag]);
    });

    test('fresh snapshot without match reports nothing', () {
      final now = DateTime.utc(2026, 9, 13);
      final s = snap('{"entries":{"AB12":{"status":"REVOKED"}}}',
          now.millisecondsSinceEpoch);
      expect(RevocationCache.reviewFlagsFor(s, now: now, serialHex: 'ff00'),
          isEmpty);
      expect(RevocationCache.reviewFlagsFor(s, now: now), isEmpty);
    });
  });

  group('isSerialRevoked (lenient, fail-open)', () {
    RevocationSnapshot fresh(String body) => snap(
        body, DateTime.utc(2026, 9, 13).millisecondsSinceEpoch);

    test('REVOKED / SUSPENDED match (case-insensitive serial)', () {
      expect(
          RevocationCache.isSerialRevoked(
              fresh('{"entries":{"ab12":{"status":"REVOKED"}}}'), 'AB12'),
          isTrue);
      expect(
          RevocationCache.isSerialRevoked(
              fresh('{"entries":{"ab12":{"status":"Suspended"}}}'), 'ab12'),
          isTrue);
    });

    test('VALID entry does not accuse', () {
      expect(
          RevocationCache.isSerialRevoked(
              fresh('{"entries":{"ab12":{"status":"VALID"}}}'), 'ab12'),
          isFalse);
    });

    test('unknown serial / empty / garbage never accuse', () {
      expect(
          RevocationCache.isSerialRevoked(
              fresh('{"entries":{"ab12":{"status":"REVOKED"}}}'), 'ffff'),
          isFalse);
      expect(RevocationCache.isSerialRevoked(fresh(''), 'ab12'), isFalse);
      expect(
          RevocationCache.isSerialRevoked(fresh('not-json{{{'), 'ab12'),
          isFalse);
      expect(
          RevocationCache.isSerialRevoked(
              fresh('{"entries":{"ab12":{"status":"REVOKED"}}}'), ''),
          isFalse);
    });
  });

  group('refreshIfStale (fail-open persistence)', () {
    test('fetches once when empty, then serves cached while fresh', () async {
      final store = MemoryRevocationStore();
      var calls = 0;
      Future<String> fetcher(Uri _) async {
        calls++;
        return '{"entries":{}}';
      }

      final now = DateTime.utc(2026, 9, 13);
      final first = await RevocationCache.refreshIfStale(
          store: store, fetcher: fetcher, now: now);
      expect(calls, 1);
      expect(first.isStale(now), isFalse);

      final second = await RevocationCache.refreshIfStale(
          store: store,
          fetcher: fetcher,
          now: now.add(const Duration(hours: 1)));
      expect(calls, 1); // fresh cache → no refetch
      expect(second.rawBody, '{"entries":{}}');
    });

    test('transport failure serves stale cached (never throws)', () async {
      final store = MemoryRevocationStore();
      final now = DateTime.utc(2026, 9, 13);
      Future<String> fail(Uri _) async => throw StateError('offline');
      final got = await RevocationCache.refreshIfStale(
          store: store, fetcher: fail, now: now);
      expect(got.isEmpty, isTrue);
      expect(RevocationCache.flagFor(got, now: now), kRevocationStaleFlag);
    });

    test('force refetches even when fresh; failure keeps fresh cache',
        () async {
      final store = MemoryRevocationStore();
      final now = DateTime.utc(2026, 9, 13);
      await RevocationCache.refreshIfStale(
          store: store, fetcher: (_) async => '{"entries":{}}', now: now);
      var calls = 0;
      final kept = await RevocationCache.refreshIfStale(
        store: store,
        fetcher: (_) async {
          calls++;
          throw StateError('offline');
        },
        now: now,
        force: true,
      );
      expect(calls, 1);
      expect(kept.isStale(now), isFalse); // old fresh body survives
    });

    test('refreshBestEffort never throws (setup-path contract)', () async {
      final store = MemoryRevocationStore();
      await RevocationCache.refreshBestEffort(
          store: store, fetcher: (_) async => throw StateError('offline'));
      // Returns normally; stale flag is the degradation signal.
      final loaded = await RevocationCache.load(store: store);
      expect(loaded.isEmpty, isTrue);
    });
  });

  group('chain_serial (offline, never throws)', () {
    test('genuine leaf DER extracts serial 01 -> "1"', () {
      final leaf = _pemToDer(_genuineLeafPem);
      expect(leaf.length, 643); // guards fixture drift
      expect(leafSerialHex(leaf), '1');
    });

    test('allSerialsHex is leaf-first over a genuine pair', () {
      final leaf = _pemToDer(_genuineLeafPem);
      final inter1 = _pemToDer(_genuineInter1Pem);
      expect(inter1.length, 553); // guards fixture drift
      // openssl ground truth: leaf 01, inter1 05014131950868983053.
      expect(allSerialsHex([leaf, inter1]),
          ['1', '5014131950868983053']);
    });

    test('synthetic versionless cert trims the DER sign pad', () {
      // Serial 0xAB needs a DER leading 0x00 pad (high bit); the value is
      // still 'ab', lowercase, no prefix.
      expect(leafSerialHex(_fakeCertDer(BigInt.from(0xab))), 'ab');
      expect(leafSerialHex(_fakeCertDer(BigInt.one)), '1');
      expect(leafSerialHex(_fakeCertDer(BigInt.zero)), '0');
      expect(
          allSerialsHex(
              [_fakeCertDer(BigInt.from(0xab)), _fakeCertDer(BigInt.one)]),
          ['ab', '1']);
    });

    test('garbage/empty/truncated DER -> null (never throws, never accuses)',
        () {
      expect(leafSerialHex(Uint8List(0)), isNull);
      expect(leafSerialHex(Uint8List.fromList([1, 2, 3])), isNull);
      expect(leafSerialHex(Uint8List.fromList('not-a-cert'.codeUnits)),
          isNull);
      // Truncated SEQUENCE header (claims length it does not have).
      expect(leafSerialHex(Uint8List.fromList([0x30, 0x0a, 0x02, 0x01])),
          isNull);
      // Oversized input refused without parsing.
      expect(
          leafSerialHex(Uint8List(kMaxCertDerBytes + 1)), isNull);
      expect(
          allSerialsHex([
            Uint8List(0),
            Uint8List.fromList([1, 2, 3]),
          ]),
          isEmpty);
    });

    test('hex-list decode is lenient (bad entries skipped, never throws)',
        () {
      final leaf = _pemToDer(_genuineLeafPem);
      final good = _hexEncode(leaf);
      expect(
          certsDerFromHexList([good, 'zz', '', 'abc', '0x$good']),
          hasLength(2));
      expect(certsDerFromHexList(['zz', '']), isEmpty);
    });
  });

  group('reviewFlagsForChain (chain-aware, fail-open)', () {
    RevocationSnapshot fresh(String body) => snap(
        body, DateTime.utc(2026, 9, 13).millisecondsSinceEpoch);
    RevocationSnapshot stale(String body) => snap(
        body,
        DateTime.utc(2026, 9, 13).millisecondsSinceEpoch -
            const Duration(days: 30).inMilliseconds);

    test('revoked leaf serial in FRESH snapshot -> revocation-revoked', () {
      // Entry key '01' vs extracted '1': leading-zero-insensitive match.
      final s = fresh('{"entries":{"01":{"status":"REVOKED"}}}');
      expect(
          RevocationCache.reviewFlagsForChain(s, [_pemToDer(_genuineLeafPem)],
              now: DateTime.utc(2026, 9, 13)),
          [kRevocationRevokedFlag]);
    });

    test('0x-prefixed / uppercase entry keys still match', () {
      final s = fresh('{"entries":{"0X01":{"status":"suspended"}}}');
      expect(
          RevocationCache.reviewFlagsForChain(s, [_pemToDer(_genuineLeafPem)],
              now: DateTime.utc(2026, 9, 13)),
          [kRevocationRevokedFlag]);
    });

    test('revoked INTERMEDIATE serial also accuses (all serials checked)',
        () {
      final s = fresh(
          '{"entries":{"5014131950868983053":{"status":"REVOKED"}}}');
      expect(
          RevocationCache.reviewFlagsForChain(
              s, [_pemToDer(_genuineLeafPem), _pemToDer(_genuineInter1Pem)],
              now: DateTime.utc(2026, 9, 13)),
          [kRevocationRevokedFlag]);
    });

    test('stale snapshot with revoked serial -> only revocation-stale', () {
      final s = stale('{"entries":{"01":{"status":"REVOKED"}}}');
      expect(
          RevocationCache.reviewFlagsForChain(s, [_pemToDer(_genuineLeafPem)],
              now: DateTime.utc(2026, 9, 13)),
          [kRevocationStaleFlag]);
    });

    test('empty serial -> stale-only when stale, clean when fresh', () {
      expect(
          RevocationCache.reviewFlagsForChain(
              stale('{"entries":{"01":{"status":"REVOKED"}}}'), const [],
              now: DateTime.utc(2026, 9, 13)),
          [kRevocationStaleFlag]);
      expect(
          RevocationCache.reviewFlagsForChain(
              fresh('{"entries":{"01":{"status":"REVOKED"}}}'), const [],
              now: DateTime.utc(2026, 9, 13)),
          isEmpty);
    });

    test('garbage DER in a fresh snapshot never accuses', () {
      final s = fresh('{"entries":{"01":{"status":"REVOKED"}}}');
      expect(
          RevocationCache.reviewFlagsForChain(
              s,
              [
                Uint8List.fromList([1, 2, 3]),
                Uint8List.fromList('junk'.codeUnits),
              ],
              now: DateTime.utc(2026, 9, 13)),
          isEmpty);
    });

    test('fresh snapshot without match reports nothing', () {
      final s = fresh('{"entries":{"ff00":{"status":"REVOKED"}}}');
      expect(
          RevocationCache.reviewFlagsForChain(s, [_pemToDer(_genuineLeafPem)],
              now: DateTime.utc(2026, 9, 13)),
          isEmpty);
    });

    test('hex convenience matches the DER path', () {
      final leafHex = _hexEncode(_pemToDer(_genuineLeafPem));
      final revoked = fresh('{"entries":{"01":{"status":"REVOKED"}}}');
      final now = DateTime.utc(2026, 9, 13);
      expect(RevocationCache.reviewFlagsForChainHex(revoked, [leafHex], now: now),
          [kRevocationRevokedFlag]);
      expect(
          RevocationCache.reviewFlagsForChainHex(
              stale('{"entries":{"01":{"status":"REVOKED"}}}'), [leafHex],
              now: now),
          [kRevocationStaleFlag]);
      // Undecodable chain hex degrades to flagFor semantics.
      expect(RevocationCache.reviewFlagsForChainHex(revoked, ['zz'], now: now),
          isEmpty);
      expect(
          RevocationCache.reviewFlagsForChainHex(
              RevocationSnapshot.empty(), ['zz'],
              now: now),
          [kRevocationStaleFlag]);
    });
  });

  group('revocationReviewFlagsForDevice (claim review companion)', () {
    StudentDeviceDoc docWith(List<String> chain) => StudentDeviceDoc(
          email: 'a@x.edu',
          uid: 'u',
          pkHex: 'pk',
          name: 'A',
          roll: '1',
          modelVer: 'm',
          attestationChain: chain,
        );

    test('bound device, revoked leaf, fresh snapshot -> revoked', () {
      final leafHex = _hexEncode(_pemToDer(_genuineLeafPem));
      final s = snap('{"entries":{"01":{"status":"REVOKED"}}}',
          DateTime.utc(2026, 9, 13).millisecondsSinceEpoch);
      expect(
          revocationReviewFlagsForDevice(s, docWith([leafHex]),
              now: DateTime.utc(2026, 9, 13)),
          [kRevocationRevokedFlag]);
    });

    test('unbound legacy device (empty chain) never accuses', () {
      final freshSnap = snap('{"entries":{"01":{"status":"REVOKED"}}}',
          DateTime.utc(2026, 9, 13).millisecondsSinceEpoch);
      expect(
          revocationReviewFlagsForDevice(freshSnap, docWith(const []),
              now: DateTime.utc(2026, 9, 13)),
          isEmpty);
      expect(
          revocationReviewFlagsForDevice(
              RevocationSnapshot.empty(), docWith(const []),
              now: DateTime.utc(2026, 9, 13)),
          [kRevocationStaleFlag]);
    });
  });
}

// -- sec-revoke fixtures ----------------------------------------------------
// Genuine Google test vectors (public, not secrets): leaf + first
// intermediate of android/keyattestation testdata `blueline/sdk28`
// `TEE_EC_NONE.pem` — the same chain `chain_verify_test.dart` in
// packages/protocol proves signatures over (duplicated here because that
// fixture lives in another package's test dir; lengths + openssl serials
// asserted above guard drift: leaf 643B serial 01, inter1 553B serial
// 05014131950868983053).

Uint8List _pemToDer(String pem) {
  final lines = pem
      .split('\n')
      .map((l) => l.trim())
      .where((l) =>
          l.isNotEmpty &&
          !l.startsWith('-----BEGIN') &&
          !l.startsWith('-----END'));
  return Uint8List.fromList(base64.decode(lines.join()));
}

const _genuineLeafPem = '''-----BEGIN CERTIFICATE-----
MIICfzCCAiagAwIBAgIBATAKBggqhkjOPQQDAjApMRkwFwYDVQQFExBhMGI2M2Ez
NTc0MzY3M2I3MQwwCgYDVQQMDANURUUwIBcNNzAwMTAxMDAwMDAwWhgPMjEwNjAy
MDcwNjI4MTVaMB8xHTAbBgNVBAMMFEFuZHJvaWQgS2V5c3RvcmUgS2V5MFkwEwYH
KoZIzj0CAQYIKoZIzj0DAQcDQgAEQ4ejMmmc5O9vcHpHjfo1EnLIuGseb9fTM26F
PBQBMjUAo0zyVYJQpnExkAnFnpKkfZPAyk7gLdFEngSetIk01qOCAUUwggFBMA4G
A1UdDwEB/wQEAwIHgDCCAS0GCisGAQQB1nkCAREEggEdMIIBGQIBAwoBAQIBBAoB
AQQJY2hhbGxlbmdlBAAwgYO/hT0IAgYBZiKOLXa/hUVzBHEwbzFJMEcEQmNvbS5n
b29nbGUud2lyZWxlc3MuYW5kcm9pZC5zZWN1cml0eS5hdHRlc3RhdGlvbnZlcmlm
aWVyLmNvbGxlY3RvcgIBADEiBCAQOTjuRTflno7nkvZUUE+4NG/Gs0bQu8RBX8M5
/PyOwTB4oQUxAwIBAqIDAgEDowQCAgEAqgMCAQG/g3cCBQC/hT4DAgEAv4VALDAq
BAABAQAKAQIEIG6dDFvqLNqZ8+XHb7J0DN+Hk9HTY0Is0GXSK/Ciu1utv4VBBQID
AV+Qv4VCBQIDAxS0v4VOBQIDAxRRv4VPBQIDAxS0MAoGCCqGSM49BAMCA0cAMEQC
IA21HJafZI/wGy5lXuBtZt40jaXq6zlbXm9kPJm3CzFQAiA81uyzS8PTA/h9W5hC
jrSGcsjHj3vZ0fDFxjq8JHAckg==
-----END CERTIFICATE-----''';

const _genuineInter1Pem = '''-----BEGIN CERTIFICATE-----
MIICJTCCAaugAwIBAgIKBQFBMZUIaJgwUzAKBggqhkjOPQQDAjApMRkwFwYDVQQF
ExBlMThjNGYyY2E2OTk3MzlhMQwwCgYDVQQMDANURUUwHhcNMTgwNzIzMjAzMzI4
WhcNMjgwNzIwMjAzMzI4WjApMRkwFwYDVQQFExBhMGI2M2EzNTc0MzY3M2I3MQww
CgYDVQQMDANURUUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATTv5kVHCdbVoeY
YPnrPjNJ0QNtZMeJAKq0e0w5XfCMc2iHvHmZZ+hmWJud1S94wLKPJKx8OkJfpJg2
fZoISK4Wo4G6MIG3MB0GA1UdDgQWBBRGZfPoN9ZqhkjAS/oWiLsbm6HO9TAfBgNV
HSMEGDAWgBStaJfkd3MUTYzmNFYScunw3VEFvjAPBgNVHRMBAf8EBTADAQH/MA4G
A1UdDwEB/wQEAwICBDBUBgNVHR8ETTBLMEmgR6BFhkNodHRwczovL2FuZHJvaWQu
Z29vZ2xlYXBpcy5jb20vYXR0ZXN0YXRpb24vY3JsLzA1MDE0MTMxOTUwODY4OTgz
MDUzMAoGCCqGSM49BAMCA2gAMGUCMQDtPMGkhcrmmUIm0iDXKgtlIGE/27j9e44P
9lEoqbvgy4wT4pmfxYrP7S6JunE+2qcCMHt3SohaS7BaOu7awdlsdLoRO1avJURZ
fJnen8gPP+oiqw/P5tWy59kgcDOEcohbvg==
-----END CERTIFICATE-----''';

/// Minimal versionless TBS cert carrying [serial] (outer shape mirrors a
/// real Certificate; the serial parser ignores everything past the TBS
/// serial slot). Built with asn1lib in-test — no fixture drift possible.
Uint8List _fakeCertDer(BigInt serial) {
  final tbs = ASN1Sequence()
    ..add(ASN1Integer(serial))
    ..add(ASN1Integer.fromInt(0));
  final outer = ASN1Sequence()
    ..add(tbs)
    ..add(ASN1Integer.fromInt(0))
    ..add(ASN1Integer.fromInt(0));
  return Uint8List.fromList(outer.encodedBytes);
}

String _hexEncode(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
