// Hands-free face retry policy (marking): an inconclusive verdict
// re-scans automatically every ~1s inside a 10s window, then falls back to
// the manual Scan button. Mismatch never auto-retries (it burns an attempt
// by design). Pure-policy pins for nextAutoFaceRetryDelay.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/screens/student_home.dart';

void main() {
  group('nextAutoFaceRetryDelay', () {
    final now = DateTime.utc(2026, 9, 13, 12, 0, 0);
    const gap = Duration(seconds: 1);

    test('retries inside the window', () {
      expect(
          nextAutoFaceRetryDelay(
              tries: 1,
              tryCap: 8,
              gap: gap,
              now: now,
              deadline: now.add(const Duration(seconds: 10))),
          gap);
    });

    test('stops at the deadline (manual Scan takes over)', () {
      expect(
          nextAutoFaceRetryDelay(
              tries: 2,
              tryCap: 8,
              gap: gap,
              now: now.add(const Duration(seconds: 10)),
              deadline: now.add(const Duration(seconds: 10))),
          isNull);
      expect(
          nextAutoFaceRetryDelay(
              tries: 2,
              tryCap: 8,
              gap: gap,
              now: now.add(const Duration(seconds: 11)),
              deadline: now.add(const Duration(seconds: 10))),
          isNull);
    });

    test('try-count cap backstops clock jumps', () {
      expect(
          nextAutoFaceRetryDelay(
              tries: 9,
              tryCap: 8,
              gap: gap,
              now: now,
              deadline: now.add(const Duration(hours: 1))),
          isNull);
    });

    test('cap boundary retries exactly tryCap times', () {
      final deadline = now.add(const Duration(seconds: 10));
      expect(
          nextAutoFaceRetryDelay(
              tries: 8, tryCap: 8, gap: gap, now: now, deadline: deadline),
          gap);
      expect(
          nextAutoFaceRetryDelay(
              tries: 9, tryCap: 8, gap: gap, now: now, deadline: deadline),
          isNull);
    });
  });
}
