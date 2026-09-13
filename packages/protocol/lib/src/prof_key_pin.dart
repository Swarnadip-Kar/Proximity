// Professor lecture-key pins (anti-fake-professor, anybody-can-host).
//
// Lecture keys are ephemeral per hosting today (host generates a fresh
// Ed25519 keypair per Take open, never uploaded before this track). The
// pin doc `profDevices/{emailLower} {email, uid, org, pubKeys[{pkP,
// createdAtMillis}], updatedAtMillis}` holds up to 8 recent lecture public
// keys per Gmail, owner-only write (rules), same-org get.
//
// Trust law (offline-capable, first-seen TOFU):
//   no cache for email -> unknown (first-seen, allow with banner, pin on use)
//   presented in cache  -> known (allow)
//   cache has email but no match -> mismatch (fake, refuse to sign)
// Email binding comes from the CACHED pin fetch by profEmail (Firestore),
// never from the LAN-presented pkP alone. Display name is never trust.
library;

const int kProfPinMaxKeys = 8;

/// True when [s] is a 32B Ed25519 public key as 64 hex chars.
bool isValidProfPkPHex(String s) {
  if (s.length != 64) return false;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final ok = (c >= 48 && c <= 57) ||
        (c >= 97 && c <= 102) ||
        (c >= 65 && c <= 70);
    if (!ok) return false;
  }
  return true;
}

/// One pinned lecture key.
class ProfKeyEntry {
  final String pkPHex;
  final int createdAtMillis;
  const ProfKeyEntry({required this.pkPHex, required this.createdAtMillis});

  Map<String, dynamic> toJson() =>
      {'pkP': pkPHex.toLowerCase(), 'createdAtMillis': createdAtMillis};

  static ProfKeyEntry? tryFromJson(Map<String, dynamic> j) {
    final pkP = (j['pkP'] as String? ?? '').trim().toLowerCase();
    final at = (j['createdAtMillis'] as num?)?.toInt() ?? 0;
    if (!isValidProfPkPHex(pkP) || at <= 0) return null;
    return ProfKeyEntry(pkPHex: pkP, createdAtMillis: at);
  }
}

/// Pin verdict for a LAN-presented professor key.
enum ProfPinVerdict {
  /// No cache for this email (offline first-seen or never fetched).
  /// Caller allows with `unverified-prof-key` banner and pins on use.
  unknown,

  /// Presented key is in the pin list.
  known,

  /// Pin list exists for email but presented key is not in it.
  /// Caller must refuse to sign (fake professor).
  mismatch,
}

/// Pure verdict: [pinned] is the cached pin list for [profEmailLower]
/// (empty = no cache); [presentedPkPHex] is the LAN-presented pkP.
ProfPinVerdict evaluateProfPin({
  required String presentedPkPHex,
  required List<String> pinned,
  required bool hasCache,
}) {
  final presented = presentedPkPHex.trim().toLowerCase();
  if (!isValidProfPkPHex(presented)) return ProfPinVerdict.mismatch;
  if (!hasCache) return ProfPinVerdict.unknown;
  if (pinned.isEmpty) return ProfPinVerdict.unknown;
  for (final p in pinned) {
    if (p.trim().toLowerCase() == presented) return ProfPinVerdict.known;
  }
  return ProfPinVerdict.mismatch;
}

/// Pure merge: append [newPkPHex] to [existing] (deduped, lowercased),
// keeping the newest [kProfPinMaxKeys]. Invalid new key returns existing
// unchanged. Existing invalid entries are dropped.
List<ProfKeyEntry> mergeProfPinKeys({
  required List<ProfKeyEntry> existing,
  required String newPkPHex,
  required int nowMillis,
}) {
  final want = newPkPHex.trim().toLowerCase();
  if (!isValidProfPkPHex(want) || nowMillis <= 0) {
    return List<ProfKeyEntry>.unmodifiable(existing);
  }
  final out = <ProfKeyEntry>[];
  for (final e in existing) {
    if (!isValidProfPkPHex(e.pkPHex.toLowerCase())) continue;
    if (e.pkPHex.toLowerCase() == want) continue;
    out.add(e);
  }
  out.add(ProfKeyEntry(pkPHex: want, createdAtMillis: nowMillis));
  out.sort((a, b) => a.createdAtMillis.compareTo(b.createdAtMillis));
  while (out.length > kProfPinMaxKeys) {
    out.removeAt(0);
  }
  return List<ProfKeyEntry>.unmodifiable(out);
}
