// Thin sync call-site helpers (Track 4): every screen that used to
// push/pull/rename/delete against CloudSync directly builds its prof
// identity HERE and calls [syncEngine] — call sites stay one-liners and
// the flush discipline lives in SyncEngine, not in widgets.
//
// Mounted discipline: call only from State methods while mounted (the
// provider reads below are synchronous; the store awaits use captured
// objects, never ref-after-await).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';

/// Professor push identity for [syncEngine] calls, or null when local-only
/// (student mode, offline-skipped prof, signed out — the outbox stays
/// queued and flush skips session pushes while still replaying the manual
/// queue). Org falls back to the role cache when the account carries none.
Future<SyncProf?> readSyncProf(WidgetRef ref) async {
  final AuthService auth;
  final DeviceStore store;
  try {
    auth = ref.read(authServiceProvider);
    store = ref.read(deviceStoreProvider);
  } catch (_) {
    return null;
  }
  SignedAccount? acct;
  try {
    acct = auth.current;
  } catch (_) {}
  Map<String, String>? role;
  try {
    role = await store.readRole();
  } catch (_) {}
  String hostName = '';
  try {
    hostName = await store.readHostName();
  } catch (_) {}
  final id = profPushIdentity(
      authEmail: acct?.email,
      authUid: acct?.uid,
      authName: acct?.displayName,
      role: role,
      hostNameFallback: hostName);
  if (id == null) return null;
  final org = resolveMyOrg(acct?.org, role);
  return (uid: id.uid, email: id.email, name: id.name, org: org);
}

/// One-line flush for screens (pull-merge on open, retry buttons).
Future<SyncFlushResult> flushNow(WidgetRef ref) async {
  final DeviceStore store;
  final CloudSync cloud;
  try {
    store = ref.read(deviceStoreProvider);
    cloud = ref.read(cloudSyncProvider);
  } catch (_) {
    return const SyncFlushResult(online: false, remaining: -1);
  }
  final prof = await readSyncProf(ref);
  try {
    return await syncEngine.flush(store: store, cloud: cloud, prof: prof);
  } catch (_) {
    return const SyncFlushResult(online: false, remaining: -1);
  }
}
