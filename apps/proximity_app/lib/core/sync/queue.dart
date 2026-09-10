// Offline manual-add queue: replay/apply order + single-flight guard.
// widget keeps only the UI and calls [processPendingAdds] (same signature);
// bodies here are verbatim moves.
library;

import 'dart:async';

import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

import '../../design/tokens.dart';
import 'cloud_api.dart';
import 'directory.dart';
import 'org.dart';
import 'store/store_base.dart';

/// One offline manual-add task, waiting for internet to resolve the ID
/// against the student directory and land on its session record.
class PendingManualAdd {
  final String course;
  final String sessionId; // '' when queued from a live (unsaved) visit
  final String roll;
  final String name;
  final String email;
  final String createdAtIso;
  final String org; // prof org at enqueue (see orgOf), '' = legacy
  const PendingManualAdd(
      {required this.course,
      required this.sessionId,
      required this.roll,
      this.name = '',
      this.email = '',
      required this.createdAtIso,
      this.org = ''});

  Map<String, dynamic> toJson() => {
        'course': course,
        'sessionId': sessionId,
        'roll': roll,
        'name': name,
        'email': email,
        'createdAtIso': createdAtIso,
        'org': org,
      };

  factory PendingManualAdd.fromJson(Map<String, dynamic> j) =>
      PendingManualAdd(
        course: j['course'] as String? ?? '',
        sessionId: j['sessionId'] as String? ?? '',
        roll: j['roll'] as String? ?? '',
        name: j['name'] as String? ?? '',
        email: j['email'] as String? ?? '',
        createdAtIso: j['createdAtIso'] as String? ?? '',
        org: j['org'] as String? ?? '',
      );
}

/// Shared helper: exact ID match out of a directory hit list.
/// The same roll-exact loop ran in 3 places (live search submit + queue
/// resolution); one helper keeps them consistent.
StudentDirectoryEntry? matchRollExact(
    List<StudentDirectoryEntry> hits, String roll) {
  for (final h in hits) {
    if (h.roll == roll) return h;
  }
  return null;
}

/// Offline queue replay with explicit order and a single-flight guard.
///
/// Replay/apply order (explicit — preserves the offline-first guarantee
/// "nothing is lost, queued actions apply correctly on reconnect"):
///   1. FIFO over the stored queue order ([DeviceStore.readPendingAdds]).
///   2. Per item, in order: exact-roll directory match ([matchRollExact])
///      → locate the target record (exact [PendingManualAdd.sessionId]
///      match first, else the latest record for [PendingManualAdd.course])
///      → skip (leave queued) while a live draft for that course is still
///      open, so replay never races the live tally → apply by marking the
///      student present in EVERY window + names/rolls via
///      [DeviceStore.upsertHistory] (same id: replays are idempotent).
///   3. Unknown rolls, missing targets, live drafts and per-item errors
///      stay queued IN ORIGINAL RELATIVE ORDER; one
///      [DeviceStore.writePendingAdds] persists the remainder at the end.
///
/// Single-flight: one replay runs at a time per [SyncQueue] instance.
/// Concurrent sync passes short-circuit to a remaining-count read instead
/// of interleaving readPendingAdds → upsertHistory → writePendingAdds
/// (lost items). The shared [syncQueue] preserves the old process-wide
/// guard; custom instances guard independently.
class SyncQueue {
  bool _running = false;

  Future<({List<String> resolvedIds, int remaining})> process(
      {required DeviceStore store, required CloudSync cloud}) async {
    if (_running) {
      final items = await store.readPendingAdds();
      return (resolvedIds: const <String>[], remaining: items.length);
    }
    _running = true;
    try {
      return await _replay(store, cloud);
    } finally {
      _running = false;
    }
  }

  Future<({List<String> resolvedIds, int remaining})> _replay(
      DeviceStore store, CloudSync cloud) async {
    var online = false;
    try {
      online = cloud.available &&
          await cloud.isOnline().timeout(const Duration(seconds: 8));
    } catch (_) {
      online = false;
    }
    final items = await store.readPendingAdds();
    if (!online || items.isEmpty) {
      if (items.isNotEmpty) {
        BleLog.log(ProxLogTags.sync,
            'manual queue sync deferred (offline): ${items.length} waiting');
      }
      return (resolvedIds: const <String>[], remaining: items.length);
    }
    final resolvedIds = <String>[];
    final remaining = <Map<String, dynamic>>[];
    for (final raw in items) {
      final item = PendingManualAdd.fromJson(
          Map<String, dynamic>.from(raw as Map));
      var done = false;
      try {
        if (item.roll.isNotEmpty) {
          final history = await store.readHistory();
          ClassRecord? target;
          if (item.sessionId.isNotEmpty) {
            for (final r in history) {
              if (r.id == item.sessionId) {
                target = r;
                break;
              }
            }
          }
          target ??= _latestCourseRecord(history, item.course);
          // Org gate: a queued add only lands on a session in its own org.
          // Legacy ('' either side) still resolves locally.
          if (target != null &&
              !recordInMyOrg(target, item.org)) {
            BleLog.log(ProxLogTags.sync,
                'manual queue skip cross-org ${item.roll} (session ${target.org} vs queued ${item.org})');
          } else if (target != null) {
            final hits = await cloud.searchStudents(
                rollPrefix: item.roll, org: item.org);
            final match = matchRollExact(hits, item.roll);
            if (match != null) {
              final m = match;
              // Cross-domain directory hit never lands (defense in depth:
              // the org-scoped query already filters, this holds for fakes
              // and legacy rows).
              if (m.org.isNotEmpty &&
                  target.org.isNotEmpty &&
                  m.org != target.org) {
                BleLog.log(ProxLogTags.sync,
                    'manual queue skip cross-org hit ${m.email} (${m.org} vs ${target.org})');
              } else {
                // A live draft for this course means the visit is still open —
                // leave the item queued rather than racing the live tally.
                var live = false;
                try {
                  live = item.course.isNotEmpty &&
                      await store.readSession(item.course) != null;
                } catch (_) {}
                if (!live) {
                  final email = m.email.toLowerCase();
                  final names = Map<String, String>.from(target.names)
                    ..[email] = m.name;
                  final rolls = Map<String, String>.from(target.rolls)
                    ..[email] = m.roll;
                  final windows = [
                    for (final w in target.windows)
                      Map<String, bool>.from(w)..[email] = true
                  ];
                  await store.upsertHistory(ClassRecord(
                    id: target.id,
                    courseId: target.courseId,
                    classLabel: target.classLabel,
                    dateIso: target.dateIso,
                    timestampIso: target.timestampIso,
                    startIso: target.startIso,
                    windows: windows,
                    names: names,
                    rolls: rolls,
                    org: target.org,
                  ));
                  resolvedIds.add(target.id);
                  done = true;
                }
              }
            }
          }
        }
      } catch (_) {
        done = false;
      }
      if (!done) remaining.add(raw);
    }
    BleLog.log(ProxLogTags.sync,
        'manual queue sync: ${resolvedIds.length} resolved, ${remaining.length} remaining');
    await store.writePendingAdds(remaining);
    return (resolvedIds: resolvedIds, remaining: remaining.length);
  }
}

/// Shared single-flight instance behind [processPendingAdds].
final syncQueue = SyncQueue();

/// Applies queued offline manual adds: resolves each roll against the
/// online directory and marks the student present on its session record.
/// Runs wherever the professor syncs (records page open); live visits skip
/// applying while their draft is still open (the professor is present and
/// adds directly) — those items wait for the next sync.
/// Returns the resolved record ids (the caller pushes them to the cloud —
/// they already exist there, so a plain id-diff merge would skip them)
/// plus the still-pending count.
Future<({List<String> resolvedIds, int remaining})> processPendingAdds(
        {required DeviceStore store, required CloudSync cloud}) =>
    syncQueue.process(store: store, cloud: cloud);

ClassRecord? _latestCourseRecord(List<ClassRecord> history, String course) {
  ClassRecord? best;
  for (final r in history) {
    final c = r.courseId.isNotEmpty ? r.courseId : r.classLabel;
    if (course.isNotEmpty && c != course) continue;
    if (best == null ||
        r.timestampIso.compareTo(best.timestampIso) > 0) {
      best = r;
    }
  }
  return best;
}
