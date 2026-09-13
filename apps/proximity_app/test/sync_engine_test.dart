// SyncEngine tests (Track 4 §4): outbox durability, per-course FIFO order,
// union-merge convergence, tombstone-wins, dropped-mid-sync replay (no
// dups), backoff schedule, org drill, offline deferral, badge count.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_storage/storage.dart';

ClassRecord rec(String id, String course, String startIso, String ts,
        {Map<String, bool>? w1,
        Map<String, String>? names,
        String org = 'univ.edu'}) =>
    ClassRecord(
      id: id,
      courseId: course,
      classLabel: course,
      dateIso: startIso.substring(0, 10),
      timestampIso: ts,
      startIso: startIso,
      windows: [w1 ?? const {}],
      names: names ?? const {},
      rolls: const {},
      org: org,
    );

SyncProf get prof =>
    (uid: 'u1', email: 'p@univ.edu', name: 'Prof', org: 'univ.edu');

/// Fake that drops the Nth push once (dropped-mid-sync replay drill).
class FlakyCloud extends FakeCloudSync {
  int pushes = 0;
  int failOnPush = -1;
  final List<String> pushOrder = [];
  FlakyCloud({super.online});
  @override
  Future<void> pushSession(
      {required String profUid,
      required String profEmail,
      required String profName,
      required ClassRecord record,
      String? profOrg}) async {
    pushes++;
    pushOrder.add(record.id);
    if (pushes == failOnPush) {
      throw StateError('dropped mid-sync');
    }
    return super.pushSession(
        profUid: profUid,
        profEmail: profEmail,
        profName: profName,
        record: record,
        profOrg: profOrg);
  }
}

void main() {
  test('saveSessionLocal writes history + outbox together', () async {
    final store = InMemoryDeviceStore();
    final engine = SyncEngine();
    final r = rec('s1', 'CS201', '2026-09-01T10:00:00.000Z',
        '2026-09-01T10:05:00.000Z',
        w1: {'a@univ.edu': true});
    await engine.saveSessionLocal(store, r);
    expect((await store.readHistory()).map((e) => e.id), ['s1']);
    expect(await engine.pendingCount(store), 1);
    final outbox = await store.readPendingSessions();
    expect(outbox.single['id'], 's1');
    expect(outbox.single['org'], 'univ.edu');
  });

  test('offline flush defers everything (zero cloud writes)', () async {
    final store = InMemoryDeviceStore();
    final cloud = FakeCloudSync()..online = false;
    final engine = SyncEngine();
    await engine.saveSessionLocal(
        store,
        rec('s1', 'CS201', '2026-09-01T10:00:00.000Z',
            '2026-09-01T10:05:00.000Z'));
    final res =
        await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.online, isFalse);
    expect(res.remaining, 1);
    expect(cloud.sessions, isEmpty);
    expect(await engine.pendingCount(store), 1);
  });

  test('long-offline-gap replay: per-course FIFO order, no dups', () async {
    final store = InMemoryDeviceStore();
    final cloud = FlakyCloud();
    final engine = SyncEngine();
    // Enqueue out of order while offline: FIFO must still push
    // startIso-ascending within each course.
    cloud.online = false;
    await engine.saveSessionLocal(store,
        rec('late', 'CS201', '2026-09-03T10:00:00.000Z', '2026-09-03T10:05:00.000Z'));
    await engine.saveSessionLocal(store,
        rec('early', 'CS201', '2026-09-01T10:00:00.000Z', '2026-09-01T10:05:00.000Z'));
    await engine.saveSessionLocal(store,
        rec('other', 'CS101', '2026-09-02T10:00:00.000Z', '2026-09-02T10:05:00.000Z'));
    var res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.online, isFalse);
    expect(cloud.sessions, isEmpty);
    // Reconnect: all three push, CS101 first (course), then CS201 by start.
    cloud.online = true;
    res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.online, isTrue);
    expect(res.pushed, 3);
    expect(cloud.pushOrder, ['other', 'early', 'late']);
    expect(cloud.sessions.keys.toSet(), {'other', 'early', 'late'});
    expect(res.remaining, 0);
    expect(await engine.pendingCount(store), 0); // badge → 0
    // Second flush pushes nothing (converged, no dups).
    cloud.pushOrder.clear();
    res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.pushed, 0);
    expect(cloud.pushOrder, isEmpty);
  });

  test('dropped-mid-sync replay retries with backoff, no dups', () async {
    final store = InMemoryDeviceStore();
    final cloud = FlakyCloud()..failOnPush = 2;
    final engine = SyncEngine();
    await engine.saveSessionLocal(store,
        rec('s1', 'CS201', '2026-09-01T10:00:00.000Z', '2026-09-01T10:05:00.000Z'));
    await engine.saveSessionLocal(store,
        rec('s2', 'CS201', '2026-09-02T10:00:00.000Z', '2026-09-02T10:05:00.000Z'));
    var res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.pushed, 1); // s1 acked, s2 dropped
    expect(res.remaining, 1);
    expect(cloud.sessions.keys, ['s1']);
    // Entry carries attempts + nextRetryAt (persisted, not due yet).
    final outbox = await store.readPendingSessions();
    expect(outbox.single['id'], 's2');
    expect(outbox.single['attempts'], 1);
    expect((outbox.single['nextRetryAtIso'] as String).isNotEmpty, isTrue);
    // Immediate reflush does NOT retry (backoff not elapsed) — no dup push.
    cloud.pushOrder.clear();
    res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.pushed, 0);
    expect(cloud.pushOrder, isEmpty);
    // After the backoff elapses the retry lands exactly once.
    final retryAt =
        DateTime.parse(outbox.single['nextRetryAtIso'] as String).toUtc();
    engine.nowUtc = () => retryAt.add(const Duration(seconds: 1));
    res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.pushed, 1);
    expect(cloud.sessions.keys.toSet(), {'s1', 's2'});
    expect(res.remaining, 0);
  });

  test('union-merge convergence: marks from two devices add up', () async {
    final store = InMemoryDeviceStore();
    final cloud = FakeCloudSync();
    final engine = SyncEngine();
    // Device A marks alice locally (offline).
    await engine.saveSessionLocal(
        store,
        rec('s1', 'CS201', '2026-09-01T10:00:00.000Z',
            '2026-09-01T10:05:00.000Z',
            w1: {'alice@univ.edu': true},
            names: {'alice@univ.edu': 'Alice'}));
    // Device B pushes bob for the SAME session id, newer timestamp.
    await cloud.pushSession(
        profUid: 'u1',
        profEmail: 'p@univ.edu',
        profName: 'Prof',
        record: rec('s1', 'CS201', '2026-09-01T10:00:00.000Z',
            '2026-09-01T11:00:00.000Z',
            w1: {'bob@univ.edu': true},
            names: {'bob@univ.edu': 'Bob'}),
        profOrg: 'univ.edu');
    final res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.online, isTrue);
    // Pure LWW would have kept only bob; union keeps BOTH marks.
    final local = (await store.readHistory()).singleWhere((r) => r.id == 's1');
    expect(local.w1['alice@univ.edu'], isTrue);
    expect(local.w1['bob@univ.edu'], isTrue);
    expect(local.names['alice@univ.edu'], 'Alice');
    final pushed = await cloud.pullProfSessions('u1', org: 'univ.edu');
    final doc = pushed.singleWhere((r) => r.id == 's1');
    expect(doc.w1['alice@univ.edu'], isTrue);
    expect(doc.w1['bob@univ.edu'], isTrue);
  });

  test('tombstone wins over older upserts, badge drains', () async {
    final store = InMemoryDeviceStore();
    final cloud = FakeCloudSync();
    final engine = SyncEngine();
    final r = rec('s1', 'CS201', '2026-09-01T10:00:00.000Z',
        '2026-09-01T10:05:00.000Z',
        w1: {'a@univ.edu': true});
    await engine.saveSessionLocal(store, r);
    var res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.pushed, 1);
    // Delete locally while offline: history + outbox drop, tombstone stays.
    cloud.online = false;
    await engine.deleteSessionsLocal(store, ['s1'], org: 'univ.edu');
    expect(await store.readHistory(), isEmpty);
    expect(await engine.pendingCount(store), 1); // the tombstone
    res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.online, isFalse);
    // Reconnect: the delete propagates even though the cloud copy is older.
    cloud.online = true;
    res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.deleted, 1);
    expect(cloud.sessions, isEmpty);
    expect(await store.readHistory(), isEmpty);
    expect(await engine.pendingCount(store), 0);
  });

  test('org drill: cross-org entry refused and kept', () async {
    final store = InMemoryDeviceStore();
    final cloud = FakeCloudSync();
    final engine = SyncEngine();
    await engine.saveSessionLocal(
        store,
        rec('evil', 'CS201', '2026-09-01T10:00:00.000Z',
            '2026-09-01T10:05:00.000Z',
            org: 'rival.edu'));
    final res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.pushed, 0);
    expect(cloud.sessions, isEmpty);
    expect(res.remaining, 1); // kept, not dropped
    expect(await engine.pendingCount(store), 1);
  });

  test('org-less local history never pushes (fail-closed, no backfill)',
      () async {
    // Full-fresh: the engine never stamps org — an org-less row is
    // hand-built, not a migration artifact, so it stays local and the
    // flush pushes nothing.
    final store = InMemoryDeviceStore();
    final cloud = FakeCloudSync();
    final engine = SyncEngine();
    await store.upsertHistory(rec('s1', 'CS201',
        '2026-09-01T10:00:00.000Z', '2026-09-01T10:05:00.000Z',
        org: ''));
    final res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.online, isTrue);
    // No backfill: the row keeps its org-less stamp locally and never
    // reaches the cloud.
    final local = (await store.readHistory()).single;
    expect(local.org, isEmpty);
    expect(cloud.sessions, isEmpty);
  });

  test('org-less cloud rows stay invisible (no unfiltered discovery pull)',
      () async {
    // Full-fresh: flush runs only org-filtered pulls, so a pre-org cloud
    // doc never merges into local history.
    final store = InMemoryDeviceStore();
    final cloud = FakeCloudSync();
    final engine = SyncEngine();
    final legacyDoc = sessionToDoc(
        profUid: 'u1',
        profEmail: 'p@univ.edu',
        profName: 'Prof',
        record: rec('old2', 'CS201', '2026-08-02T10:00:00.000Z',
            '2026-08-02T10:05:00.000Z',
            org: ''),
        profOrg: '');
    legacyDoc.remove('org');
    cloud.sessions['old2'] = legacyDoc;
    final res = await engine.flush(store: store, cloud: cloud, prof: prof);
    expect(res.online, isTrue);
    expect(await store.readHistory(), isEmpty);
  });

  test('backoff schedule 5s -> 1min -> 15min cap with jitter', () {
    final rng = Random(7);
    final first = syncBackoffFor(0, rng: rng);
    expect(first.inMilliseconds, inInclusiveRange(3750, 7500));
    final second = syncBackoffFor(1, rng: rng);
    expect(second.inMilliseconds, inInclusiveRange(45000, 90000));
    final third = syncBackoffFor(2, rng: rng);
    expect(third.inMilliseconds, inInclusiveRange(675000, 1350000));
    final capped = syncBackoffFor(99, rng: rng);
    expect(capped.inMilliseconds, inInclusiveRange(675000, 1350000));
  });

  test('single-flight: concurrent flushes do not interleave', () async {
    final store = InMemoryDeviceStore();
    final cloud = FakeCloudSync();
    final engine = SyncEngine();
    await engine.saveSessionLocal(store,
        rec('s1', 'CS201', '2026-09-01T10:00:00.000Z', '2026-09-01T10:05:00.000Z'));
    final results = await Future.wait([
      engine.flush(store: store, cloud: cloud, prof: prof),
      engine.flush(store: store, cloud: cloud, prof: prof),
    ]);
    expect(results.map((r) => r.pushed).reduce((a, b) => a + b), 1);
    expect(cloud.sessions.keys, ['s1']); // pushed exactly once
  });

  group('no server attestation path: flush is endpoint-free', () {
    StudentDeviceDoc attestDev() => StudentDeviceDoc(
          email: 's@univ.edu',
          uid: 'u9',
          pkHex: 'aa',
          name: 'S',
          roll: '1',
          modelVer: 'v',
          platform: 'android',
          org: 'univ.edu',
          attestationLevel: 'FULL',
          attestedAtMillis:
              DateTime.now().toUtc().millisecondsSinceEpoch,
          attestedUntilMillis: DateTime.now()
              .toUtc()
              .add(const Duration(days: 80))
              .millisecondsSinceEpoch,
        );

    test('flush with enrolled device: attendance syncs, binding untouched',
        () async {
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      await cloud.claimStudentDevice(doc: attestDev(), installId: 'iA');
      final engine = SyncEngine();
      await engine.saveSessionLocal(store,
          rec('s1', 'CS201', '2026-09-01T10:00:00.000Z', '2026-09-01T10:05:00.000Z'));
      final res =
          await engine.flush(store: store, cloud: cloud, prof: prof);
      expect(res.online, isTrue);
      expect(res.pushed, 1);
      expect(res.remaining, 0);
      // No server re-check exists: the binding's self-asserted
      // level + window pass through the flush byte-identical.
      final binding = (await cloud.fetchStudentDevice('s@univ.edu'))!;
      expect(binding.attestationLevel, 'FULL');
      expect(binding.pkDHex, attestDev().pkDHex);
    });
  });
}
