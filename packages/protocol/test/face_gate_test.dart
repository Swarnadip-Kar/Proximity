// Face-gate policy tests rewritten for Tracks 2+3 (new adapter).
//
// The on-device match runs in the `face_verification` plugin (FaceNet
// scale); this pins the POLICY side only: threshold VALUE 0.70 (plugin
// default, FAR ~0.01%/FRR <2% — the old 0.60/0.80 EdgeFace numbers are
// retired and must not be reused), freshness window, retry counts, and the
// passive-only contract (no blink/turn-head prompts — production passes
// livenessPass:true; nothing gates on an active prompt).
import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('face-gate policy on plugin score scale (no embeddings here)', () {
    test('threshold is the plugin default 0.70, not the old EdgeFace 0.60', () {
      expect(kFaceThreshold, 0.70);
      expect(FaceGate().threshold, 0.70);
    });

    test('threshold 0.70: pass at/above, retry below', () {
      final g = FaceGate();
      final now = DateTime.utc(2026, 9, 3, 10, 0, 0);
      expect(g.evaluate(score: 0.70, livenessPass: true, now: now),
          FaceDecision.pass);
      expect(g.isFresh(now), isTrue);
      final g2 = FaceGate();
      // 0.69 fails on the new scale — and 0.60 (the OLD EdgeFace bar) is
      // firmly a retry now, never a pass.
      expect(g2.evaluate(score: 0.69, livenessPass: true, now: now),
          FaceDecision.retry);
      expect(g2.isFresh(now), isFalse);
      final g3 = FaceGate();
      expect(g3.evaluate(score: 0.60, livenessPass: true, now: now),
          FaceDecision.retry);
    });

    test('passive-only: no prompt gates the verdict (liveness always true)', () {
      // Production never shows blink/turn-head prompts; the adapter passes
      // livenessPass:true unconditionally. A high score still passes and a
      // low score still retries — the prompt plays no role.
      final g = FaceGate();
      final now = DateTime.utc(2026, 9, 3, 10, 0, 0);
      expect(g.evaluate(score: 0.95, livenessPass: true, now: now),
          FaceDecision.pass);
      final g2 = FaceGate();
      expect(g2.evaluate(score: 0.10, livenessPass: true, now: now),
          FaceDecision.retry);
    });

    test('2 retries then needs-review (counts unchanged)', () {
      expect(kFaceMaxRetries, 2);
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
      expect(kFaceValidWindow, const Duration(minutes: 5));
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

    test('marking session budget: 4 sessions then manual path (constant)', () {
      // The per-session burn counting lives in the app (one dead 12s
      // session = one attempt); the protocol pins the budget constant.
      expect(kFaceMaxSessions, 4);
      expect(kFaceRescanInterval, const Duration(seconds: 12));
    });

    test('verifier allowlist prefix pins the plugin namespace', () {
      expect(kVerifierVerPrefix, 'face_verification/');
    });
  });
}
