//
// InMemoryDeviceStore:
//   - [recordInCourse]: the course-membership predicate used by both
//     renameCourse impls and both deleteCourse impls (was 4 copies).
//   - [todayIso]: the course creation stamp used by Secure addCourse.
//   - [dateIsoOf]: the ONE yyyy-MM-dd formatter (claim/trust/export all
//     delegate here; core never imports widgets/).
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

/// Calendar date as yyyy-MM-dd (STORAGE ONLY: stamps, export filenames,
/// CSV bytes, record ids). Single definition — UI resolves it via
/// device_store. Never render this directly: user-visible dates use
/// [displayDateOf] (DD-MM-YYYY) or the widgets/clock helpers
/// ([Day], DD-MM-YYYY where the weekday is shown).
String dateIsoOf(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

/// Global date rule — DISPLAY ONLY, app-wide: DD-MM-YYYY (e.g. 03-09-2026).
/// For DateTime values shown without a weekday (enrollment/trust/claim
/// dates). Storage/CSV/filenames stay [dateIsoOf] (yyyy-MM-dd) — never
/// route those through here.
String displayDateOf(DateTime t) =>
    '${t.day.toString().padLeft(2, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.year.toString().padLeft(4, '0')}';

/// Today's date as yyyy-MM-dd (course creation stamp).
String todayIso() => dateIsoOf(DateTime.now());
