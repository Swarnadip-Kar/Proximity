import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

List<double> emb(List<double> v) => v;

void main() {
  group('face-threshold logic (mocked embeddings)', () {
    test('cosine 1.0 self, 0.0 orthogonal, -1 opposite', () {
      expect(cosineSimilarity([1, 0], [1, 0]), closeTo(1.0, 1e-9));
      expect(cosineSimilarity([1, 0], [0, 1]), closeTo(0.0, 1e-9));
      expect(cosineSimilarity([1, 0], [-1, 0]), closeTo(-1.0, 1e-9));
    });

    test('threshold 0.60: pass above, retry below', () {
      final g = FaceGate();
      final now = DateTime.utc(2026, 9, 3, 10, 0, 0);
      expect(g.evaluate(score: 0.82, livenessPass: true, now: now),
          FaceDecision.pass);
      expect(g.isFresh(now), isTrue);
      final g2 = FaceGate();
      expect(g2.evaluate(score: 0.59, livenessPass: true, now: now),
          FaceDecision.retry);
      expect(g2.isFresh(now), isFalse);
    });

    test('liveness fail never passes even with high score', () {
      final g = FaceGate();
      final now = DateTime.utc(2026, 9, 3, 10, 0, 0);
      expect(g.evaluate(score: 0.95, livenessPass: false, now: now),
          FaceDecision.retry);
      expect(g.isFresh(now), isFalse);
    });

    test('2 retries then needs-review', () {
      final g = FaceGate();
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      expect(g.evaluate(score: 0.1, livenessPass: true, now: t0),
          FaceDecision.retry); // fail 1
      expect(g.evaluate(score: 0.1, livenessPass: true, now: t0),
          FaceDecision.retry); // fail 2
      expect(g.evaluate(score: 0.1, livenessPass: true, now: t0),
          FaceDecision.needsReview); // fail 3 → review queue
      expect(g.consecFails, 3);
    });

    test('SK gate: faceValid < 5min; signing throws when stale', () {
      final g = FaceGate();
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      expect(g.canSign, isFalse);
      expect(() => g.requireFreshForSign(t0), throwsStateError);
      g.evaluate(score: 0.9, livenessPass: true, now: t0);
      expect(g.isFresh(t0.add(const Duration(minutes: 4, seconds: 59))), isTrue);
      g.requireFreshForSign(t0.add(const Duration(minutes: 4)));
      expect(g.isFresh(t0.add(const Duration(minutes: 5, seconds: 1))), isFalse);
      expect(() => g.requireFreshForSign(t0.add(const Duration(minutes: 6))),
          throwsStateError);
    });

    test('fresh pass resets fail counter', () {
      final g = FaceGate();
      final t0 = DateTime.utc(2026, 9, 3, 10, 0, 0);
      g.evaluate(score: 0.1, livenessPass: true, now: t0);
      expect(g.consecFails, 1);
      g.evaluate(score: 0.9, livenessPass: true, now: t0);
      expect(g.consecFails, 0);
    });

    test('mocked embedding match vs wrong-face no-sign', () {
      // enrollment template vs live probe
      final enrolled = emb([0.6, 0.8, 0.0, 0.2]);
      final holder = emb([0.61, 0.79, 0.01, 0.19]); // same person
      final stranger = emb([-0.7, 0.1, 0.7, -0.1]); // lent phone
      expect(cosineSimilarity(enrolled, holder), greaterThanOrEqualTo(0.60));
      expect(cosineSimilarity(enrolled, stranger), lessThan(0.60));
    });
  });
}
