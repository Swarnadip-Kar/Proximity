// Front-row relay admission (controlled flood, §6.2).
//
// Part of engine.dart (M4 radio slim): shares the engine's private relay
// state verbatim. Rules are unchanged — TTL left, strong signal, unseen
// only ([tokenRelayGuard]: token-keyed, one relay per token per device —
// sender-keyed dedup would re-air each token once per path in a full
// hall), jitter via [FloodController], halted abort,
// split-horizon, challenge + IP-hint relay, responses never flooded,
// busy-skip releases the key so the next hearing retries.
part of 'engine.dart';

extension ProxBleRelay on ProxBleEngine {
  /// Front-row re-advertise of professor packets (controlled flood,
  /// §6.2): unseen packet + TTL left + strong signal + jitter, never what
  /// we already advertise (split horizon), never responses (no flooding).
  /// Both challenge and IP-hint packets relay (back rows need the server
  /// address too); responses travel direct (or directed GATT write) only.
  /// Air packets carry no TTL byte, so direct receptions arrive with
  /// ttl=[kTtlOriginate]; explicit 0 still drops.
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

    if (s.ttl <= 0) {
      skip('TTL spent');
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
        // Relays preserve the heard format verbatim (v2 stays v2, v3 stays
        // v3) and set the v3 relayed flag on re-air — never upgrade v2.
        final mfg = s.version == kAirVerV3
            ? packAirV3(
                type: s.type,
                token8: s.token8,
                host: s.ipHost,
                port: s.ipPort,
                relayed: true,
                denseHint: s.denseHint)!
            : packAir(
                type: s.type,
                token8: s.token8,
                host: s.ipHost,
                port: s.ipPort)!;
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
