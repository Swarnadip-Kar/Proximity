// Professor-searchable student directory row.
// Split out of core/cloud_sync.dart (M6 sync refactor) — body verbatim.
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
  const StudentDirectoryEntry(
      {required this.email, required this.name, required this.roll});
}
