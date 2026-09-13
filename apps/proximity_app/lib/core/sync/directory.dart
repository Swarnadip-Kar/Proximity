// Professor-searchable student directory row.
//
// NOTE (kept separate deliberately): the two search implementations differ
// and are NOT collapsed — FirestoreCloudSync fans out to parallel
// server-side prefix queries (single-field range queries, no composite
// index) merged by email client-side, while FakeCloudSync scans its
// in-memory map. Same outward contract (prefix match on email/roll/
// lowercased name, merged by email, sorted, capped at [limit]), different
// mechanism. See firestore_sync.dart / fake_sync.dart.
library;

/// One row of the professor-searchable student directory: the minimum a
/// professor needs to add someone to a record. Written by the claim
/// transaction, never by hand.
class StudentDirectoryEntry {
  final String email;
  final String name;
  final String roll;
  final String org; // Google-account domain (see orgOf), '' = unstamped
  /// Last claim touch (UTC epoch ms, 0 = legacy — never "stale" by itself;
  /// drives the owner-lazy six-month purge gate).
  final int updatedAtMillis;
  const StudentDirectoryEntry(
      {required this.email,
      required this.name,
      required this.roll,
      this.org = '',
      this.updatedAtMillis = 0});
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
