import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('window timer / rotation', () {
    test('6 sub-epochs, 5s each, 30s total', () {
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      final p = WindowParams.generate('CS201-Room301', t0: t0);
      expect(p.jForTime(t0), 0);
      expect(p.jForTime(t0.add(const Duration(seconds: 4, milliseconds: 999))), 0);
      expect(p.jForTime(t0.add(const Duration(seconds: 5))), 1);
      expect(p.jForTime(t0.add(const Duration(seconds: 29))), 5);
      expect(p.jForTime(t0.add(const Duration(seconds: 30))), 6);
      expect(p.jForTime(t0.subtract(const Duration(seconds: 1))), -1);
    });

    test('rotation yields distinct C_j per j', () {
      final p = WindowParams.generate('CS201', t0: DateTime.now().toUtc());
      final cs = List.generate(6, (j) => p.challengeFor(j));
      for (var i = 0; i < 6; i++) {
        for (var k = i + 1; k < 6; k++) {
          expect(cs[i], isNot(cs[k]), reason: 'C_$i == C_$k');
        }
      }
    });

    test('freshness 7s window accepts drift, rejects stale', () {
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      final p = WindowParams.generate('CS201', t0: t0);
      // inside sub-epoch 0
      expect(p.isFresh(0, t0.add(const Duration(seconds: 2))), isTrue);
      // 6s drift into next epoch still within extended acceptance
      expect(p.isFresh(0, t0.add(const Duration(seconds: 8))), isTrue);
      // far future stale
      expect(p.isFresh(0, t0.add(const Duration(seconds: 60))), isFalse);
      // out-of-range j
      expect(p.isFresh(6, t0), isFalse);
      expect(p.isFresh(-1, t0), isFalse);
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

    test('WindowTimer progress/state machine', () {
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      final p = WindowParams(
          sessionId: randBytes(16),
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: t0,
          classLabel: 'CS201');
      final timer = WindowTimer(p);
      expect(timer.state(t0.subtract(const Duration(seconds: 1))),
          WindowState.idle);
      expect(timer.state(t0.add(const Duration(seconds: 10))), WindowState.live);
      expect(timer.state(t0.add(const Duration(seconds: 31))), WindowState.closed);
      expect(timer.remaining(t0.add(const Duration(seconds: 29))).inSeconds,
          lessThanOrEqualTo(1));
      expect(timer.progress(t0), 0.0);
      expect(timer.progress(t0.add(const Duration(seconds: 15))), 0.5);
      expect(timer.progress(t0.add(const Duration(seconds: 60))), 1.0);
    });
  });
}
