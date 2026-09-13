// Offline-capable CRL snapshot cache for Android attestation status
// (PROXIMITY_SECURITY.md §2 residual; PROXIMITY_DESIGN.md §3 "Remains").
//
// Source: https://android.googleapis.com/attestation/status — Google's
// published attestation-certificate status list (revoked/suspended serials).
// Consulted Firestore-INDEPENDENTLY over plain HTTPS (no Firestore read, no
// Cloud Function, no custom backend — Spark-free; the offline professor gate
// in protocol `verifyAttestationChainPin` cannot consult it, so this cache
// is the only CRL story until a backend exists).
//
// Lifecycle (offline-first, never blocks marking):
//   - fetch-once-when-online: `refreshBestEffort()` from one-time online
//     setup only (enrollment `upload()` + host `_startHostingInner()`).
//     Best-effort, bounded timeout, never throws — a failure keeps the old
//     snapshot and marking proceeds offline.
//   - persist: raw body + `fetchedAt` millis in SharedPreferences
//     (`prox.revocation.v1.*`); TTL 7d (`kRevocationCacheTtl`).
//   - fail-open: stale/missing/offline NEVER blocks — `flagFor()` surfaces
//     `revocation-stale` for professor review instead (alongside
//     `audit-double-pkD` from `claim.dart findDoublePkD` + the ticket anomaly
//     flags; the roster keeps presence, review happens post-hoc).
//
// Serial matching (`isSerialRevoked`): lenient JSON scan of the `entries`
// map (serial-hex keys, case-insensitive, leading-zero-insensitive; status
// containing REVOK/SUSPEND counts as revoked). X.509 serial extraction from
// chain DER is pure-Dart offline (`chain_serial.dart`: Certificate/TBS
// parse via asn1lib, never throws) — `reviewFlagsForChain[Hex]` extracts
// leaf/all serials and delegates to `reviewFlagsFor`/`isSerialRevoked`.
// Unparseable chains degrade to the freshness flag (fail-open), never to an
// accusation. Unknown/garbage bodies never report revoked (fail-open),
// only stale.
//
// What this file does NOT do (other tracks own it — do not expand here):
//   - device_binding signature math / chain-pin gates (sec-protocol).
//   - Firestore `studentDevices` writes or rules (sec-sync).
//   - App Check / Play Integrity API (sec-integrity).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:proximity_ble/ble.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chain_serial.dart';

/// Google's published attestation status list (revoked/suspended cert
/// serials). Fetched directly — never via Firestore/Functions.
const kAttestationStatusUrl =
    'https://android.googleapis.com/attestation/status';

/// Snapshot freshness window: refetch at most once per 7d of online setup.
/// A snapshot older than this (or missing) is served stale + flagged, never
/// blocking.
const kRevocationCacheTtl = Duration(days: 7);

/// Advisory flag surfaced when the snapshot is missing/stale/offline.
/// Professor review groups it with `audit-double-pkD` + ticket anomaly
/// flags; presence is never changed offline because of it.
const kRevocationStaleFlag = 'revocation-stale';

/// Advisory flag when a chain serial matches a revoked entry in a FRESH
/// snapshot. Only ever set on fresh snapshots (stale ones report the stale
/// flag instead — a stale CRL must not accuse).
const kRevocationRevokedFlag = 'revocation-revoked';

/// HTTPS fetch budget for the one-time online refresh: a hung fetch must
/// never stall enrollment/host setup past this (degrades to stale-cached).
const kRevocationFetchBudget = Duration(seconds: 10);

/// Cap on the persisted status body (the published list is small; a huge
/// body is truncated-fail-open: keep first bytes, still parseable prefix).
const kRevocationBodyCap = 1024 * 1024;

const _kBodyKey = 'prox.revocation.v1.body';
const _kFetchedAtKey = 'prox.revocation.v1.fetchedAtMillis';

/// One cached CRL snapshot: raw status body + fetch time (UTC).
class RevocationSnapshot {
  /// Raw response body ('' = never fetched).
  final String rawBody;

  /// Fetch time (epoch 0 = never fetched).
  final DateTime fetchedAt;

  const RevocationSnapshot({required this.rawBody, required this.fetchedAt});

  /// Never-fetched snapshot (stale by construction).
  factory RevocationSnapshot.empty() => RevocationSnapshot(
        rawBody: '',
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  bool get isEmpty => rawBody.isEmpty;

  /// True when missing or older than [kRevocationCacheTtl] at [now].
  bool isStale(DateTime now) {
    if (isEmpty) return true;
    final fetchedMs = fetchedAt.toUtc().millisecondsSinceEpoch;
    if (fetchedMs <= 0) return true;
    return now.toUtc().millisecondsSinceEpoch - fetchedMs >
        kRevocationCacheTtl.inMilliseconds;
  }
}

/// Minimal persistence seam (production = SharedPreferences; tests = memory).
abstract class RevocationStore {
  Future<String?> readBody();
  Future<int?> readFetchedAtMillis();
  Future<void> write({required String body, required int fetchedAtMillis});
}

/// SharedPreferences backend (local store, Spark-free, no backend).
class SharedPrefsRevocationStore implements RevocationStore {
  final Future<SharedPreferences> Function() _prefs;

  SharedPrefsRevocationStore(
      [Future<SharedPreferences> Function()? prefsForTest])
      : _prefs = prefsForTest ?? SharedPreferences.getInstance;

  @override
  Future<String?> readBody() async {
    try {
      return (await _prefs()).getString(_kBodyKey);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int?> readFetchedAtMillis() async {
    try {
      return (await _prefs()).getInt(_kFetchedAtKey);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(
      {required String body, required int fetchedAtMillis}) async {
    final prefs = await _prefs();
    await prefs.setString(_kBodyKey, body);
    await prefs.setInt(_kFetchedAtKey, fetchedAtMillis);
  }
}

/// In-memory backend (tests / previews — never shipped state).
class MemoryRevocationStore implements RevocationStore {
  String? body;
  int? fetchedAtMillis;

  @override
  Future<String?> readBody() async => body;

  @override
  Future<int?> readFetchedAtMillis() async => fetchedAtMillis;

  @override
  Future<void> write(
      {required String body, required int fetchedAtMillis}) async {
    this.body = body;
    this.fetchedAtMillis = fetchedAtMillis;
  }
}

/// Offline CRL cache (static helpers over [RevocationStore]).
class RevocationCache {
  RevocationCache._();

  /// Loads the persisted snapshot (empty when never fetched). Never throws.
  static Future<RevocationSnapshot> load({RevocationStore? store}) async {
    final s = store ?? SharedPrefsRevocationStore();
    try {
      final body = await s.readBody() ?? '';
      final ms = await s.readFetchedAtMillis() ?? 0;
      return RevocationSnapshot(
        rawBody: body,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
      );
    } catch (_) {
      return RevocationSnapshot.empty();
    }
  }

  /// Advisory flag for professor review: '' when fresh, else
  /// `revocation-stale`. Pure — the offline review path calls this without
  /// any fetch (never blocks marking).
  static String flagFor(RevocationSnapshot snap, {DateTime? now}) =>
      snap.isStale(now ?? DateTime.now().toUtc()) ? kRevocationStaleFlag : '';

  /// Review flags for one binding: stale flag when the snapshot is
  /// missing/stale; revoked flag when [serialHex] matches a revoked entry
  /// in a FRESH snapshot. Fail-open: stale snapshots report ONLY the stale
  /// flag (never accuse from a stale CRL); empty serials report nothing
  /// beyond staleness. Pure — combine with `findDoublePkD` groups +
  /// ticket anomaly flags on the professor review screen.
  static List<String> reviewFlagsFor(
    RevocationSnapshot snap, {
    DateTime? now,
    String? serialHex,
  }) {
    final at = (now ?? DateTime.now()).toUtc();
    if (snap.isStale(at)) return const [kRevocationStaleFlag];
    final serial = (serialHex ?? '').trim();
    if (serial.isNotEmpty && isSerialRevoked(snap, serial)) {
      return const [kRevocationRevokedFlag];
    }
    return const [];
  }

  /// Review flags for one chain (leaf-first DER, as carried in
  /// `chainDERHex` / `attestationChain`): stale flag when the snapshot is
  /// missing/stale; revoked flag when ANY parseable chain serial matches a
  /// revoked entry in a FRESH snapshot. Fail-open: stale snapshots report
  /// ONLY the stale flag (never accuse from a stale CRL); empty or
  /// unparseable chains report nothing beyond staleness (a fresh snapshot +
  /// no serials is clean — garbage DER never accuses). Pure — the offline
  /// professor review path calls this without any fetch (never blocks
  /// marking). Delegates to [reviewFlagsFor]/[allSerialsHex].
  static List<String> reviewFlagsForChain(
    RevocationSnapshot snap,
    List<Uint8List> certsDer, {
    DateTime? now,
  }) {
    final at = (now ?? DateTime.now()).toUtc();
    if (snap.isStale(at)) return const [kRevocationStaleFlag];
    for (final serial in allSerialsHex(certsDer)) {
      if (isSerialRevoked(snap, serial)) {
        return const [kRevocationRevokedFlag];
      }
    }
    return const [];
  }

  /// Hex-string convenience over [reviewFlagsForChain] for the stored wire
  /// form (leaf-first DER hex). Lenient decode (bad entries skipped,
  /// fail-open); an empty/undecodable chain degrades to [flagFor]
  /// semantics (stale flag iff the snapshot is stale, else clean).
  static List<String> reviewFlagsForChainHex(
    RevocationSnapshot snap,
    List<String> chainHex, {
    DateTime? now,
  }) =>
      reviewFlagsForChain(snap, certsDerFromHexList(chainHex), now: now);

  /// Lenient revoked check over the cached body: parses the `entries` map
  /// (serial-hex keys → {status}) case-insensitively and
  /// leading-zero-insensitively (`'01'` ≡ `'1'` ≡ `'0x01'` — same integer);
  /// any status containing `revok`/`suspend` counts. Falls back to false on
  /// unparseable bodies (fail-open — garbage never accuses; staleness is
  /// the signal there).
  static bool isSerialRevoked(RevocationSnapshot snap, String serialHex) {
    final want = _normSerial(serialHex);
    if (snap.rawBody.isEmpty || want.isEmpty) return false;
    try {
      final doc = jsonDecode(snap.rawBody);
      final entries = doc is Map
          ? (doc['entries'] is Map ? doc['entries'] as Map : doc)
          : null;
      if (entries != null) {
        for (final e in entries.entries) {
          if (_normSerial('${e.key}') != want) continue;
          final status = e.value is Map
              ? '${(e.value as Map)['status'] ?? ''}'.toLowerCase()
              : '$e'.toLowerCase();
          if (status.contains('revok') || status.contains('suspend')) {
            return true;
          }
          return false;
        }
        return false;
      }
    } catch (_) {
      // Fall through to the substring fallback below.
    }
    // Non-JSON bodies: only a joint serial+revoke mention counts (a bare
    // serial echo without a revoke word is not an accusation).
    final body = snap.rawBody.toLowerCase();
    return body.contains(want) &&
        (body.contains('revok') || body.contains('suspend'));
  }

  /// Canonical serial form for CRL comparison: lowercase, no `0x`, leading
  /// zeros trimmed (keeps one digit, so `'0'` stays `'0'` and `''` stays
  /// `''`). Pure — never throws.
  static String _normSerial(String serialHex) {
    var n = serialHex.trim().toLowerCase();
    if (n.startsWith('0x')) n = n.substring(2);
    n = n.replaceFirst(RegExp(r'^0+(?=[0-9a-f])'), '');
    return n;
  }

  /// One refresh attempt over Firestore-independent HTTPS. Returns the new
  /// snapshot and persists it (body + fetchedAt). Throws on transport /
  /// non-200 / empty body — callers that must not fail use
  /// [refreshIfStale]/[refreshBestEffort]. Injectable [fetcher] keeps unit
  /// tests offline (production uses HttpClient).
  static Future<RevocationSnapshot> refresh({
    RevocationStore? store,
    Future<String> Function(Uri url)? fetcher,
    Duration timeout = kRevocationFetchBudget,
    DateTime? now,
  }) async {
    final at = (now ?? DateTime.now()).toUtc();
    final fetch = fetcher ?? _fetchStatusBody;
    var body = await fetch(Uri.parse(kAttestationStatusUrl))
        .timeout(timeout);
    body = body.trim();
    if (body.isEmpty) throw StateError('empty attestation status body');
    if (body.length > kRevocationBodyCap) {
      body = body.substring(0, kRevocationBodyCap);
    }
    final snap = RevocationSnapshot(rawBody: body, fetchedAt: at);
    try {
      await (store ?? SharedPrefsRevocationStore()).write(
        body: body,
        fetchedAtMillis: at.millisecondsSinceEpoch,
      );
    } catch (e) {
      BleLog.log('SEC', 'revocation snapshot persist failed ($e)');
    }
    BleLog.log('SEC',
        'revocation snapshot refreshed (${body.length}B @ ${at.toIso8601String()})');
    return snap;
  }

  /// Cached-or-refresh: returns the cached snapshot when fresh (unless
  /// [force]); otherwise attempts [refresh] and falls back to the stale
  /// cached snapshot on ANY failure (fail-open — never throws for transport
  /// reasons, so online setup degrades to `revocation-stale`, never to an
  /// enrollment/hosting refusal).
  static Future<RevocationSnapshot> refreshIfStale({
    RevocationStore? store,
    Future<String> Function(Uri url)? fetcher,
    Duration timeout = kRevocationFetchBudget,
    DateTime? now,
    bool force = false,
  }) async {
    final at = (now ?? DateTime.now()).toUtc();
    final cached = await load(store: store);
    if (!force && !cached.isStale(at)) return cached;
    try {
      return await refresh(
          store: store, fetcher: fetcher, timeout: timeout, now: at);
    } catch (e) {
      BleLog.log('SEC', 'revocation refresh failed ($e) — serving stale');
      return cached;
    }
  }

  /// Fire-and-forget hook for one-time online setup (enrollment/host
  /// setup call sites `unawaited(...)` this): bounded, never throws, never
  /// blocks offline marking. Failures degrade to the stale flag.
  static Future<void> refreshBestEffort({
    RevocationStore? store,
    Future<String> Function(Uri url)? fetcher,
    Duration timeout = kRevocationFetchBudget,
  }) async {
    try {
      await refreshIfStale(store: store, fetcher: fetcher, timeout: timeout);
    } catch (_) {
      // refreshIfStale already fails open; this is belt-and-braces so the
      // setup path can never observe a throw (or a hung future past the
      // budget — refresh bounds the fetch; the store read is local).
    }
  }

  /// Production HTTPS fetch (HttpClient, no Firestore/Functions/SDK).
  static Future<String> _fetchStatusBody(Uri url) async {
    final client = HttpClient();
    try {
      final req =
          await client.getUrl(url).timeout(kRevocationFetchBudget);
      final res = await req.close().timeout(kRevocationFetchBudget);
      if (res.statusCode != 200) {
        throw StateError('status ${res.statusCode}');
      }
      final body = await res.transform(utf8.decoder).join().timeout(
            kRevocationFetchBudget,
          );
      return body;
    } finally {
      client.close(force: true);
    }
  }
}

/// Fire-and-forget advisory review log for one chain (enrollment/host setup
/// call sites `unawaited(...)` this where chain DER hex is available):
/// loads the cached snapshot locally (no fetch) and logs non-empty
/// `reviewFlagsForChainHex` flags for the professor review screen. Empty
/// chains log nothing (existing stale-flag behavior is unchanged — the
/// review screen still derives it via `flagFor`). Bounded local read only,
/// never throws, never blocks marking.
Future<void> logChainRevocationReview(
    List<String> chainHex, String where) async {
  try {
    if (chainHex.isEmpty) return;
    final snap = await RevocationCache.load();
    final flags =
        RevocationCache.reviewFlagsForChainHex(snap, chainHex);
    if (flags.isNotEmpty) {
      BleLog.log('SEC', '$where chain revocation review (${flags.join(',')})');
    }
  } catch (_) {
    // Best-effort advisory only — setup paths must never observe a throw.
  }
}
