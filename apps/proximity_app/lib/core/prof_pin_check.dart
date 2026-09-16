// Professor key-pin check (anti-fake-professor, anybody-can-host).
//
// Flow: student fetches WindowDescriptor over gated /window unicast, then
// calls [checkProfPin] BEFORE signing anything. The pin list comes from the
// local cache first, refreshed best-effort from Firestore when online.
// Verdicts (see protocol prof_key_pin.dart):
//   unknown  -> first-seen TOFU, allow with `unverified-prof-key` banner,
//               pin presented key locally for next class.
//   known    -> allow, refresh cache timestamp.
//   mismatch -> fake, refuse to sign (structured error, no proof sent).
//
// Hosting stays offline-capable: publish is best-effort fire-and-forget,
// verify degrades to cached pin, then to unknown (never blocks on network).
library;

import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';

import 'device_store.dart';

/// Result of [checkProfPin].
class ProfPinCheck {
  final ProfPinVerdict verdict;
  final String profEmail;
  final String presentedPkPHex;

  /// True only when a live remote fetch returned a non-empty pin list for
  /// this verdict (drives the `Verified · live` badge — a cache-only
  /// verdict while offline must never claim a live fetch).
  final bool liveRefreshed;
  const ProfPinCheck(
      {required this.verdict,
      required this.profEmail,
      required this.presentedPkPHex,
      this.liveRefreshed = false});
}

/// Pure cache read: cached pin hexes for [profEmailLower] from raw store rows.
List<String> profPinHexesFromRows(List<Map<String, dynamic>> rows) => [
      for (final e in rows)
        if (e['pkP'] is String && (e['pkP'] as String).trim().isNotEmpty)
          (e['pkP'] as String).trim().toLowerCase()
    ];

/// Checks [desc] against the local pin cache, refreshing best-effort via
/// [fetchRemote] when provided (online Firestore get, never throws).
/// Updates the local cache on known/unknown (pin-on-first-use).
Future<ProfPinCheck> checkProfPin({
  required WindowDescriptor desc,
  required DeviceStore store,
  Future<List<Map<String, dynamic>>> Function(String email)? fetchRemote,
}) async {
  final email = desc.profEmail.trim().toLowerCase();
  final presented = hexEncode(desc.profPk.bytes.sublist(0, 32)).toLowerCase();
  if (email.isEmpty || !isValidProfPkPHex(presented)) {
    return ProfPinCheck(
        verdict: ProfPinVerdict.unknown,
        profEmail: email,
        presentedPkPHex: presented);
  }
  List<Map<String, dynamic>> rows = const [];
  try {
    rows = await store.readProfPin(email);
  } catch (_) {
    rows = const [];
  }
  var pinned = profPinHexesFromRows(rows);
  var hasCache = pinned.isNotEmpty;
  // Best-effort refresh when online: a fresh pin overrides the cache for
  // the verdict and rewrites the cache for next class.
  var liveRefreshed = false;
  if (fetchRemote != null) {
    try {
      final fresh =
          await fetchRemote(email).timeout(const Duration(seconds: 8));
      final freshHexes = profPinHexesFromRows(fresh);
      if (freshHexes.isNotEmpty) {
        pinned = freshHexes;
        hasCache = true;
        liveRefreshed = true;
        try {
          await store.writeProfPin(email, fresh);
        } catch (_) {}
      }
    } catch (_) {
      // Offline or denied -> fall back to cache (unknown when empty).
    }
  }
  final verdict = evaluateProfPin(
      presentedPkPHex: presented, pinned: pinned, hasCache: hasCache);
  // Pin-on-first-use: an unknown email that just verified over Sig_p gets
  // cached so the NEXT class is pinned (TOFU -> pin).
  if (verdict == ProfPinVerdict.unknown) {
    try {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final existing = <ProfKeyEntry>[
        for (final e in rows)
          if (ProfKeyEntry.tryFromJson(e) != null)
            ProfKeyEntry.tryFromJson(e)!
      ];
      final merged = mergeProfPinKeys(
          existing: existing, newPkPHex: presented, nowMillis: now);
      await store.writeProfPin(
          email, [for (final e in merged) e.toJson()]);
    } catch (_) {}
  }
  return ProfPinCheck(
      verdict: verdict,
      profEmail: email,
      presentedPkPHex: presented,
      liveRefreshed: liveRefreshed);
}
