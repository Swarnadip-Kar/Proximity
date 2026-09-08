// FacePrint: cloud-comparable face representation for same-face enrollment
// dedup (one face must not enroll as two Gmails on two devices). §4.
//
// PRIVACY FLAG (read before touching this file): storing a FacePrint in
// cloud Firestore REVERSES the standing guarantee that face-derived data
// never leaves the device. What is stored per enrolled Gmail is ONE
// int8-quantized mean FaceNet embedding (512 bytes, base64) + 10 simhash
// bucket strings + org/pipeline tags — no images, no names, no rolls.
// Irreversibility: quantized embeddings are NOT one-way. Published
// template-inversion work reconstructs recognizable faces from unprotected
// deep embeddings (Mai et al., TPAMI 2019; Shahreza & Marcel black-box
// reconstruction; diffusion-based inversion, 2026) and recovers
// soft-biometrics (sex/age/race, Terhörst et al. 2020); int8 quantization
// barely degrades inversion or identity matching. Treat every stored byte
// as biometric personal data (GDPR sensitive-data class), readable by any
// signed-in same-org user (claim-time compare runs client-side — there is
// no backend), retained indefinitely (no delete API, no TTL on Spark),
// enumerated by paging org queries. Why it is judged worth it: same-face
// second-Gmail enrollment on a second phone is a stock-app proxy vector
// (carry two phones, both pass holder check) that NOTHING else in the
// system detects — install/cooldown/pkD-audit all key on Gmail+device,
// never on the holder — and proxy-hard attendance is the entire point of
// the app (§1 goal 1). Mitigations: explicit enrollment consent copy,
// strict flag threshold (0.75, not the 0.70 marking gate), never a dead
// end (recapture retry + manual attendance), never auto-accusation copy,
// self-exclusion (re-enroll never flags itself), pipeline-scoped compare.
// Follow-ups if this proves load-bearing: Blaze Function for server-side
// compare (no client-readable biometrics), institute-domain orgs, TTL /
// delete story, measured ROC retune.
//
// Design (Spark-only: queries + rules, no backend compute):
// - Canonical pipeline (identical on every client): mean over the enrolled
//   stills → L2 normalize → int8 quantize → buckets + embQ BOTH derived
//   from the QUANTIZED bytes (integer math only — bit-deterministic on
//   native and web, unlike float-transcendental projections).
// - Pre-filter: 80-bit simhash (Rademacher ±1 hyperplanes from a fixed
//   xorshift32 seed — no stored matrix), banded 10×8. One Firestore query:
//   where org == X AND buckets arrayContainsAny [10 values], limit 25.
//   Recall ≈0.91 at cosine 0.85, ≈0.73 at 0.75; stranger shortlist ≈4% of
//   org per enrollment (N=500 → ~20 reads vs 500 naive; enrollment-week
//   170/day → ~3.4k reads/day vs 85k naive — naive blows the 50k/day Spark
//   quota, bucketed fits with headroom).
// - Exact compare client-side on the shortlist: cosine over dequantized
//   vectors, flag at [kFaceDupThreshold]. Firestore bills per DOCUMENT
//   read, not per byte — quantization saves storage/bandwidth, buckets
//   save reads. Do not "optimize" by dropping the buckets.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'face_gate.dart';

/// FaceNet embedding width (plugin TFLite model output; the plugin's
/// registerFromEmbedding rejects anything else).
const kFacePrintDim = 512;

/// Cross-user duplicate flag threshold — STRICTER than the 0.70 marking
/// gate on purpose. A marking false-reject costs a rescan; a duplicate
/// false-flag blocks self-service enrollment (twins/siblings are the known
/// FP class → manual path). 0.75 catches blatant same-face captures
/// (same person, two phones: typically 0.80+) while keeping stranger FP
/// near the vendor FAR tail. Retune only from measured ROC, never by feel.
const kFaceDupThreshold = 0.75;

/// Simhash banding: 10 bands × 8 rows = 80 bits. Fits one
/// arrayContainsAny (max 10) — the whole pre-filter is ONE query.
const kFacePrintBands = 10;

/// Bits per band. 8 keeps stranger band-agreement at 2^-8 while holding
/// recall ≈0.9 at cosine 0.85 (see file header for the trade table).
const kFacePrintRows = 8;

/// Shortlist cap per enrollment check. Bounds the per-enrollment read
/// cost even if an org's buckets collide pathologically.
const kFacePrintQueryLimit = 25;

/// Fixed seed for the Rademacher hyperplane stream. Arbitrary, pinned by
/// the golden bucket test — changing it re-buckets every stored print
/// (old prints become unfindable until re-enrolled).
const kFacePrintSeed = 0x243F6A88;

/// L2-renormalized mean over per-still embeddings (the plugin stores one
/// 512-d record per enroll slot; the print summarizes all of them).
/// Throws [ArgumentError] on empty input, width mismatch, or zero norm.
List<double> faceMeanEmbedding(List<List<double>> embeddings) {
  if (embeddings.isEmpty) {
    throw ArgumentError('faceMeanEmbedding needs at least one embedding');
  }
  final mean = List<double>.filled(kFacePrintDim, 0.0);
  for (final e in embeddings) {
    if (e.length != kFacePrintDim) {
      throw ArgumentError(
          'faceMeanEmbedding needs width $kFacePrintDim, got ${e.length}');
    }
    for (var i = 0; i < kFacePrintDim; i++) {
      mean[i] += e[i];
    }
  }
  final n = embeddings.length;
  var norm = 0.0;
  for (var i = 0; i < kFacePrintDim; i++) {
    mean[i] /= n;
    norm += mean[i] * mean[i];
  }
  norm = sqrt(norm);
  if (norm == 0) {
    throw ArgumentError('faceMeanEmbedding: zero-norm mean');
  }
  for (var i = 0; i < kFacePrintDim; i++) {
    mean[i] /= norm;
  }
  return mean;
}

/// int8 quantization of a (normalized) embedding: clamp(-1,1)×127, round.
/// 512 bytes — the FaceNet paper notes embeddings quantize to 1 byte/dim
/// without accuracy loss. Self-roundtrip cosine lands >0.998 and, what
/// matters for dedup, quantized-vs-quantized cosine tracks the true cosine
/// within ±0.005 (both sides share the same canonical quantization).
Uint8List faceQuantizeEmbedding(List<double> embedding) {
  if (embedding.length != kFacePrintDim) {
    throw ArgumentError(
        'faceQuantizeEmbedding needs width $kFacePrintDim, got ${embedding.length}');
  }
  final out = Uint8List(kFacePrintDim);
  for (var i = 0; i < kFacePrintDim; i++) {
    final v = (embedding[i].clamp(-1.0, 1.0) * 127).round().clamp(-127, 127);
    out[i] = v & 0xFF;
  }
  return out;
}

/// Inverse of [faceQuantizeEmbedding]: signed bytes back to [-1,1] floats.
List<double> faceDequantizeEmbedding(Uint8List quantized) {
  if (quantized.length != kFacePrintDim) {
    throw ArgumentError(
        'faceDequantizeEmbedding needs width $kFacePrintDim, got ${quantized.length}');
  }
  return List<double>.generate(kFacePrintDim, (i) {
    final b = quantized[i];
    return (b > 127 ? b - 256 : b) / 127.0;
  });
}

String facePrintEncode(Uint8List quantized) => base64Encode(quantized);

Uint8List facePrintDecode(String encoded) =>
    Uint8List.fromList(base64Decode(encoded));

/// Rademacher (±1) hyperplane signs, streamed from a fixed xorshift32 —
/// pure integer math, bit-identical on every platform (Gaussian Box-Muller
/// would drag in libm transcendentals that differ native-vs-web and split
/// buckets across phones). Layout: [band][row][dim], value 0/1.
final Uint8List _kSigns = _buildSigns();

Uint8List _buildSigns() {
  var s = kFacePrintSeed;
  final out = Uint8List(kFacePrintBands * kFacePrintRows * kFacePrintDim);
  for (var i = 0; i < out.length; i++) {
    s ^= ((s << 13) & 0xFFFFFFFF);
    s &= 0xFFFFFFFF;
    s ^= s >> 17;
    s ^= ((s << 5) & 0xFFFFFFFF);
    s &= 0xFFFFFFFF;
    out[i] = s & 1;
  }
  return out;
}

/// Simhash buckets for the canonical (quantized) vector: one
/// `b{band}:{2 hex}` string per band. Buckets are derived from the
/// QUANTIZED bytes so every client hashes identical input.
List<String> facePrintBuckets(Uint8List quantized) {
  if (quantized.length != kFacePrintDim) {
    throw ArgumentError(
        'facePrintBuckets needs width $kFacePrintDim, got ${quantized.length}');
  }
  final signed = List<int>.generate(
      kFacePrintDim, (i) => quantized[i] > 127 ? quantized[i] - 256 : quantized[i]);
  final out = <String>[];
  for (var b = 0; b < kFacePrintBands; b++) {
    var bits = 0;
    for (var r = 0; r < kFacePrintRows; r++) {
      var acc = 0;
      final base = (b * kFacePrintRows + r) * kFacePrintDim;
      for (var i = 0; i < kFacePrintDim; i++) {
        acc += _kSigns[base + i] == 1 ? signed[i] : -signed[i];
      }
      if (acc >= 0) bits |= (1 << r);
    }
    out.add('b$b:${bits.toRadixString(16).padLeft(2, '0')}');
  }
  return out;
}

/// The cloud-stored duplicate-check record. Pure math + scoping tags —
/// NEVER names, rolls, photos, or keys (the doc id carries the Gmail for
/// one-print-per-Gmail overwrite semantics; readers of a shortlist see
/// matched doc ids transiently — stated cost of client-side compare).
class FacePrintDoc {
  /// Org scope (Google-account domain), '' never stored (rules refuse).
  final String org;

  /// Pipeline tag (`face_verification/<pkgVer>+<assetHash8>`) — only
  /// same-pipeline prints are comparable; cross-pipeline pairs are
  /// skipped, never scored.
  final String verifierVer;

  /// base64 int8 mean embedding (512 bytes → 684 chars).
  final String embQ;

  /// 10 simhash bucket strings (indexed array, pre-filter only).
  final List<String> buckets;

  final int updatedAtMillis;

  const FacePrintDoc({
    required this.org,
    required this.verifierVer,
    required this.embQ,
    required this.buckets,
    required this.updatedAtMillis,
  });

  Map<String, dynamic> toMap() => {
        'org': org,
        'verifierVer': verifierVer,
        'embQ': embQ,
        'buckets': buckets,
        'updatedAtMillis': updatedAtMillis,
      };

  static FacePrintDoc fromMap(Map<String, dynamic> m) => FacePrintDoc(
        org: m['org'] as String? ?? '',
        verifierVer: m['verifierVer'] as String? ?? '',
        embQ: m['embQ'] as String? ?? '',
        buckets: [(m['buckets'] as List? ?? const [])]
            .expand((e) => e)
            .map((e) => '$e')
            .toList(),
        updatedAtMillis: (m['updatedAtMillis'] as num?)?.toInt() ?? 0,
      );
}

/// Builds the canonical print: quantize the mean, derive buckets + embQ
/// from the quantized bytes (single canonical input — see file header).
FacePrintDoc buildFacePrint({
  required String org,
  required String verifierVer,
  required List<double> meanEmbedding,
  int? updatedAtMillis,
}) {
  final q = faceQuantizeEmbedding(meanEmbedding);
  return FacePrintDoc(
    org: org,
    verifierVer: verifierVer,
    embQ: facePrintEncode(q),
    buckets: facePrintBuckets(q),
    updatedAtMillis: updatedAtMillis ?? 0,
  );
}

/// One flagged pair: the OTHER Gmail whose print matched.
class FaceDuplicate {
  final String email;
  final double score;
  const FaceDuplicate({required this.email, required this.score});
}

/// Exact compare over a bucket shortlist. Skips the caller's own doc
/// (same-Gmail re-enroll must never flag itself) and foreign-pipeline
/// prints (incomparable — the stale-pipeline re-face check bounds that
/// window). Returns the best hit at/above [threshold], else null.
/// [others] maps lowercased Gmail → print. Pure — no I/O.
FaceDuplicate? findFaceDuplicate({
  required String myEmail,
  required FacePrintDoc mine,
  required Map<String, FacePrintDoc> others,
  double threshold = kFaceDupThreshold,
}) {
  final mineQ = facePrintDecode(mine.embQ);
  if (mineQ.length != kFacePrintDim) return null;
  final mineF = faceDequantizeEmbedding(mineQ);
  final mineSelf = cosineSimilarity(mineF, mineF);
  if (mineSelf < 0.99) return null; // corrupt own print: fail closed, no flag
  final me = myEmail.toLowerCase();
  FaceDuplicate? best;
  for (final e in others.entries) {
    if (e.key.toLowerCase() == me) continue;
    if (e.value.verifierVer != mine.verifierVer) continue;
    Uint8List theirQ;
    try {
      theirQ = facePrintDecode(e.value.embQ);
    } catch (_) {
      continue;
    }
    if (theirQ.length != kFacePrintDim) continue;
    final score = cosineSimilarity(mineF, faceDequantizeEmbedding(theirQ));
    if (score >= threshold && (best == null || score > best.score)) {
      best = FaceDuplicate(email: e.key, score: score);
    }
  }
  return best;
}
