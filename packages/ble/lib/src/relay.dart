// Front-row relay admission (controlled flood, §6.2).
//
// Part of engine.dart (M4 radio slim): shares the engine's private relay
// state verbatim. Rules — TTL-on-air via the v3 b2..b3 hop count (0 =
// direct, +1 per re-air, stop at kMaxRelayHop), strong signal, unseen
// only ([tokenRelayGuard]: token-keyed, one relay per token per device),
// jitter via [FloodController], halted abort,
// split-horizon, challenge + IP-hint relay, responses never flooded,
// busy-skip releases the key so the next hearing retries.
part of 'engine.dart';

extension ProxBleRelay on ProxBleEngine {
  /// Front-row re-advertise of professor packets (controlled flood,
  /// §6.2): unseen packet + hop budget left + strong signal + jitter,
  /// never what we already advertise (split horizon), never responses.
  /// Both challenge and IP-hint packets relay; responses travel direct
  /// only. v2 hearings (hop=0, no flags byte) upgrade to v3 on re-air
  /// with hop=1; v3 re-airs increment hop. v1 legacy UUIDs carry no
  /// hop/IP and stay v1 (single-relay bound only).
  /// [log]: false silences the routine per-repeat lines (same packet heard
  /// every second) — the relay decision itself is unchanged.
  Future<void> _maybeRelay(BleSighting s, {bool log = true}) async {
    // Relay disarmed (professor mode, or radio off) is a steady state, not
    // an event — return silently so the terminal isn't spammed with skips.
    if (!relayEnabled) return;
    final key = s.key;
    void skip(String why) {
      if (log) BleLog.log('MESH', 'relay skip ($why) ${s.label}');
    }

    if (s.ttl <= 0 || s.hop >= kMaxRelayHop) {
      skip('TTL spent (hop=${s.hop})');
      return;
    }
    if (s.rssiDbm <= kRssiRelayMinDbm) {
      skip('weak rssi=${s.rssiDbm}');
      return;
    }
    if (key == _ownAdvertising) {
      skip('split-horizon/own');
      return;
    }
    if (!_relayCapAllow()) {
      relayDrops++;
      if (log) {
        BleLog.log(
            'MESH', 'relay-cap drop ${s.label} (drops=$relayDrops)');
      }
      return; // token guard untouched: the next hearing retries
    }
    if (!tokenRelayGuard.add(key)) {
      skip('dup');
      return; // unseen only (storm guard: one relay per token per device)
    }
    if (tokenRelayGuard.length > 64) tokenRelayGuard.remove(tokenRelayGuard.first);
    if (log) {
      BleLog.log('MESH', 'forwarding to mesh ${s.label} jitter→re-ADV');
    }
    await Future.delayed(
        FloodController.relayJitter(dense: dense));
    if (_halted) {
      if (log) BleLog.log('MESH', 'relay aborted (halted) ${s.label}');
      return;
    }
    try {
      final bool aired;
      if (s.legacy && s.legacyUuid != null) {
        aired = await _advGuard(
            () => radio.startLegacyUuid(s.legacyUuid!), 'relay ${s.label}');
      } else {
        // Re-air as v3 with hop+1 (v2 hearings upgrade: v2 has no flags
        // byte, so hop arrives 0 and leaves 1). Relayed bit set, dense
        // hint preserved, token/IP/port bytes untouched.
        final nextHop = (s.hop + 1).clamp(0, kAirHopMax);
        final mfg = packAirV3(
            type: s.type,
            token8: s.token8,
            host: s.ipHost,
            port: s.ipPort,
            relayed: true,
            denseHint: s.denseHint,
            hop: nextHop);
        if (mfg == null) {
          tokenRelayGuard.remove(key);
          return;
        }
        aired = await _advGuard(
            () => radio.startAirPacket(kAirSvc, mfg), 'relay ${s.label}');
      }
      if (!aired) {
        // Busy-skip must not burn the token either (see catch below).
        tokenRelayGuard.remove(key);
        return;
      }
      _ownAdvertising = key;
      if (log) BleLog.log('MESH', 'relayed ${s.label} on air');
    } catch (e) {
      // A skipped/failed air attempt must not burn the token: the next
      // hearing of the same rotation retries (back rows starve otherwise).
      tokenRelayGuard.remove(key);
      BleLog.log('MESH', 'relay ADV FAILED: $e');
    }
  }
}
