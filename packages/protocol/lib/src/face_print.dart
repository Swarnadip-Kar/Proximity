// FacePrint: compact face representation for same-face duplicate
// detection — LOCAL-SESSION ONLY (§4).
//
// NOTHING here reaches the cloud, ever: during marking the student's proof
// carries ONE quantized vector to the professor's phone over the existing
// local HTTPS channel; the professor holds email→vector in RAM for the
// open window only, compares each incoming vector against the rest, and
// wipes everything on window close / hosting end. The cloud sync carries
// only final statuses (PRESENT/ABSENT/FLAGGED). There is no biometric
// store to breach, enumerate, or retain — the entire cloud
// read-quota/enumeration/retention analysis of the earlier claim-time
// design is moot by construction (no queries, no collection, no quota).
//
// What is carried per prove: ONE int8-quantized mean FaceNet embedding
// (512 bytes, base64) — no images, no names, no rolls. Honesty notes
// (unchanged from the earlier analysis): quantized embeddings are NOT
// one-way (published template-inversion reconstructs recognizable faces
// from such vectors), but the blast radius is one classroom LAN for one
// window — the professor already sees every face physically — and RAM
// lifetime is minutes. Proofs without vectors (legacy) mark normally
// with no dup participation; custom clients can omit/garbage vectors
// (evasion only: transplanting another holder's vector merely self-flags,
// and the Sig_s face-ticket crypto is untouched).
//
// Design:
// - Canonical pipeline (identical on every phone): mean over the enrolled
//   stills → L2 normalize → int8 quantize → base64. Buckets + embQ derive
//   from the QUANTIZED bytes (integer math only — bit-deterministic on
//   native and web).
// - Session compare is EXACT cosine over dequantized vectors, O(session)
//   per prove (~500×512 mult-adds ≈ single-digit ms — measured in the
//   transport test, not asserted). No pre-filter, no index, no quota: the
//   simhash buckets below stay as tested primitives but the local path
//   does not need them (kept, not rewritten, per the shared-layer rule).
// - Flag at [kFaceDupThreshold]: STRICTER than the 0.70 marking gate.
//   Different error costs (a group-flag pages the professor mid-lecture;
//   a marking reject costs a rescan), expected false pairs <1/session at
//   pilot scale, and blatant same-lecture proxy (same holder, minutes
//   apart, typically 0.85+) still caught. Residual misses (0.70–0.80 true
//   dupes) and twin false flags (1-tap professor resolve — both faces are
//   IN THE ROOM) are the accepted classes. Retune only from measured ROC.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'face_gate.dart';

/// FaceNet embedding width (plugin TFLite model output; the plugin's
/// registerFromEmbedding rejects anything else).
const kFacePrintDim = 512;

/// Session duplicate flag threshold — STRICTER than the 0.70 marking
/// gate on purpose (see file header: group-flag error costs, false-pair
/// budget, blatant-proxy capture). Retune only from measured ROC.
const kFaceDupThreshold = 0.80;

/// Simhash banding: 10 bands × 8 rows = 80 bits. Fits one
/// arrayContainsAny (max 10) — the whole pre-filter is ONE query.
const kFacePrintBands = 10;

/// Bits per band. 8 keeps stranger band-agreement at 2^-8 while holding
/// recall ≈0.9 at cosine 0.85 (see file header for the trade table).
const kFacePrintRows = 8;

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

/// LAN prove-body encoding: quantize the mean embedding + base64 (684
/// chars over the existing HTTPS channel — no new transport).
String faceVecEncode(List<double> meanEmbedding) =>
    facePrintEncode(faceQuantizeEmbedding(meanEmbedding));

/// Inverse of [faceVecEncode]: dequantized floats, or null on garbage
/// (fail-soft — a proof without a usable vector marks normally with no
/// dup participation, same as a legacy proof).
List<double>? faceVecDecode(String encoded) {
  try {
    final q = facePrintDecode(encoded);
    if (q.length != kFacePrintDim) return null;
    return faceDequantizeEmbedding(q);
  } catch (_) {
    return null;
  }
}

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

/// The session duplicate-check record (RAM-only on the professor's phone
/// during the open window; never serialized to the cloud). Pure math +
/// scoping tags — NEVER names, rolls, photos, or keys.
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

/// Exact compare over one window's in-memory vectors. Skips the prover's
/// own entry (same-device retries share the vector) and foreign-pipeline
/// vectors (incomparable). Returns EVERY hit at/above [threshold],
/// best-first — pairs AND larger groups (A/B/C…) all surface so the
/// roster can flag every involved entry. [others] maps lowercased Gmail →
/// print. Pure — no I/O.
List<FaceDuplicate> findFaceDuplicates({
  required String myEmail,
  required FacePrintDoc mine,
  required Map<String, FacePrintDoc> others,
  double threshold = kFaceDupThreshold,
}) {
  Uint8List mineQ;
  try {
    mineQ = facePrintDecode(mine.embQ);
  } catch (_) {
    return const []; // garbage own vector: fail soft, no flag
  }
  if (mineQ.length != kFacePrintDim) return const [];
  final mineF = faceDequantizeEmbedding(mineQ);
  final mineSelf = cosineSimilarity(mineF, mineF);
  if (mineSelf < 0.99) return const []; // corrupt own vector: fail closed
  final me = myEmail.toLowerCase();
  final hits = <FaceDuplicate>[];
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
    if (score >= threshold) hits.add(FaceDuplicate(email: e.key, score: score));
  }
  hits.sort((a, b) => b.score.compareTo(a.score));
  return hits;
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
  final hits = findFaceDuplicates(
      myEmail: myEmail, mine: mine, others: others, threshold: threshold);
  return hits.isEmpty ? null : hits.first;
}
