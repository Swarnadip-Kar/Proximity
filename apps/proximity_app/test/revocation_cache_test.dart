// sec-revoke: offline CRL snapshot cache tests (no network — injected
// fetchers + memory store only; production HTTPS is never exercised here).
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/security/revocation_cache.dart';

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
}
