// Next-challenge waiters.
//
// Part of engine.dart (M4 radio slim): shares the engine's private waiter
// state verbatim. Semantics unchanged — fresh cached challenges resolve
// immediately, live hearings settle all waiters, each waiter's timeout
// expires only itself, stop() settles all as noSignal.
part of 'engine.dart';

extension ProxBleChallengeWait on ProxBleEngine {
  /// Completes every outstanding challenge waiter with [v] and cancels
  /// their timeout timers, so no dangling callbacks survive a radio stop
  /// (or a completed wait).
  void _settleChallengeWaiters(Uint8List? v) {
    for (final w in _challengeWaiters.toList()) {
      if (!w.isCompleted) w.complete(v);
      _challengeTimers.remove(w)?.cancel();
    }
    _challengeWaiters.clear();
  }

  /// Resolves with the next challenge's C_j heard over radio, or null on
  /// [timeout] (dead air — no rotation heard for the whole wait).
  /// Already-heard fresh challenges (≤7s old) resolve immediately so slow
  /// pollers never miss a rotation.
  Future<Uint8List?> nextChallenge(
      {Duration timeout = const Duration(seconds: 31)}) {
    final now = DateTime.now().toUtc();
    for (var i = sightings.length - 1; i >= 0; i--) {
      final s = sightings[i];
      // One-sided freshness (matches WindowParams.isFresh): a sighting
      // timestamped in the future never resolves.
      final age = now.difference(s.at.toUtc());
      if (s.isChallenge &&
          age >= Duration.zero &&
          age < kFreshness) {
        BleLog.log('BLE',
            'heard challenge (cached) tok=${s.shortToken}… rssi=${s.rssiDbm}');
        return Future.value(Uint8List.fromList(s.token8));
      }
    }
    BleLog.log('BLE', 'waiting for challenge over radio…');
    final c = Completer<Uint8List?>();
    _challengeWaiters.add(c);
    _challengeTimers[c] = Timer(timeout, () {
      // Expire ONLY this waiter: completing every waiter here let the
      // shortest timeout kill concurrent longer waits with a spurious
      // noSignal (browse prewarm + listen overlap). Mass-settle stays in
      // _settleChallengeWaiters (radio stop path) only.
      _challengeWaiters.remove(c);
      _challengeTimers.remove(c);
      if (!c.isCompleted) {
        BleLog.log('BLE', 'challenge wait timeout (${timeout.inSeconds}s, noSignal)');
        c.complete(null);
      }
    });
    c.future.then((v) {
      // Same-token echoes (own relay, professor repeat) resolve waiters
      // silently — only a NEW token logs.
      if (v != null) {
        final hex =
            v.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
        if (hex != _lastLiveHex) {
          _lastLiveHex = hex;
          BleLog.log('BLE', 'heard challenge (live) ${v.length}B');
        }
      }
    });
    return c.future;
  }
}
