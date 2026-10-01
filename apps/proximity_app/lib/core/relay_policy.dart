// Relay policy: which devices re-air challenges (active mesh) vs listen
// passively (prove over WiFi, never ADV).
//
// Old phones + iPhones drown in the BLE storm (scan→parse→ADV churn +
// CoreBluetooth throttling + background pause). Passive mode keeps marking
// working while cutting ~1 ADV/10s/device from the hall.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'platformx.dart';

/// Below this much total RAM an Android phone listens passively instead
/// of relaying (old-phone storm shelter). 4 GiB: 2–3 GB devices and the
/// OS low-RAM tier stay out of the flood; 6 GB+ phones keep covering
/// back rows. Tunable without a wire change.
const int kLowRamPassiveBytes = 4 * 1024 * 1024 * 1024;

/// Native memory channel (same channel as the hardware-id read — no new
/// permission, no new plugin). Returns `{totalMemBytes, lowRamDevice}` on
/// Android; missing anywhere else (tests, desktop, iOS — which never
/// reaches it).
const MethodChannel _memChannel =
    MethodChannel('org.iitbhilai.proximity/hardware_id');

/// Pure decision: OS low-RAM flag wins; otherwise total RAM under the
/// floor is passive. Unknown RAM (0) with no flag stays active
/// (fail-open to today's behavior — never strand a capable phone).
bool passiveForMemory({required bool lowRamDevice, required int totalMemBytes}) {
  if (lowRamDevice) return true;
  if (totalMemBytes > 0 && totalMemBytes < kLowRamPassiveBytes) return true;
  return false;
}

bool? _cachedPassive;
Future<bool>? _flight;

/// Sync read of the warmed policy cache for UI affordances (glass blur,
/// shimmer). False until the first policy read resolves — builds must
/// tolerate the flip (it only ever removes work).
bool get preferReducedOverhead => _cachedPassive == true;

/// Warm the policy cache (startup, fire-and-forget): one channel hop in
/// the background so browse + UI affordances decide without stalling.
Future<void> warmRelayPolicyCache() async {
  try {
    await shouldRelayPassively();
  } catch (_) {}
}

/// True when this device should listen passively (no relay).
/// iOS always (CoreBluetooth foreground-only + displaced mfg data + OS
/// scan throttling make iPhones poor relays; Android front rows cover —
/// no native call needed). Android reads one cached channel value:
/// OS low-RAM flag OR <4 GiB total RAM. Bounded (2 s) and fail-open
/// (unreadable → active), resolved once per process.
Future<bool> shouldRelayPassively() {
  if (isIOS) return Future.value(true);
  if (!isAndroid) return Future.value(false);
  final cached = _cachedPassive;
  if (cached != null) return Future.value(cached);
  final flight = _flight;
  if (flight != null) return flight;
  Future<bool> read() async {
    try {
      final m = await _memChannel
          .invokeMethod<Map<Object?, Object?>>('getMemoryInfo')
          .timeout(const Duration(seconds: 2));
      final total = (m?['totalMemBytes'] as int?) ?? 0;
      final low = (m?['lowRamDevice'] as bool?) ?? false;
      return passiveForMemory(lowRamDevice: low, totalMemBytes: total);
    } catch (_) {
      return false;
    }
  }

  final fut = read().then<bool>((v) {
    _cachedPassive = v;
    _flight = null;
    return v;
  }, onError: (_) {
    _flight = null;
    return false;
  });
  _flight = fut;
  return fut;
}

/// Test seam: drop the cached verdict so tests pin each branch.
void debugResetRelayPolicyForTest() {
  _cachedPassive = null;
  _flight = null;
}
