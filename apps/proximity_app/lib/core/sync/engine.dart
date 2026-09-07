// SyncEngine: offline-first cloud sync-on-reconnect (Track 4 §4).
//
// Single-flight flush owned HERE (no wrapper-only modules): every screen
// that used to push/pull/rename/delete against CloudSync directly now calls
// [flush], [saveSessionLocal]/[deleteSessionsLocal]/[renameCourseLocal] or
// [noteLocalSave] and stays thin. Reuses mergeHistories/sessionToDoc (via
// pushSession), SyncQueue discipline (single-flight + remainder-rewrite at
// end), ProxCrypto (untouched) and the org helpers (outbox entries carry
// org; pulls filter org).
//
// Durable outbox (DeviceStore): pendingSessions (full ClassRecord snapshots
// keyed by record id + per-entry attempts/nextRetryAt) + the existing
// pendingAdds manual queue + tombstones (deletes win over older upserts).
// Every local mutation upserts the outbox in the same call as the history
// write (sequential best-effort; a crash between the two heals on the next
// mutation of that record, which re-enqueues it).
//
// Idempotency: doc id = ClassRecord.id, set(merge:true) server-side,
// timestampIso monotonic (union merge takes max, never goes backwards), so
// retries and dropped-mid-sync replays converge without duplicates.
// Ordering: per-course FIFO by startIso then timestampIso (PendingSession.
// order). Pushes union-merge-before-push (window maps + names/rolls
// additive). Retry: per-entry exp backoff with jitter (5s -> 1min -> 15min
// cap, nextRetryAt persisted). Partial failure: acked entries are removed,
// the remainder is rewritten once at the end — local state is never
// mutated per-entry mid-flush.
//
// Triggers: connectivity-return edge (Firestore Source.server probe via
// CloudSync.isOnline is ground truth; the platform hint only wakes a ~5s
// debounced probe) + app resume ([onAppResume]) + post-live-save hook
// ([noteLocalSave]) + 15min backstop ([startBackstop]) while the outbox is
// non-empty. Unsynced badge reads [pendingCount] (N pending). Offline->
// online edges log SYNC lines (never silent).
library;

import 'dart:async';
import 'dart:math';

import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

import '../../design/tokens.dart';
import 'cloud_api.dart';
import 'org.dart';
import 'queue.dart';
import 'sessions.dart';
import 'store/store_base.dart';

/// Professor push identity for a flush (null = local-only: student mode,
/// offline-skipped prof, signed out — outbox stays queued, queue replays).
typedef SyncProf = ({String uid, String email, String name, String org});

/// Result of one flush (single-flight: concurrent callers get the remaining
/// count without interleaving, same discipline as SyncQueue).
class SyncFlushResult {
  final bool online;
  final int pushed;
  final int deleted;
  final int resolvedQueue;
  final int remaining;
  const SyncFlushResult(
      {required this.online,
      this.pushed = 0,
      this.deleted = 0,
      this.resolvedQueue = 0,
      this.remaining = 0});
}

/// Cap on durable tombstones (oldest evicted first).
const int kTombstoneCap = 500;

/// Per-entry retry backoff with jitter: 5s -> 1min -> 15min cap.
/// [attempts] counts CONSECUTIVE failures of that entry.
Duration syncBackoffFor(int attempts, {Random? rng}) {  const bases = [5, 60, 900];
  final baseSecs = bases[attempts.clamp(0, 2)];
  final r = rng ?? Random.secure();
  final jitteredMs = (baseSecs * 1000 * (0.75 + r.nextDouble() * 0.5)).round();
  return Duration(milliseconds: jitteredMs);
}

class SyncEngine {
  /// Test seam: override the clock (backoff math + due checks).
  DateTime Function() nowUtc = () => DateTime.now().toUtc();

  bool _running = false;

  /// Last probed online state (connectivity-return EDGE detection).
  /// null = never probed this process (first online probe does not log an
  /// edge — only a real offline->online return does).
  bool? _lastOnline;

  Timer? _debounce;
  Timer? _backstop;

  /// Total unsynced work: outbox sessions + manual queue + tombstones.
  /// Drives the unsynced badge (N pending).
  Future<int> pendingCount(DeviceStore store) async {
    final s = await store.readPendingSessions();
    final a = await store.readPendingAdds();
    final t = await store.readTombstones();
    return s.length + a.length + t.length;
  }

  /// Local session save: history write + outbox upsert in one call.
  /// Callers use this INSTEAD of raw upsertHistory so every mutation is
  /// durable for the next flush (post-live-save hook calls [noteLocalSave],
  /// which is this + a best-effort flush).
  Future<void> saveSessionLocal(DeviceStore store, ClassRecord record) async {
    await store.upsertHistory(record);
    final outbox = await store.readPendingSessions();
    final entry = PendingSession(
      id: record.id,
      record: record,
      org: record.org,
      updatedAtIso: nowUtc().toIso8601String(),
    );
    final idx = outbox.indexWhere((e) => (e['id'] as String? ?? '') == record.id);
    if (idx < 0) {
      outbox.add(entry.toJson());
    } else {
      // Fresh edit resets retry state: the new snapshot is due now.
      outbox[idx] = entry.toJson();
    }
    await store.writePendingSessions(outbox);
    BleLog.log(ProxLogTags.sync,
        'outbox queued ${record.id} (${outbox.length} sessions pending)');
  }

  /// Local delete: history + outbox drop + tombstone in one call, so the
  /// delete propagates on flush and wins over older upserts everywhere.
  /// [courseOf] resolves the course label per id for the tombstone note.
  Future<int> deleteSessionsLocal(DeviceStore store, List<String> ids,
      {String org = '', String Function(String id)? courseOf}) async {
    final removed = await store.deleteSessions(ids);
    if (removed == 0) return 0;
    final set = ids.toSet();
    final outbox = await store.readPendingSessions();
    outbox.removeWhere((e) => set.contains(e['id'] as String? ?? ''));
    await store.writePendingSessions(outbox);
    final tombs = await store.readTombstones();
    final have = {for (final t in tombs) t['id'] as String? ?? ''};
    final at = nowUtc().toIso8601String();
    for (final id in set) {
      if (have.contains(id)) continue;
      tombs.add(SessionTombstone(
              id: id,
              deletedAtIso: at,
              org: org,
              course: courseOf?.call(id) ?? '')
          .toJson());
    }
    // Bounded: tombstones converge other devices over time; evict the
    // oldest past the cap so one device's lifetime deletes stay small.
    tombs.sort((a, b) => (a['deletedAtIso'] as String? ?? '')
        .compareTo(b['deletedAtIso'] as String? ?? ''));
    while (tombs.length > kTombstoneCap) {
      tombs.removeAt(0);
    }
    await store.writeTombstones(tombs);
    BleLog.log(ProxLogTags.sync,
        'outbox tombstoned ${set.length} (${tombs.length} deletes pending)');
    return removed;
  }

  /// Local course rename: history migrate + re-enqueue every touched record
  /// with a monotonic timestamp bump (so the rename converges on union
  /// merge instead of resurrecting the old name from a newer-timestamped
  /// copy on another device). Cloud needs no separate rename batch: the
  /// same doc ids push with the new courseId on flush.
  Future<bool> renameCourseLocal(
      DeviceStore store, String oldName, String newName) async {
    final ok = await store.renameCourse(oldName, newName);
    if (!ok) return false;
    final nowIso = nowUtc().toIso8601String();
    final history = await store.readHistory();
    for (final r in history) {
      final course = r.courseId.isNotEmpty ? r.courseId : r.classLabel;
      if (course != newName) continue;
      final bumped = r.timestampIso.compareTo(nowIso) < 0
          ? ClassRecord(
              id: r.id,
              courseId: r.courseId,
              classLabel: r.classLabel,
              dateIso: r.dateIso,
              timestampIso: nowIso,
              startIso: r.startIso,
              windows: [for (final w in r.windows) Map<String, bool>.from(w)],
              names: Map<String, String>.from(r.names),
              rolls: Map<String, String>.from(r.rolls),
              org: r.org,
            )
          : r;
      await store.upsertHistory(bumped);
      final outbox = await store.readPendingSessions();
      final entry = PendingSession(
        id: bumped.id,
        record: bumped,
        org: bumped.org,
        updatedAtIso: nowIso,
      );
      final idx =
          outbox.indexWhere((e) => (e['id'] as String? ?? '') == bumped.id);
      if (idx < 0) {
        outbox.add(entry.toJson());
      } else {
        outbox[idx] = entry.toJson();
      }
      await store.writePendingSessions(outbox);
    }
    BleLog.log(
        ProxLogTags.sync, 'outbox rename $oldName → $newName (re-queued)');
    return true;
  }

  /// Post-live-save hook: durable save + best-effort flush (never throws —
  /// offline just leaves the outbox for the reconnect edge).
  Future<void> noteLocalSave(
      {required DeviceStore store,
      required CloudSync cloud,
      SyncProf? prof,
      required ClassRecord record}) async {
    try {
      await saveSessionLocal(store, record);
    } catch (e) {
      BleLog.log(ProxLogTags.sync, 'outbox save FAILED: $e');
      return;
    }
    unawaited(flush(store: store, cloud: cloud, prof: prof));
  }

  /// Single-flight flush: tombstones -> outbox sessions (per-course FIFO,
  /// union-merge-before-push) -> manual queue (SyncQueue) -> pull + union
  /// converge. Partial failure: acked entries drop, the remainder (with
  /// bumped attempts/nextRetryAt) is rewritten ONCE at the end.
  Future<SyncFlushResult> flush(
      {required DeviceStore store,
      required CloudSync cloud,
      SyncProf? prof}) async {
    if (_running) {
      return SyncFlushResult(
          online: _lastOnline ?? true,
          remaining: await pendingCount(store));
    }
    _running = true;
    try {
      return await _flushInner(store: store, cloud: cloud, prof: prof);
    } finally {
      _running = false;
    }
  }

  Future<SyncFlushResult> _flushInner(
      {required DeviceStore store,
      required CloudSync cloud,
      SyncProf? prof}) async {
    final now = nowUtc();
    var online = false;
    try {
      online = cloud.available &&
          await cloud.isOnline().timeout(const Duration(seconds: 8));
    } catch (_) {
      online = false;
    }
    if (!online) {
      final pending = await pendingCount(store);
      if (_lastOnline == true || _lastOnline == null) {
        BleLog.log(ProxLogTags.sync,
            'SYNC offline ($pending pending) — outbox durable, will flush on reconnect');
      }
      _lastOnline = false;
      return SyncFlushResult(online: false, remaining: pending);
    }
    // Legacy discovery + migration run before the empty check: the
    // org-filtered pulls below can never see pre-org cloud docs, so an
    // unfiltered profUid-only pull discovers them while the backfill
    // gate is open — otherwise untouched cloud legacy would strand the
    // missingOrg() rules grace open forever. Discovery merges into
    // local history; the backfill stamps on this same flush.
    var discoveredLegacy = 0;
    if (prof != null && !(await store.readOrgBackfillComplete())) {
      discoveredLegacy = await _discoverLegacyCloud(store, cloud, prof);
    }
    // Migration runs before the empty check: legacy org='' history must
    // enqueue (and push) even when the outbox starts empty.
    if (prof != null) {
      await _backfillLegacyOrg(store, prof, now);
    }
    final pending = await pendingCount(store);
    if (_lastOnline == false) {
      BleLog.log(ProxLogTags.sync,
          'SYNC offline→online (server probe ok, $pending pending) — flushing');
    }
    _lastOnline = true;
    if (pending == 0 && prof != null) {
      // Still converge pulls (other devices may have written meanwhile).
      await _converge(store, cloud, prof);
      await _maybeSignalBackfillComplete(store, discoveredLegacy);
      return const SyncFlushResult(online: true);
    }

    var pushed = 0;
    var deleted = 0;
    // Tombstones first: a delete concurrent with an edit of the same id
    // must land before the upsert it should (or should not) beat — the
    // timestamp comparison decides, and cloud order matches local order.
    deleted = await _flushTombstones(store, cloud, prof, now);
    pushed += await _flushSessions(store, cloud, prof, now);
    // Manual queue (existing SyncQueue discipline, reused verbatim).
    var resolvedQueue = 0;
    try {
      final q = await processPendingAdds(store: store, cloud: cloud);
      resolvedQueue = q.resolvedIds.length;
      if (resolvedQueue > 0 && prof != null) {
        // Resolved records already exist in the cloud, so the outbox path
        // would skip them — push the merged rows explicitly (idempotent).
        final fresh = await store.readHistory();
        for (final rid in q.resolvedIds) {
          for (final r in fresh) {
            if (r.id != rid) continue;
            try {
              await cloud
                  .pushSession(
                      profUid: prof.uid,
                      profEmail: prof.email,
                      profName: prof.name,
                      record: r,
                      profOrg: prof.org)
                  .timeout(const Duration(seconds: 10));
              pushed++;
            } catch (e) {
              // Leave for the outbox: enqueue due-later so the next flush
              // retries instead of dropping a resolved mark.
              await _enqueueRetry(store, r, now);
              BleLog.log(ProxLogTags.sync,
                  'queue-resolved push deferred ${r.id}: $e');
            }
          }
        }
      }
      if (q.resolvedIds.isNotEmpty || q.remaining > 0) {
        BleLog.log(ProxLogTags.sync,
            'manual queue: ${q.resolvedIds.length} resolved, ${q.remaining} remaining');
      }
    } catch (e) {
      BleLog.log(ProxLogTags.sync, 'manual queue flush FAILED: $e');
    }
    if (prof != null) {
      await _converge(store, cloud, prof);
      await _maybeSignalBackfillComplete(store, discoveredLegacy);
    }
    final remaining = await pendingCount(store);
    BleLog.log(ProxLogTags.sync,
        'SYNC flush done: $pushed pushed, $deleted deleted, $resolvedQueue queue-resolved, $remaining remaining');
    return SyncFlushResult(
        online: true,
        pushed: pushed,
        deleted: deleted,
        resolvedQueue: resolvedQueue,
        remaining: remaining);
  }

  /// Deletes due tombstones one id at a time (per-entry failure isolation);
  /// acked ids drop, failures bump attempts/nextRetryAt, remainder written
  /// once at the end. No prof identity => local-only, everything stays.
  Future<int> _flushTombstones(DeviceStore store, CloudSync cloud,
      SyncProf? prof, DateTime now) async {
    if (prof == null) return 0;
    final raw = await store.readTombstones();
    if (raw.isEmpty) return 0;
    var deleted = 0;
    final keep = <Map<String, dynamic>>[];
    for (final t in raw) {
      SessionTombstone tomb;
      try {
        tomb = SessionTombstone.fromJson(Map<String, dynamic>.from(t));
      } catch (_) {
        continue; // poison entry: drop, history already converged locally
      }
      if (tomb.id.isEmpty) continue;
      final attempts = (t['attempts'] as num?)?.toInt() ?? 0;
      if (!_due(t['nextRetryAtIso'] as String? ?? '', now)) {
        keep.add(t);
        continue;
      }
      try {
        await cloud
            .deleteSessionsCloud(profUid: prof.uid, ids: [tomb.id]).timeout(
                const Duration(seconds: 10));
        deleted++;
      } catch (e) {
        keep.add({
          ...t,
          'attempts': attempts + 1,
          'nextRetryAtIso':
              now.add(syncBackoffFor(attempts)).toIso8601String(),
        });
        BleLog.log(
            ProxLogTags.sync, 'tombstone delete deferred ${tomb.id}: $e');
      }
    }
    await store.writeTombstones(keep);
    return deleted;
  }

  /// Migration: owner backfill of legacy org='' history records once
  /// (idempotent — stamped records never match again). Backfilled rows
  /// enqueue due-now so the stamp itself propagates on this flush.
  ///
  /// Unfiltered legacy discovery (Track 1 grace sunset): returns the
  /// number of pre-org ('') cloud sessions seen, merged into local
  /// history for stamping (-1 when the pull failed — unknown, never a
  /// completion signal). Skipped once the gate flag fires (see
  /// [_maybeSignalBackfillComplete]) so steady-state flushes pay no
  /// extra query.
  Future<int> _discoverLegacyCloud(
      DeviceStore store, CloudSync cloud, SyncProf prof) async {
    List<ClassRecord> remote;
    try {
      remote = await cloud
          .pullProfSessions(prof.uid)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      BleLog.log(ProxLogTags.sync, 'legacy discovery pull FAILED: $e');
      return -1;
    }
    final legacy = [for (final r in remote) if (r.org.isEmpty) r];
    if (legacy.isEmpty) return 0;
    final local = await store.readHistory();
    final tombRaw = await store.readTombstones();
    final tombs = <SessionTombstone>[];
    for (final t in tombRaw) {
      try {
        tombs.add(SessionTombstone.fromJson(Map<String, dynamic>.from(t)));
      } catch (_) {}
    }
    await store.writeHistory(
        mergeHistoriesUnion(local, legacy, tombstones: tombs));
    BleLog.log(ProxLogTags.sync,
        'legacy discovery: ${legacy.length} pre-org cloud sessions merged for stamping');
    return legacy.length;
  }

  /// Per-device half of the missingOrg() rules-removal gate: fires once
  /// when a full online flush leaves zero org-less records locally after
  /// an unfiltered cloud pull also showed zero. Removal itself is a
  /// human deploy gated on this signal PLUS the org-wide console check
  /// (see firestore.rules) — never on judgment alone.
  Future<void> _maybeSignalBackfillComplete(
      DeviceStore store, int discoveredLegacy) async {
    if (discoveredLegacy != 0) return;
    if (await store.readOrgBackfillComplete()) return;
    final history = await store.readHistory();
    if (history.any((r) => r.org.isEmpty)) return;
    await store.writeOrgBackfillComplete();
    BleLog.log(ProxLogTags.sync,
        'org backfill COMPLETE: no org-less records locally or in the last full cloud pull — per-device gate done. Remove missingOrg() ONLY after the org-wide console check (classSessions/studentDevices/studentDirectory/deviceInstalls where org missing) returns zero, then `firebase deploy --only firestore:rules`.');
  }
  Future<void> _backfillLegacyOrg(
      DeviceStore store, SyncProf prof, DateTime now) async {
    final ownerOrg = prof.org.isNotEmpty ? prof.org : orgOf(prof.email);
    if (ownerOrg.isEmpty) return;
    final history = await store.readHistory();
    final legacy = [for (final r in history) if (r.org.isEmpty) r];
    if (legacy.isEmpty) return;
    final outbox = await store.readPendingSessions();
    for (final r in legacy) {
      final withOrg = ClassRecord(
        id: r.id,
        courseId: r.courseId,
        classLabel: r.classLabel,
        dateIso: r.dateIso,
        timestampIso: r.timestampIso,
        startIso: r.startIso,
        windows: [for (final w in r.windows) Map<String, bool>.from(w)],
        names: Map<String, String>.from(r.names),
        rolls: Map<String, String>.from(r.rolls),
        org: ownerOrg,
      );
      await store.upsertHistory(withOrg);
      if (!outbox.any((e) => (e['id'] as String? ?? '') == r.id)) {
        outbox.add(PendingSession(
          id: r.id,
          record: withOrg,
          org: ownerOrg,
          updatedAtIso: now.toIso8601String(),
        ).toJson());
      }
    }
    await store.writePendingSessions(outbox);
    BleLog.log(ProxLogTags.sync,
        'org backfill: stamped ${legacy.length} legacy sessions ($ownerOrg)');
  }

  /// Pushes due outbox sessions per-course FIFO with union-merge-before-push
  /// (additive windows/names/rolls vs the cloud copy). Cross-org entries
  /// never push (refused + kept, same gate as the live join path). Acked
  /// entries drop; failures bump attempts/nextRetryAt; the remainder is
  /// rewritten once at the end in original relative order.
  Future<int> _flushSessions(DeviceStore store, CloudSync cloud,
      SyncProf? prof, DateTime now) async {
    if (prof == null) return 0;
    // Pull once for union-merge-before-push (org-filtered when stamped).
    var cloudById = <String, ClassRecord>{};
    try {
      final cloudSessions = await cloud.pullProfSessions(prof.uid,
          org: prof.org.isNotEmpty ? prof.org : '');
      cloudById = {for (final r in cloudSessions) r.id: r};
    } catch (e) {
      BleLog.log(ProxLogTags.sync, 'pre-push pull FAILED: $e');
    }
    var raw = await store.readPendingSessions();
    final ownerOrg = prof.org.isNotEmpty ? prof.org : orgOf(prof.email);
    if (raw.isEmpty) return 0;
    // Heal strays: history rows missing from the outbox (crash between the
    // history write and the outbox upsert) that the cloud lacks or holds
    // older — enqueue due-now so this flush converges them.
    final have = {for (final e in raw) e['id'] as String? ?? ''};
    final history = await store.readHistory();
    var healed = 0;
    for (final r in history) {
      if (have.contains(r.id)) continue;
      final c = cloudById[r.id];
      if (c == null || r.timestampIso.compareTo(c.timestampIso) > 0) {
        raw.add(PendingSession(
          id: r.id,
          record: r,
          org: r.org,
          updatedAtIso: now.toIso8601String(),
        ).toJson());
        healed++;
      }
    }
    if (healed > 0) {
      BleLog.log(
          ProxLogTags.sync, 'outbox healed $healed strays from history');
    }
    final parsed = <PendingSession>[];
    final poison = <String>{};
    for (final e in raw) {
      try {
        parsed.add(
            PendingSession.fromJson(Map<String, dynamic>.from(e as Map)));
      } catch (_) {
        poison.add(e['id'] as String? ?? '');
        BleLog.log(ProxLogTags.sync,
            'outbox poison entry dropped (${e['id'] ?? 'no-id'} — history keeps the data)');
      }
    }
    // Backfill legacy org on the parsed entries (rewritten below).
    for (var i = 0; i < parsed.length; i++) {
      final p = parsed[i];
      if (p.org.isEmpty && ownerOrg.isNotEmpty) {
        final rec = p.record.org.isNotEmpty
            ? p.record
            : ClassRecord(
                id: p.record.id,
                courseId: p.record.courseId,
                classLabel: p.record.classLabel,
                dateIso: p.record.dateIso,
                timestampIso: p.record.timestampIso,
                startIso: p.record.startIso,
                windows: p.record.windows,
                names: p.record.names,
                rolls: p.record.rolls,
                org: ownerOrg,
              );
        parsed[i] = PendingSession(
          id: p.id,
          record: rec,
          org: ownerOrg,
          attempts: p.attempts,
          nextRetryAtIso: p.nextRetryAtIso,
          updatedAtIso: p.updatedAtIso,
        );
      }
    }
    final due = parsed.where((p) => p.due(now)).toList()
      ..sort(PendingSession.order);
    final acked = <String>{};
    for (final p in due) {
      // Org drill: a queued entry only lands in its own org. Legacy (''
      // either side) still resolves locally.
      if (p.org.isNotEmpty &&
          prof.org.isNotEmpty &&
          p.org != prof.org) {
        BleLog.log(ProxLogTags.sync,
            'outbox skip cross-org ${p.id} (${p.org} vs ${prof.org}) — kept');
        continue;
      }
      final cloudRec = cloudById[p.id];
      final merged =
          cloudRec == null ? p.record : unionMergeRecords(cloudRec, p.record);
      try {
        await cloud
            .pushSession(
                profUid: prof.uid,
                profEmail: prof.email,
                profName: prof.name,
                record: merged,
                profOrg: prof.org)
            .timeout(const Duration(seconds: 10));
        acked.add(p.id);
      } catch (e) {
        BleLog.log(ProxLogTags.sync, 'outbox push deferred ${p.id}: $e');
        final idx = parsed.indexWhere((x) => x.id == p.id);
        if (idx >= 0) {
          final cur = parsed[idx];
          parsed[idx] = PendingSession(
            id: cur.id,
            record: cur.record,
            org: cur.org,
            attempts: cur.attempts + 1,
            nextRetryAtIso:
                now.add(syncBackoffFor(cur.attempts)).toIso8601String(),
            updatedAtIso: cur.updatedAtIso,
          );
        }
      }
    }
    // Remainder rewritten ONCE at the end, original relative order minus
    // acked/poison (partial-failure discipline — never per-entry writes).
    final rest = [
      for (final p in parsed)
        if (!acked.contains(p.id)) p.toJson(),
    ];
    await store.writePendingSessions(rest);
    return acked.length;
  }

  /// Re-enqueues a queue-resolved record for retry (its cloud push failed
  /// after the local marks already landed).
  Future<void> _enqueueRetry(
      DeviceStore store, ClassRecord r, DateTime now) async {
    final outbox = await store.readPendingSessions();
    final idx = outbox.indexWhere((e) => (e['id'] as String? ?? '') == r.id);
    final entry = PendingSession(
      id: r.id,
      record: r,
      org: r.org,
      attempts: 1,
      nextRetryAtIso: now.add(syncBackoffFor(0)).toIso8601String(),
      updatedAtIso: now.toIso8601String(),
    );
    if (idx < 0) {
      outbox.add(entry.toJson());
    } else {
      outbox[idx] = entry.toJson();
    }
    await store.writePendingSessions(outbox);
  }

  /// Pull + union converge (other devices' visits land here; tombstones
  /// hold deletes). Best-effort — failures keep local data untouched.
  Future<void> _converge(
      DeviceStore store, CloudSync cloud, SyncProf prof) async {
    try {
      final local = await store.readHistory();
      final remote = await cloud.pullProfSessions(prof.uid,
          org: prof.org.isNotEmpty ? prof.org : '');
      final tombRaw = await store.readTombstones();
      final tombs = <SessionTombstone>[];
      for (final t in tombRaw) {
        try {
          tombs.add(SessionTombstone.fromJson(Map<String, dynamic>.from(t)));
        } catch (_) {}
      }
      final merged =
          mergeHistoriesUnion(local, remote, tombstones: tombs);
      await store.writeHistory(merged);
      for (final r in merged) {
        final course = r.courseId.isNotEmpty ? r.courseId : r.classLabel;
        if (course.isNotEmpty) {
          try {
            await store.addCourse(course);
          } catch (_) {}
        }
      }
    } catch (e) {
      BleLog.log(ProxLogTags.sync, 'converge pull FAILED: $e');
    }
  }

  bool _due(String nextRetryAtIso, DateTime now) {
    if (nextRetryAtIso.isEmpty) return true;
    try {
      return !DateTime.parse(nextRetryAtIso).toUtc().isAfter(now);
    } catch (_) {
      return true;
    }
  }

  /// Connectivity-hint entry: the platform hint is HINT-ONLY — a
  /// return-to-online hint schedules a ~5s debounced server probe
  /// ([CloudSync.isOnline] over Source.server is ground truth), and only
  /// an offline->online EDGE flushes. An offline hint just marks the edge
  /// (no probe burned on a dead radio).
  void onConnectivityHint(bool hintOnline,
      {required DeviceStore store,
      required CloudSync cloud,
      FutureOr<SyncProf?> Function()? profOf}) {
    _debounce?.cancel();
    if (!hintOnline) {
      _lastOnline = false;
      return;
    }
    _debounce = Timer(const Duration(seconds: 5), () async {
      var online = false;
      try {
        online = cloud.available &&
            await cloud.isOnline().timeout(const Duration(seconds: 8));
      } catch (_) {
        online = false;
      }
      if (online && _lastOnline == false) {
        BleLog.log(ProxLogTags.sync,
            'SYNC connectivity returned (hint + server probe) — flushing');
        SyncProf? prof;
        try {
          prof = await profOf?.call();
        } catch (_) {}
        unawaited(flush(store: store, cloud: cloud, prof: prof));
      }
      _lastOnline = online;
    });
  }

  /// App-resume entry: flush best-effort (the flush itself probes server
  /// truth, so a resume while still offline is one cheap probe + log).
  void onAppResume(
      {required DeviceStore store,
      required CloudSync cloud,
      FutureOr<SyncProf?> Function()? profOf}) {
    unawaited(_resumeFlush(store: store, cloud: cloud, profOf: profOf));
  }

  Future<void> _resumeFlush(
      {required DeviceStore store,
      required CloudSync cloud,
      FutureOr<SyncProf?> Function()? profOf}) async {
    SyncProf? prof;
    try {
      prof = await profOf?.call();
    } catch (_) {}
    try {
      await flush(store: store, cloud: cloud, prof: prof);
    } catch (_) {}
  }

  /// 15min backstop while the outbox is non-empty (covers missed edges:
  /// no platform hook fired, app left open). Call once per app start;
  /// [stopBackstop] on dispose/tests.
  void startBackstop(
      {required DeviceStore store,
      required CloudSync cloud,
      FutureOr<SyncProf?> Function()? profOf,
      Duration interval = const Duration(minutes: 15)}) {
    _backstop?.cancel();
    _backstop = Timer.periodic(interval, (_) async {
      try {
        if (await pendingCount(store) > 0) {
          BleLog.log(ProxLogTags.sync, 'SYNC backstop tick — flushing');
          SyncProf? prof;
          try {
            prof = await profOf?.call();
          } catch (_) {}
          await flush(store: store, cloud: cloud, prof: prof);
        }
      } catch (_) {}
    });
  }

  void stopBackstop() {
    _backstop?.cancel();
    _backstop = null;
  }

  void dispose() {
    _debounce?.cancel();
    stopBackstop();
  }
}

/// Shared single-flight engine behind the thin call sites.
final syncEngine = SyncEngine();
