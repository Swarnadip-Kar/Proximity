// Shared pure helpers for the DeviceStore backends (M6 sync refactor).
//
// Collapsed ONLY where byte-identical across SecureDeviceStore and
// InMemoryDeviceStore:
//   - [recordInCourse]: the course-membership predicate used by both
//     renameCourse impls and both deleteCourse impls (was 4 copies).
// Kept separate (NOT collapsed) where logic differs — see flags:
//   - renameCourse record rebuild: Secure reuses the record's windows /
//     names / rolls references, InMemory defensively copies them
//     (Map.of / Map<String,bool>.from). Same outward result today, but
//     aliasing differs → both bodies kept verbatim, flagged in report.
//   - deleteSessions / upsertHistory / writeHistory: prefs-JSON round-trip
//     vs in-memory list ops → kept, flagged.
//   - readCourses: Secure migrates the legacy name catalog + parses stored
//     JSON; InMemory derives from its catalog list → kept, flagged.
library;

import 'package:proximity_storage/storage.dart';

/// True when [record] belongs to course [course]: canonical courseId match,
/// or (for pre-course records carrying '') a class-label match.
bool recordInCourse(ClassRecord record, String course) =>
    record.courseId == course ||
    (record.courseId.isEmpty && record.classLabel == course);

/// Today's date as yyyy-MM-dd (course creation stamp).
String todayIso() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}
