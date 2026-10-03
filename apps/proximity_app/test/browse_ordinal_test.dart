// Browse-ordinal refresh rule: the waiting-room poll feeds the tile map.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/mark/browse_list.dart';
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

  test('same display code reads marked', () {
    expect(
        tileMarkedForRound(
            markedDisplay: 'KQ7', display: 'KQ7', classNo: 10),
        isTrue);
  });

  test('unknown tile display falls back to the recorded round number', () {
    // Hint-only listings carry no code on isolating APs: the round holds.
    expect(
        tileMarkedForRound(
            markedDisplay: 'KQ7',
            markedRounds: {10},
            display: '',
            classNo: 10),
        isTrue);
    expect(
        tileMarkedForRound(
            markedDisplay: 'KQ7',
            markedRounds: {10},
            display: '',
            classNo: 11),
        isFalse);
  });

  test('retaken round re-arms despite the reused number', () {
    // Same number, fresh code after a discard: codes differ, so the
    // number match must not hold.
    expect(
        tileMarkedForRound(
            markedDisplay: 'KQ7',
            markedRounds: {11},
            display: 'ZP2',
            classNo: 11),
        isFalse);
  });

  test('idle tiles and fresh hosts never read marked', () {
    expect(tileMarkedForRound(display: '', classNo: 0), isFalse);
    expect(
        tileMarkedForRound(
            markedDisplay: 'KQ7', display: '', classNo: 0),
        isFalse);
  });
}
