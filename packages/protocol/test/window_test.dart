import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('window timer / rotation', () {
    test('j grows unbounded (no clock expiry)', () {
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      final p = WindowParams.generate('CS201-Room301', t0: t0);
      expect(p.jForTime(t0), 0);
      expect(p.jForTime(t0.add(const Duration(seconds: 4, milliseconds: 999))), 0);
      expect(p.jForTime(t0.add(const Duration(seconds: 5))), 1);
      expect(p.jForTime(t0.add(const Duration(seconds: 29))), 5);
      // No 30s expiry: the window closes only when the professor stops it.
      expect(p.jForTime(t0.add(const Duration(seconds: 30))), 6);
      expect(p.jForTime(t0.add(const Duration(seconds: 122))), 24);
      expect(p.jForTime(t0.subtract(const Duration(seconds: 1))), -1);
    });

    test('rotation yields distinct C_j per j', () {
      final p = WindowParams.generate('CS201', t0: DateTime.now().toUtc());
      final cs = List.generate(12, (j) => p.challengeFor(j));
      for (var i = 0; i < 12; i++) {
        for (var k = i + 1; k < 12; k++) {
          expect(cs[i], isNot(cs[k]), reason: 'C_$i == C_$k');
        }
      }
    });

    test('freshness 7s window accepts drift, rejects stale (any j)', () {
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      final p = WindowParams.generate('CS201', t0: t0);
      // inside sub-epoch 0
      expect(p.isFresh(0, t0.add(const Duration(seconds: 2))), isTrue);
      // 6s drift into next epoch still within extended acceptance
      expect(p.isFresh(0, t0.add(const Duration(seconds: 8))), isTrue);
      // far future stale
      expect(p.isFresh(0, t0.add(const Duration(seconds: 60))), isFalse);
      // late sub-epochs verify the same way (window still open)
      expect(p.isFresh(24, t0.add(const Duration(seconds: 122))), isTrue);
      expect(p.isFresh(24, t0.add(const Duration(seconds: 180))), isFalse);
      // negative j never valid
      expect(p.isFresh(-1, t0), isFalse);
    });

    test('freshness is one-sided: future sub-epochs never fresh', () {
      // A token cannot be pre-played before it airs: now < t_j rejects,
      // even 1s early. (The old abs() window accepted j+1 up to 7s early.)
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      final p = WindowParams.generate('CS201', t0: t0);
      expect(p.isFresh(1, t0.add(const Duration(seconds: 4))), isFalse);
      expect(p.isFresh(1, t0.add(const Duration(seconds: 4999, milliseconds: 999))),
          isFalse);
      expect(p.isFresh(1, t0.add(const Duration(seconds: 5))), isTrue);
      // Exact-rotation boundary: [0, 5s + 7s).
      expect(p.isFresh(0, t0), isTrue);
      expect(p.isFresh(0, t0.add(const Duration(seconds: 11, milliseconds: 999))),
          isTrue);
      expect(p.isFresh(0, t0.add(const Duration(seconds: 12))), isFalse);
    });

    test('(ID,j) single-use: replay rejected', () {
      final t = SingleUseTracker();
      expect(t.claim('12342210', 0), isTrue);
      expect(t.claim('12342210', 0), isFalse);
      expect(t.claim('12342210', 1), isTrue);
      expect(t.claim('12342211', 0), isTrue);
      expect(t.size, 3);
    });

    test('display code 3 chars from windowID, stable', () {
      final p = WindowParams.generate('CS201', t0: DateTime.now().toUtc());
      expect(p.displayCode.length, 3);
      expect(ProxCrypto.displayCode(p.windowId), p.displayCode);
      for (final c in p.displayCode.codeUnits) {
        expect(kDisplayAlphabet.codeUnits, contains(c));
      }
    });
  });
}
