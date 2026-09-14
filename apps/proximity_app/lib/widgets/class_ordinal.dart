// Class-number ordinals for live rounds ("1st Class", "2nd Class").
//
// One helper for both sides of the same number: the student browse tile
// (under the course disc) and the professor roster header (beside
// `Attendance`). Pure, unit-tested. `classOrdinalLabel` returns '' for
// unknown/closed rounds (0/negative) so callers hide the slot.
library;

/// English ordinal suffix for [n] (11–13 always take 'th').
String ordinalSuffix(int n) {
  final m100 = n % 100;
  if (m100 >= 11 && m100 <= 13) return 'th';
  switch (n % 10) {
    case 1:
      return 'st';
    case 2:
      return 'nd';
    case 3:
      return 'rd';
    default:
      return 'th';
  }
}

/// "1st Class" for live round [n]; '' when the round number is unknown.
String classOrdinalLabel(int n) =>
    n <= 0 ? '' : '$n${ordinalSuffix(n)} Class';
