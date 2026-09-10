// Window timing + single-use + freshness per §5.1, §5.3, §6.1.
//s
// The window opens when the professor taps Start and stays open until
// they tap Stop: challenges rotate every 5s (j=0,1,2… unbounded) and any
// proof whose sub-epoch is fresh (0 <= now - t_j < 5s + 7s) marks. There is no
// round clock on either side — the student never races a countdown, and
// stopping the window only ends acceptance (after a short grace on the
// host). Single-use is per (ID,j); a new window carries fresh secrets so
// old claims can never validate again.
//
library;

import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import 'primitives.dart';

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

  /// j for elapsed time (unbounded — the window closes only when the
  /// professor stops it); -1 when called before open.
  int jForTime(DateTime now) {
    final el = now.toUtc().difference(t0).inMilliseconds / 1000.0;
    if (el < 0) return -1;
    return (el / kSubEpochSeconds).floor();
  }

  /// Freshness: the proof's sub-epoch started within the last rotation +
  /// drift window. Purely time-anchored — no window-length bound, so proofs
  /// stay valid as long as the window is open. One-sided on purpose: a
  /// FUTURE sub-epoch (now < t_j) is never fresh, so a token cannot be
  /// pre-played before it airs. Same-clock evaluation (professor serves
  /// and verifies), so no negative slack is needed.
  bool isFresh(int j, DateTime now) {
    if (j < 0) return false;
    final dt = now.toUtc().difference(subEpochStart(j));
    return dt >= Duration.zero &&
        dt < const Duration(seconds: kSubEpochSeconds) + kFreshness;
  }
}

/// Tracks (ID, j) single-use. Replayed POST or re-advertised UUID → late/invalid.
class SingleUseTracker {
  final Set<String> _seen = {};

  String _key(String id, int j) => '$id#$j';

  /// Returns true if first use (marks used), false if replay.
  bool claim(String id, int j) => _seen.add(_key(id, j));

  void clear() => _seen.clear();
  int get size => _seen.length;
}
