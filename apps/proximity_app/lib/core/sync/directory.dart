// Professor-searchable student directory row.
//
// NOTE (kept separate deliberately): the two search implementations differ
// and are NOT collapsed — FirestoreCloudSync fans out to parallel
// server-side prefix queries (single-field range queries, no composite
// index) merged by email client-side, plus a close-substring fallback (one
// bounded org page swept locally with normalized contains + a tiny typo
// budget on rolls) when the prefix tier finds nothing — while
// FakeCloudSync scans its in-memory map. Same outward contract (prefix
// first, then substring/close match on email/roll/lowercased name, merged
// by email, sorted, capped at [limit]), different mechanism. See
// firestore_sync.dart / fake_sync.dart.
library;

/// One row of the professor-searchable student directory: the minimum a
/// professor needs to add someone to a record + the student's device
/// public key for offline email→key verification. Written by the claim
/// transaction, never by hand.
class StudentDirectoryEntry {
  final String email;
  final String name;
  final String roll;
  final String org; // Google-account domain (see orgOf), '' = unstamped
  /// Last claim touch (UTC epoch ms, 0 = legacy — never "stale" by itself;
  /// drives the owner-lazy six-month purge gate).
  final int updatedAtMillis;
  /// Student SKey public bytes hex (Ed25519 32B, '' = legacy row written
  /// before the pin field landed — treated as no-pin TOFU, never as a
  /// mismatch; re-enroll backfills it). Professors pin this online and
  /// enforce `unknown-pkS` offline from the persistent cache.
  final String pkSHex;
  const StudentDirectoryEntry(
      {required this.email,
      required this.name,
      required this.roll,
      this.org = '',
      this.updatedAtMillis = 0,
      this.pkSHex = ''});
}

/// Normalized search prefixes shared by both backends (roll is trimmed
/// only — numeric IDs are case-sensitive; email/name lowercased).
({String email, String roll, String name}) normalizeSearchPrefixes({
  String emailPrefix = '',
  String rollPrefix = '',
  String namePrefix = '',
}) =>
    (
      email: emailPrefix.trim().toLowerCase(),
      roll: rollPrefix.trim(),
      name: namePrefix.trim().toLowerCase(),
    );

/// Normalizes one haystack/needle for matching: lowercase, trim, drop
/// inner spaces/dashes/underscores (`22 10` still matches `2210`). Dots
/// are kept (emails), case is folded. Display values are untouched — this
/// only widens matching, never rewrites what is shown.
String searchNorm(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'[\s\-_]'), '');

/// Edit distance with an early-exit cap (pure): returns >[cap] without
/// finishing the matrix once the floor exceeds it. Inputs here are short
/// (IDs/names), so the matrix is tiny; the cap just bounds worst case.
int editDistanceCapped(String a, String b, int cap) {
  final n = a.length;
  final m = b.length;
  if ((n - m).abs() > cap) return cap + 1;
  var prev = List<int>.generate(m + 1, (j) => j);
  for (var i = 1; i <= n; i++) {
    final cur = List<int>.filled(m + 1, 0);
    cur[0] = i;
    var rowMin = i;
    for (var j = 1; j <= m; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var v = prev[j] + 1;
      final ins = cur[j - 1] + 1;
      if (ins < v) v = ins;
      final sub = prev[j - 1] + cost;
      if (sub < v) v = sub;
      cur[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > cap) return cap + 1;
    prev = cur;
  }
  return prev[m];
}

/// Close-substring match (pure): normalized contains, else — for needles
/// of 3+ chars — any equal-length window within a tiny edit budget (1 below
/// 6 chars, 2 at/above). Catches transpositions/typos (`12342201` still
/// suggests `12342210`). [fuzzy] gates the edit pass: rolls use it, names
/// and emails stay contains-only (their alphabets over-match at
/// distance 1). Zero database cost — runs over the already-fetched page.
bool fieldClose(String hayRaw, String needleRaw, {required bool fuzzy}) {
  final hay = searchNorm(hayRaw);
  final n = searchNorm(needleRaw);
  if (n.isEmpty) return false;
  if (hay.contains(n)) return true;
  if (!fuzzy || n.length < 3 || hay.length < n.length) return false;
  final cap = n.length >= 6 ? 2 : 1;
  for (var i = 0; i + n.length <= hay.length; i++) {
    if (editDistanceCapped(hay.substring(i, i + n.length), n, cap) <=
        cap) {
      return true;
    }
  }
  return false;
}
