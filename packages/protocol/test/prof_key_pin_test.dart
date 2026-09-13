import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  const a =
      '9a3b7c1d4e5f60719a3b7c1d4e5f60719a3b7c1d4e5f60719a3b7c1d4e5f6071';
  const b =
      'b7e4a9215c6d8093b7e4a9215c6d8093b7e4a9215c6d8093b7e4a9215c6d8093';

  test('unknown when no cache (first-seen TOFU)', () {
    expect(
        evaluateProfPin(presentedPkPHex: a, pinned: const [], hasCache: false),
        ProfPinVerdict.unknown);
  });

  test('known when presented in pin list (case-insensitive)', () {
    expect(
        evaluateProfPin(
            presentedPkPHex: a.toUpperCase(),
            pinned: [a],
            hasCache: true),
        ProfPinVerdict.known);
  });

  test('mismatch when cache has email but not presented key', () {
    expect(
        evaluateProfPin(
            presentedPkPHex: b, pinned: [a], hasCache: true),
        ProfPinVerdict.mismatch);
  });

  test('mismatch on malformed presented key', () {
    expect(
        evaluateProfPin(
            presentedPkPHex: 'zz', pinned: [a], hasCache: true),
        ProfPinVerdict.mismatch);
  });

  test('merge dedupes and caps at 8 newest', () {
    var list = <ProfKeyEntry>[];
    for (var i = 1; i <= 10; i++) {
      final hex = i.toRadixString(16).padLeft(64, '0');
      list = mergeProfPinKeys(
          existing: list, newPkPHex: hex, nowMillis: 1000 + i);
    }
    expect(list.length, kProfPinMaxKeys);
    // Oldest two evicted, newest kept.
    expect(list.first.createdAtMillis, 1003);
    expect(list.last.createdAtMillis, 1010);
  });

  test('merge ignores invalid new key', () {
    final list = mergeProfPinKeys(
        existing: const [], newPkPHex: 'bad', nowMillis: 1);
    expect(list, isEmpty);
  });
}
