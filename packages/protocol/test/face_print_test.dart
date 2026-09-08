// FacePrint representation contracts: canonical pipeline, thresholds,
// pre-filter determinism, isolation. See src/face_print.dart (privacy flag
// there applies to everything here).
import 'dart:math';
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

List<double> _unit(Random rng) {
  final v = List<double>.generate(kFacePrintDim, (_) => rng.nextDouble() * 2 - 1);
  final n = sqrt(v.fold(0.0, (a, b) => a + b * b));
  return [for (final x in v) x / n];
}

/// Near-duplicate of [base]: base plus scaled independent noise, kept
/// unit-norm — stands in for "same face, second capture" (eps=0.5 lands at
/// cosine ≈0.89, eps=0.65 at ≈0.84).
List<double> _nearDup(List<double> base, double eps, int seed) {
  final r = _unit(Random(seed));
  final v =
      List<double>.generate(kFacePrintDim, (i) => base[i] + eps * r[i]);
  final n = sqrt(v.fold(0.0, (a, b) => a + b * b));
  return [for (final x in v) x / n];
}

FacePrintDoc _doc(String email, List<double> mean, String ver) =>
    buildFacePrint(org: 'gmail.com', verifierVer: ver, meanEmbedding: mean);

void main() {
  group('face print representation', () {
    test('quantize roundtrip preserves cosine (>0.998)', () {
      final v = _unit(Random(11));
      final rt = faceDequantizeEmbedding(faceQuantizeEmbedding(v));
      expect(cosineSimilarity(v, rt), greaterThan(0.998));
    });

    test('quantized-vs-quantized tracks true cosine within 0.005', () {
      final base = _unit(Random(15));
      final near = _nearDup(base, 0.65, 16);
      final qDelta = (cosineSimilarity(base, near) -
              cosineSimilarity(
                  faceDequantizeEmbedding(faceQuantizeEmbedding(base)),
                  faceDequantizeEmbedding(faceQuantizeEmbedding(near))))
          .abs();
      expect(qDelta, lessThan(0.005));
    });

    test('quantized print is 512 bytes / 684 base64 chars', () {
      final v = _unit(Random(12));
      final q = faceQuantizeEmbedding(v);
      expect(q.length, kFacePrintDim);
      expect(facePrintEncode(q).length, 684);
    });

    test('buckets are deterministic + golden-pinned (seed change = rebucket)',
        () {
      final v = _unit(Random(7));
      final q = faceQuantizeEmbedding(v);
      final twice = [facePrintBuckets(q), facePrintBuckets(q)];
      expect(twice[0], twice[1]);
      expect(twice[0], [
        'b0:b4',
        'b1:37',
        'b2:56',
        'b3:c5',
        'b4:d2',
        'b5:e7',
        'b6:5e',
        'b7:9f',
        'b8:2a',
        'b9:9f',
      ]);
      expect(twice[0].length, kFacePrintBands);
    });

    test('mean of identical stills is the still itself', () {
      final v = _unit(Random(13));
      final m = faceMeanEmbedding([v, v, v, v, v]);
      expect(cosineSimilarity(v, m), greaterThan(0.999999));
    });

    test('mean rejects empty / width-mismatch / zero-norm', () {
      expect(() => faceMeanEmbedding(const []), throwsArgumentError);
      expect(
          () => faceMeanEmbedding([
                List.filled(kFacePrintDim, 0.1),
                List.filled(7, 0.1)
              ]),
          throwsArgumentError);
      expect(
          () => faceMeanEmbedding([List.filled(kFacePrintDim, 0.0)]),
          throwsArgumentError);
    });

    test('doc map roundtrip preserves fields', () {
      final d = _doc('a@gmail.com', _unit(Random(14)), 'v1');
      final rt = FacePrintDoc.fromMap(d.toMap());
      expect(rt.org, 'gmail.com');
      expect(rt.verifierVer, 'v1');
      expect(rt.embQ, d.embQ);
      expect(rt.buckets, d.buckets);
    });
  });

  group('findFaceDuplicate', () {
    test('flags a near-duplicate, clears strangers', () {
      final base = _unit(Random(21));
      final mine = _doc('me@gmail.com', base, 'v1');
      final dup = _doc('other@gmail.com', _nearDup(base, 0.5, 22), 'v1');
      final stranger = _doc('s@gmail.com', _unit(Random(22)), 'v1');
      final hit = findFaceDuplicate(
        myEmail: 'me@gmail.com',
        mine: mine,
        others: {'other@gmail.com': dup, 's@gmail.com': stranger},
      );
      expect(hit, isNotNull);
      expect(hit!.email, 'other@gmail.com');
      expect(hit.score, greaterThanOrEqualTo(kFaceDupThreshold));
    });

    test('strangers alone produce no hit', () {
      final mine = _doc('me@gmail.com', _unit(Random(31)), 'v1');
      final others = {
        for (var i = 0; i < 8; i++)
          'u$i@gmail.com': _doc('u$i@gmail.com', _unit(Random(100 + i)), 'v1'),
      };
      expect(
        findFaceDuplicate(myEmail: 'me@gmail.com', mine: mine, others: others),
        isNull,
      );
    });

    test('own doc never flags itself (re-enroll safe)', () {
      final base = _unit(Random(41));
      final mine = _doc('me@gmail.com', base, 'v1');
      final hit = findFaceDuplicate(
        myEmail: 'ME@gmail.com', // case-insensitive self
        mine: mine,
        others: {'me@gmail.com': mine},
      );
      expect(hit, isNull);
    });

    test('foreign pipeline prints are skipped, never scored', () {
      final base = _unit(Random(51));
      final mine = _doc('me@gmail.com', base, 'v2');
      final old = _doc('old@gmail.com', base, 'v1'); // identical face, old pipe
      expect(
        findFaceDuplicate(
            myEmail: 'me@gmail.com', mine: mine, others: {'old@gmail.com': old}),
        isNull,
      );
    });

    test('corrupt entries are skipped, not fatal', () {
      final mine = _doc('me@gmail.com', _unit(Random(61)), 'v1');
      final bad = FacePrintDoc(
          org: 'gmail.com',
          verifierVer: 'v1',
          embQ: '!!!not-base64!!!',
          buckets: const [],
          updatedAtMillis: 0);
      final short = FacePrintDoc(
          org: 'gmail.com',
          verifierVer: 'v1',
          embQ: facePrintEncode(Uint8List(7)),
          buckets: const [],
          updatedAtMillis: 0);
      expect(
        findFaceDuplicate(myEmail: 'me@gmail.com', mine: mine, others: {
          'bad@gmail.com': bad,
          'short@gmail.com': short,
        }),
        isNull,
      );
    });

    test('custom threshold honored at the boundary', () {
      final base = _unit(Random(71));
      final mine = _doc('me@gmail.com', base, 'v1');
      final near = _doc('n@gmail.com', _nearDup(base, 0.8, 72), 'v1');
      final score = cosineSimilarity(
          faceDequantizeEmbedding(facePrintDecode(mine.embQ)),
          faceDequantizeEmbedding(facePrintDecode(near.embQ)));
      expect(
        findFaceDuplicate(
            myEmail: 'me@gmail.com',
            mine: mine,
            others: {'n@gmail.com': near},
            threshold: score + 0.001),
        isNull,
      );
      expect(
        findFaceDuplicate(
            myEmail: 'me@gmail.com',
            mine: mine,
            others: {'n@gmail.com': near},
            threshold: score),
        isNotNull,
      );
    });
  });
}
