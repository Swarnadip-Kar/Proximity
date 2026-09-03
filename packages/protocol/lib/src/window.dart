// Window timing + single-use + freshness per §5.1, §5.3, §6.1.
//
// 30s window = 6 × 5s sub-epochs j=0..5.
// Rotation: stop/start advertise every 5s.
// Freshness: |now - t_j| < 7s. (ID,j) single-use, else late/invalid.
library;

import 'dart:typed_data';

import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';

/// Immutable per-window secrets (professor, never leaves host). §5.1.
class WindowParams {
  final Uint8List sessionId; // 16 B rand(128) per lecture
  final Uint8List windowId; // 6 B rand(48) per window
  final Uint8List secret; // 32 B S_w rand(256) per window
  final DateTime t0; // window open time (professor clock, authority)
  final String classLabel;

  WindowParams({
    required this.sessionId,
    required this.windowId,
    required this.secret,
    required this.t0,
    required this.classLabel,
  })  : assert(sessionId.length == kSessionIdBytes),
        assert(windowId.length == kWindowIdBytes),
        assert(secret.length == kWindowSecretBytes);

  factory WindowParams.generate(String classLabel, {DateTime? t0}) {
    return WindowParams(
      sessionId: randBytes(kSessionIdBytes),
      windowId: randBytes(kWindowIdBytes),
      secret: randBytes(kWindowSecretBytes),
      t0: (t0 ?? DateTime.now()).toUtc(),
      classLabel: classLabel,
    );
  }

  Uint8List challengeFor(int j) =>
      ProxCrypto.challengeForSubEpoch(secret, windowId, j);

  String get displayCode => ProxCrypto.displayCode(windowId);

  DateTime subEpochStart(int j) =>
      t0.add(Duration(seconds: j * kSubEpochSeconds));

  /// j for elapsed time; clamps to 0..5, returns -1 if before, 6 if after.
  int jForTime(DateTime now) {
    final el = now.toUtc().difference(t0).inMilliseconds / 1000.0;
    if (el < 0) return -1;
    final j = (el / kSubEpochSeconds).floor();
    if (j >= kSubEpochsPerWindow) return kSubEpochsPerWindow;
    return j;
  }

  bool get isClosedAtNow => jForTime(DateTime.now().toUtc()) >= kSubEpochsPerWindow;

  /// Freshness: |now - t_j| < 7s where t_j is sub-epoch start + half? Spec:
  /// |now - t_j| < 7s (5s + drift). We anchor t_j = sub-epoch start.
  /// Accepts current j and adjacent sub-epoch within drift.
  bool isFresh(int j, DateTime now) {
    if (j < 0 || j >= kSubEpochsPerWindow) return false;
    final tj = subEpochStart(j);
    final dt = now.toUtc().difference(tj).abs();
    // Accept if within freshness of the sub-epoch start..end extended:
    // now in [t_j - 7s, t_j + 5s + 7s).
    return now.toUtc().isAfter(tj.subtract(kFreshness)) &&
        now.toUtc().isBefore(tj.add(
            const Duration(seconds: kSubEpochSeconds) + kFreshness)) &&
        dt.inMilliseconds <=
            (kSubEpochSeconds * 1000 + kFreshness.inMilliseconds);
  }
}

/// Tracks (ID, j) single-use. Replayed POST or re-advertised UUID → late/invalid.
class SingleUseTracker {
  final Set<String> _seen = {};

  String _key(String id, int j) => '$id#$j';

  /// Returns true if first use (marks used), false if replay.
  bool claim(String id, int j) => _seen.add(_key(id, j));

  bool isUsed(String id, int j) => _seen.contains(_key(id, j));

  void clear() => _seen.clear();
  int get size => _seen.length;
}

/// Window state machine for UI (prof start→LIVE→close→export; student join→...).
enum WindowState { idle, live, closed }

class WindowTimer {
  final WindowParams params;
  WindowTimer(this.params);

  Duration remaining(DateTime now) {
    final end = params.t0.add(const Duration(seconds: kWindowSeconds));
    final r = end.difference(now.toUtc());
    return r.isNegative ? Duration.zero : r;
  }

  double progress(DateTime now) {
    final el =
        now.toUtc().difference(params.t0).inMilliseconds / 1000.0;
    return (el / kWindowSeconds).clamp(0.0, 1.0);
  }

  WindowState state(DateTime now) {
    final j = params.jForTime(now);
    if (j < 0) return WindowState.idle;
    if (j >= kSubEpochsPerWindow) return WindowState.closed;
    return WindowState.live;
  }
}
