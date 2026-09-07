// Shared pure helpers for the DeviceStore backends (M6 sync refactor).
//
// Collapsed ONLY where byte-identical across SecureDeviceStore and
// InMemoryDeviceStore:
//   - [recordInCourse]: the course-membership predicate used by both
//     renameCourse impls and both deleteCourse impls (was 4 copies).
//   - [todayIso]: the course creation stamp used by Secure addCourse.
//   - [dateIsoOf]: the ONE yyyy-MM-dd formatter (claim/trust/export all
//     delegate here; core never imports widgets/).
// Deliberately NOT collapsed (M3 verdict: documented-different, item
// closed): renameCourse's record rebuild reuses the record's windows /
// names / rolls references in Secure but defensively copies them in
// InMemory (Map.of); deleteSessions / upsertHistory / writeHistory go
// through a prefs-JSON round-trip (deep copy) in Secure vs live list ops
// (aliasing) in InMemory; readCourses parses stored JSON plus a legacy
// catalog migration in Secure vs deriving from the catalog list in
// InMemory. All three differences are value-invisible through the
// DeviceStore interface (equal-valued records in, equal-valued records
// out; Secure's next read re-parses JSON anyway) and InMemory is the
// test/sim double, so the copy-vs-alias gap can only make InMemory safer
// under live-object mutation, never less correct. No further extraction:
// the remaining shared fragments are single-expression predicates whose
// helpers would add indirection without benefit.
library;

import 'package:proximity_storage/storage.dart';

/// True when [record] belongs to course [course]: canonical courseId match,
/// or (for pre-course records carrying '') a class-label match.
bool recordInCourse(ClassRecord record, String course) =>
    record.courseId == course ||
    (record.courseId.isEmpty && record.classLabel == course);

/// Calendar date as yyyy-MM-dd (stamps, claim copy, trust labels, export
/// filenames). Single definition — UI resolves it via device_store.
String dateIsoOf(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

/// Today's date as yyyy-MM-dd (course creation stamp).
String todayIso() => dateIsoOf(DateTime.now());
