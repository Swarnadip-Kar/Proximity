// Browse-ordinal refresh rule: the waiting-room poll feeds the tile map.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/screens/student_home.dart';

void main() {
  test('reachable probe with Class N refreshes to Class N', () {
    expect(
        gatedProbeClassNoForTile(
            reachable: true, classNo: 5, windowNo: 2),
        5);
  });

  test('reachable probe without Class N falls back to the live round', () {
    expect(
        gatedProbeClassNoForTile(
            reachable: true, classNo: 0, windowNo: 3),
        3);
  });

  test('unknown numbers never refresh (caller keeps the old number)', () {
    expect(
        gatedProbeClassNoForTile(
            reachable: true, classNo: 0, windowNo: 0),
        isNull);
  });

  test('unreachable ticks never clobber a known number', () {
    expect(
        gatedProbeClassNoForTile(
            reachable: false, classNo: 5, windowNo: 2),
        isNull);
  });
}
