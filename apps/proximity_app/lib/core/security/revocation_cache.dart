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
//   - refresh-when-online: `refreshBestEffort()` from one-time online setup
//     (enrollment `upload()` + host `_startHostingInner()`) AND periodic
//     via `schedulePeriodicRefresh()` for long-lived sessions (H8: not
//     once — the timer no-ops locally while fresh, refetches when stale).
//     Best-effort, bounded timeout, never throws — a failure keeps the old
//     snapshot and marking proceeds offline (retry on next marking/setup).
//   - persist: raw body + `fetchedAt` millis + sha256 + truncated flag in
//     SharedPreferences (`prox.revocation.v1.*`); TTL 7d
//     (`kRevocationCacheTtl`). The hash SHOULD live in the secure store
//     (see [RevocationHashStore] seam — H8); until wired, a hash mismatch
//     forces stale (fail-open, never an accusation).
//   - fail-open: stale/missing/offline NEVER blocks — `flagFor()` surfaces
//     `revocation-stale` for professor review instead (alongside
//     `audit-double-pkD` from `claim.dart findDoublePkD` + the ticket anomaly
//     flags; the roster keeps presence, review happens post-hoc).
//   - live path (H8): the professor review path consumes the cache via the
//     sync [RevocationCache.isRevoked] (FRESH snapshots only) after a
//     `load()`/`refreshIfStale()` primed [_lastSyncSnapshot]; the fetch
//     itself never runs on the live path (pure sync, never blocks marking).
//     Serials are opaque hex (normalised, never interpreted).
//
// MITM-freeze note (H8, accepted residual — Spark-free, no pinning infra):
//   the status fetch is plain HTTPS with NO certificate pinning, so a
//   network-level MITM can at most FREEZE the CRL (block/stall refresh →
//   the snapshot stays stale → `revocation-stale` review flag, never a
//   false clean) — it cannot forge a fresh Google-signed revoked/clean
//   verdict the app would trust (TLS still authenticates the host; a full
//   CA-compromise forgery is out of scope for a Spark-free client). Pinning
//   (or a backend proxy) is the documented hardening; until then the stale
//   flag is the signal, never an accusation.
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
import 'package:proximity_protocol/protocol.dart';
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
const _kHashKey = 'prox.revocation.v1.sha256';
const _kTruncatedKey = 'prox.revocation.v1.truncated';

/// H8 integrity hash: SHA-256 hex of the persisted status body. The payload
/// is opaque bytes (length/shape only — never decrypted or interpreted
/// beyond the review-flag scan). A mismatch on load forces stale (fail-open,
/// never an accusation); the hash SHOULD live in the secure store (see
/// [RevocationHashStore]) so a prefs-only edit cannot go undetected.
String revocationBodyHashHex(String body) {
  final digest = ProxCrypto.sha256Sync(utf8.encode(body));
  final sb = StringBuffer();
  for (final b in digest) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// H8 secure-store seam for the integrity hash (Spark-free): production
/// wires a `flutter_secure_storage`-backed implementation (secure_store
/// owner) so the hash lives outside SharedPreferences; tests inject memory.
/// Until wired, callers omit [hashStore] and the hash travels alongside the
/// body in prefs (mismatch still forces stale — detection, not prevention).
abstract class RevocationHashStore {
  Future<String?> readHash();
  Future<void> writeHash(String sha256Hex);
}

/// One cached CRL snapshot: raw status body + fetch time (UTC) + H8
/// integrity markers. `truncated`/`hashMismatch` force stale (indeterminate
/// — a truncated prefix or tampered body must never read clean OR accuse).
class RevocationSnapshot {
  /// Raw response body ('' = never fetched).
  final String rawBody;

  /// Fetch time (epoch 0 = never fetched).
  final DateTime fetchedAt;

  /// True when the persisted body was cut at [kRevocationBodyCap].
  final bool truncated;

  /// True when the body does not match the stored sha256.
  final bool hashMismatch;

  const RevocationSnapshot({
    required this.rawBody,
    required this.fetchedAt,
    this.truncated = false,
    this.hashMismatch = false,
  });

  /// Never-fetched snapshot (stale by construction).
  factory RevocationSnapshot.empty() => RevocationSnapshot(
        rawBody: '',
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  bool get isEmpty => rawBody.isEmpty;

  /// True when missing, integrity-indeterminate, or older than
  /// [kRevocationCacheTtl] at [now].
  bool isStale(DateTime now) {
    if (isEmpty) return true;
    if (truncated || hashMismatch) return true;
    final fetchedMs = fetchedAt.toUtc().millisecondsSinceEpoch;
    if (fetchedMs <= 0) return true;
    return now.toUtc().millisecondsSinceEpoch - fetchedMs >
        kRevocationCacheTtl.inMilliseconds;
  }
}

/// Minimal persistence seam (production = SharedPreferences; tests = memory).
/// H8 integrity: body + fetchedAt + sha256 + truncated flag travel
/// together; a hash mismatch or truncation marker forces stale on load.
abstract class RevocationStore {
  Future<String?> readBody();
  Future<int?> readFetchedAtMillis();
  Future<String?> readHash();
  Future<bool?> readTruncated();
  Future<void> write({
    required String body,
    required int fetchedAtMillis,
    String? sha256Hex,
    bool truncated = false,
  });
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
  Future<String?> readHash() async {
    try {
      return (await _prefs()).getString(_kHashKey);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool?> readTruncated() async {
    try {
      return (await _prefs()).getBool(_kTruncatedKey);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write({
    required String body,
    required int fetchedAtMillis,
    String? sha256Hex,
    bool truncated = false,
  }) async {
    final prefs = await _prefs();
    await prefs.setString(_kBodyKey, body);
    await prefs.setInt(_kFetchedAtKey, fetchedAtMillis);
    await prefs.setString(
        _kHashKey, sha256Hex ?? revocationBodyHashHex(body));
    await prefs.setBool(_kTruncatedKey, truncated);
  }
}

/// In-memory backend (tests / previews — never shipped state).
class MemoryRevocationStore implements RevocationStore {
  String? body;
  int? fetchedAtMillis;
  String? hashHex;
  bool? truncated;

  @override
  Future<String?> readBody() async => body;

  @override
  Future<int?> readFetchedAtMillis() async => fetchedAtMillis;

  @override
  Future<String?> readHash() async => hashHex;

  @override
  Future<bool?> readTruncated() async => truncated;

  @override
  Future<void> write({
    required String body,
    required int fetchedAtMillis,
    String? sha256Hex,
    bool truncated = false,
  }) async {
    this.body = body;
    this.fetchedAtMillis = fetchedAtMillis;
    hashHex = sha256Hex ?? revocationBodyHashHex(body);
    this.truncated = truncated;
  }
}

/// Offline CRL cache (static helpers over [RevocationStore]).
class RevocationCache {
  RevocationCache._();

  /// In-memory last snapshot for the sync [`isRevoked`] helper (H8
  /// Track-B seam): refreshed by [refresh]/[refreshIfStale]; null until
  /// first load/refresh. Opaque cache only — never a trust decision alone
  /// (callers check staleness via [flagFor]/review flags).
  static RevocationSnapshot? _lastSyncSnapshot;

  /// Loads the persisted snapshot (empty when never fetched) and verifies
  /// the H8 integrity hash (mismatch ⇒ `hashMismatch: true` ⇒ stale).
  /// When [hashStore] is provided (secure-store wiring), the hash reads
  /// from it instead of the prefs sidecar. Never throws.
  /// Primes the sync [isRevoked] live-path cache as a side effect — the
  /// professor live path calls this (or [refreshIfStale]) at setup, then
  /// consumes [isRevoked] sync when fresh.
  static Future<RevocationSnapshot> load(
      {RevocationStore? store, RevocationHashStore? hashStore}) async {
    final s = store ?? SharedPrefsRevocationStore();
    try {
      final body = await s.readBody() ?? '';
      final ms = await s.readFetchedAtMillis() ?? 0;
      String? storedHash;
      try {
        storedHash = hashStore != null
            ? await hashStore.readHash()
            : await s.readHash();
      } catch (_) {
        storedHash = null;
      }
      final truncated = await s.readTruncated() ?? false;
      var hashMismatch = false;
      if (body.isNotEmpty &&
          storedHash != null &&
          storedHash.trim().isNotEmpty) {
        try {
          hashMismatch =
              revocationBodyHashHex(body) != storedHash.trim().toLowerCase();
        } catch (_) {
          hashMismatch = true;
        }
      }
      final snap = RevocationSnapshot(
        rawBody: body,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
        truncated: truncated,
        hashMismatch: hashMismatch,
      );
      _lastSyncSnapshot = snap;
      if (hashMismatch) {
        BleLog.log('SEC',
            'revocation snapshot hash mismatch — treating as stale (refetch)');
      }
      if (truncated) {
        BleLog.log('SEC',
            'revocation snapshot truncated — indeterminate, needs refresh');
      }
      return snap;
    } catch (_) {
      return RevocationSnapshot.empty();
    }
  }

  /// Sync revoked check for the Track-B server live path (H8): true only
  /// when the in-memory snapshot ([load]/[refresh]/[refreshIfStale] must
  /// have run) is FRESH and [serialHex] matches a revoked entry. False
  /// otherwise (missing/stale/truncated/mismatched/unknown ⇒ not revoked —
  /// staleness is surfaced separately via [flagFor], never as an
  /// accusation). Pure sync — never fetches, never blocks marking.
  /// Treats the serial as opaque hex (normalised, never interpreted).
  static bool isRevoked(String serialHex) {
    try {
      final snap = _lastSyncSnapshot;
      if (snap == null) return false;
      if (snap.isStale(DateTime.now().toUtc())) return false;
      if (serialHex.trim().isEmpty) return false;
      return isSerialRevoked(snap, serialHex);
    } catch (_) {
      return false;
    }
  }

  /// Test seam: seed the sync snapshot for [isRevoked].
  static void debugSeedSyncSnapshotForTest(RevocationSnapshot snap) {
    _lastSyncSnapshot = snap;
  }

  /// Live-path primer (H8): loads the persisted snapshot into the sync
  /// [isRevoked] cache (no fetch). Setup paths (enrollment/host) call this
  /// at startup when they cannot afford even a best-effort fetch; the
  /// professor live path then consumes [isRevoked] (fresh only) +
  /// [flagFor] (staleness) without I/O. Never throws, never blocks marking.
  static Future<void> primeSyncSnapshot(
      {RevocationStore? store, RevocationHashStore? hashStore}) async {
    try {
      await load(store: store, hashStore: hashStore);
    } catch (_) {}
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
  /// any status containing `revok`/`suspend` counts. Truncated or
  /// hash-mismatched snapshots never accuse here (H8 indeterminate — the
  /// review path reports stale instead; a truncated prefix must not clear
  /// or accuse). Falls back to false on unparseable bodies (fail-open —
  /// garbage never accuses; staleness is the signal there).
  static bool isSerialRevoked(RevocationSnapshot snap, String serialHex) {
    final want = _normSerial(serialHex);
    if (snap.rawBody.isEmpty || want.isEmpty) return false;
    if (snap.truncated || snap.hashMismatch) return false;
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
      // Fall through to the word-boundary fallback below.
    }
    // Non-JSON bodies (H8a): word-boundary token match only — a bare
    // substring (`body.contains`) false-positives on serials embedded in
    // longer hex (`ab12` inside `xab123`) or revoke words inside other
    // words. Serial must appear as a whole token AND a revoke/suspend word
    // must appear as a whole word (with trailing-word tolerance for
    // REVOKED/SUSPENDED). A bare serial echo without a revoke word is not
    // an accusation.
    try {
      final body = snap.rawBody.toLowerCase();
      final serialHit = RegExp(
              '\\b${RegExp.escape(want)}\\b')
          .hasMatch(body);
      if (!serialHit) return false;
      final revokeHit =
          RegExp(r'\brevok\w*\b').hasMatch(body) ||
              RegExp(r'\bsuspend\w*\b').hasMatch(body);
      return revokeHit;
    } catch (_) {
      return false;
    }
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
  /// snapshot and persists it (body + fetchedAt + sha256 + truncated flag,
  /// H8). Throws on transport / non-200 / empty body — callers that must
  /// not fail use [refreshIfStale]/[refreshBestEffort]. Injectable
  /// [fetcher] keeps unit tests offline (production uses HttpClient).
  /// Bodies larger than [kRevocationBodyCap] are truncated AND marked
  /// `truncated: true` (H8 fail-closed indeterminate — the snapshot
  /// reports stale/needs-refresh, never a false-negative clean). The
  /// payload is treated as opaque bytes (hash/persist only, never
  /// interpreted here beyond the review-flag scan).
  static Future<RevocationSnapshot> refresh({
    RevocationStore? store,
    RevocationHashStore? hashStore,
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
    var truncated = false;
    if (body.length > kRevocationBodyCap) {
      body = body.substring(0, kRevocationBodyCap);
      truncated = true;
    }
    final hashHex = revocationBodyHashHex(body);
    final snap = RevocationSnapshot(
        rawBody: body, fetchedAt: at, truncated: truncated);
    try {
      await (store ?? SharedPrefsRevocationStore()).write(
        body: body,
        fetchedAtMillis: at.millisecondsSinceEpoch,
        sha256Hex: hashHex,
        truncated: truncated,
      );
      if (hashStore != null) {
        try {
          await hashStore.writeHash(hashHex);
        } catch (e) {
          BleLog.log('SEC', 'revocation hash secure-store failed ($e)');
        }
      }
    } catch (e) {
      BleLog.log('SEC', 'revocation snapshot persist failed ($e)');
    }
    _lastSyncSnapshot = snap;
    if (truncated) {
      BleLog.log('SEC',
          'revocation snapshot truncated at $kRevocationBodyCap B — indeterminate, needs refresh (@ ${at.toIso8601String()})');
    } else {
      BleLog.log('SEC',
          'revocation snapshot refreshed (${body.length}B @ ${at.toIso8601String()})');
    }
    return snap;
  }

  /// Cached-or-refresh (H8 periodic-refresh helper): returns the cached
  /// snapshot when fresh (unless [force]); otherwise attempts [refresh]
  /// and falls back to the stale cached snapshot on ANY failure
  /// (fail-open — never throws for transport reasons, so online setup
  /// degrades to `revocation-stale`, never to an enrollment/hosting
  /// refusal). Failures keep the snapshot stale so the NEXT marking/setup
  /// retries (retry-on-next-marking — no lost refresh). Updates the sync
  /// [isRevoked] cache on success. This is the ONLY refresh entry the
  /// host/enrollment setup paths should call (via [refreshBestEffort]
  /// `unawaited(...)`); the server live path (Track B) only consumes
  /// [isRevoked] + this future, never the fetch directly.
  static Future<RevocationSnapshot> refreshIfStale({
    RevocationStore? store,
    RevocationHashStore? hashStore,
    Future<String> Function(Uri url)? fetcher,
    Duration timeout = kRevocationFetchBudget,
    DateTime? now,
    bool force = false,
  }) async {
    final at = (now ?? DateTime.now()).toUtc();
    final cached = await load(store: store, hashStore: hashStore);
    if (!force && !cached.isStale(at)) {
      _lastSyncSnapshot = cached;
      return cached;
    }
    try {
      return await refresh(
          store: store,
          hashStore: hashStore,
          fetcher: fetcher,
          timeout: timeout,
          now: at);
    } catch (e) {
      BleLog.log('SEC', 'revocation refresh failed ($e) — serving stale');
      return cached;
    }
  }

  /// Periodic-refresh scheduler (H8d): arms a [Timer.periodic] that calls
  /// [refreshIfStale] (best-effort, never throws). Host/enrollment setup
  /// paths keep their single `unawaited(refreshBestEffort())` AND may arm
  /// this for long-lived sessions; the timer only refreshes when the
  /// snapshot is stale/truncated/mismatched, otherwise it no-ops locally.
  /// Returns the timer (caller cancels on teardown) or null when
  /// [interval] is non-positive. Never blocks marking.
  static Timer? schedulePeriodicRefresh({
    Duration interval = kRevocationCacheTtl,
    RevocationStore? store,
    RevocationHashStore? hashStore,
    Future<String> Function(Uri url)? fetcher,
    Duration timeout = kRevocationFetchBudget,
  }) {
    if (interval <= Duration.zero) return null;
    return Timer.periodic(interval, (_) {
      unawaited(refreshBestEffort(
          store: store,
          hashStore: hashStore,
          fetcher: fetcher,
          timeout: timeout));
    });
  }

  /// Fire-and-forget hook for one-time online setup (enrollment/host
  /// setup call sites `unawaited(...)` this): bounded, never throws, never
  /// blocks offline marking. Failures degrade to the stale flag and retry
  /// on the next marking/setup (the snapshot stays stale, so the next
  /// [refreshIfStale] refetches).
  static Future<void> refreshBestEffort({
    RevocationStore? store,
    RevocationHashStore? hashStore,
    Future<String> Function(Uri url)? fetcher,
    Duration timeout = kRevocationFetchBudget,
  }) async {
    try {
      await refreshIfStale(
          store: store,
          hashStore: hashStore,
          fetcher: fetcher,
          timeout: timeout);
    } catch (_) {
      // refreshIfStale already fails open; this is belt-and-braces so the
      // setup path can never observe a throw (or a hung future past the
      // budget — refresh bounds the fetch; the store read is local).
    }
  }

  /// Production HTTPS fetch (HttpClient, no Firestore/Functions/SDK).
  /// No certificate pinning (Spark-free — no pinning infra): a network
  /// MITM can FREEZE the CRL at worst (block/stall → stale flag, never a
  /// false clean); it cannot mint a fresh verdict the cache would trust
  /// (TLS host auth still applies; CA-compromise forgery out of scope —
  /// see the file-header MITM-freeze note).
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
