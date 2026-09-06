// Session-recovery policy: prompt ONLY for drafts older than 2.5h;
// recent drafts auto-archive to history (no interrogation after a
// crash mid-lecture).
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/screens/take_attendance.dart';

void main() {
  test('shouldPromptRecover gates on the 2.5h threshold', () {
    final now = DateTime.utc(2026, 9, 6, 12, 0, 0);
    // No timestamp: nothing to recover → fresh.
    expect(shouldPromptRecover(null, now), isFalse);
    // Minutes/hours old: auto-archive, no prompt.
    expect(
        shouldPromptRecover(now.subtract(const Duration(minutes: 5)), now),
        isFalse);
    expect(
        shouldPromptRecover(now.subtract(const Duration(hours: 2)), now),
        isFalse);
    // Just under the line: still auto-archive.
    expect(
        shouldPromptRecover(
            now.subtract(const Duration(minutes: 149)), now),
        isFalse);
    // Over the line: prompt.
    expect(
        shouldPromptRecover(
            now.subtract(const Duration(minutes: 151)), now),
        isTrue);
    expect(
        shouldPromptRecover(now.subtract(const Duration(days: 1)), now),
        isTrue);
  });
}
