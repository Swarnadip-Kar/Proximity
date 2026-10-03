// Browse-ordinal refresh rule: the waiting-room poll feeds the tile map.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/mark/browse_list.dart';
import 'package:proximity_app/screens/student_home.dart';
import 'package:proximity_app/widgets/class_ordinal.dart';

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
            markedDisplay: 'KQ7',
            display: 'KQ7',
            classNo: 20,
            roundNo: 2),
        isTrue);
  });

  test('unknown tile display falls back to the recorded round key', () {
    // Hint-only listings carry no code on isolating APs: the round holds.
    expect(
        tileMarkedForRound(
            markedDisplay: 'KQ7',
            markedRounds: {'20:2'},
            display: '',
            classNo: 20,
            roundNo: 2),
        isTrue);
    expect(
        tileMarkedForRound(
            markedDisplay: 'KQ7',
            markedRounds: {'20:2'},
            display: '',
            classNo: 20,
            roundNo: 3),
        isFalse);
  });

  test('retaken round re-arms despite matching numbers', () {
    // Same numbers, fresh code after a discard: codes differ, so the
    // round key must not hold.
    expect(
        tileMarkedForRound(
            markedDisplay: 'KQ7',
            markedRounds: {'20:2'},
            display: 'ZP2',
            classNo: 20,
            roundNo: 2),
        isFalse);
  });

  test('idle tiles and fresh hosts never read marked', () {
    expect(tileMarkedForRound(display: '', classNo: 0, roundNo: 0),
        isFalse);
    expect(
        tileMarkedForRound(
            markedDisplay: 'KQ7', display: '', classNo: 0, roundNo: 0),
        isFalse);
  });

  test('trail labels the actual round, not the mark count', () {
    // Missed R1, marked R2: the trail must read R2, not R1.
    expect(
        roundTrailLabel(
            roundNo: 2, fallbackCount: 1, detail: 'HXK · 18:31:03'),
        'R2 · HXK · 18:31:03');
    // Unknown round: count fallback (never worse than before).
    expect(
        roundTrailLabel(
            roundNo: 0, fallbackCount: 1, detail: 'HXK · 18:31:03'),
        'R1 · HXK · 18:31:03');
  });

  test('round ordinal pairs with the class ordinal', () {
    expect(roundOrdinalLabel(2), 'Round 2');
    expect(roundOrdinalLabel(0), isEmpty);
    expect(roundOrdinalLabel(-1), isEmpty);
  });
}
