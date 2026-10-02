// Live ambient light — instant darkness evidence for flash assist.
//
// Why a sensor, not capture brightness: the capture path (takePicture +
// ML Kit pose + TFLite liveness) yields one brightness sample per ~600ms
// beat at best, zero while off-target (no probe runs), and auto-exposure
// compensates the crop anyway — field dark-room stills read 58-189 vs
// normal 80-100, so no threshold separates them. The ambient TYPE_LIGHT
// sensor reports true pre-AE lux at ~5Hz with no camera interference,
// so the ring fades gradually with the room instead of snapping per beat.
//
// Android only (SensorManager, no permission needed). Every other platform
// has no sensor side and resolves to [UnavailableAmbientLight] — the
// driver falls back to capture brightness there. Zero new dependencies:
// one EventChannel owned by MainActivity, same pattern as the brightness
// channel in flash_assist.dart.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Lux at/above which no assist is needed (lit office). Below it the ring
/// grades up smoothly to full at 0 lux.
const double kAmbientBrightLux = 500.0;

/// Lux below which the window brightness maxes (true dark — instant, no
/// beat wait). Sits at ring level ~0.45 so light and glow agree.
const double kAmbientDarkLux = 30.0;

/// Log-scale lux to ring level 0..1 (darker = brighter ring). Gradual by
/// construction: neighbouring lux values map to neighbouring levels, never
/// a binary snap. Non-finite/negative (unknown) reads 0 — unknown
/// brightness is never darkness evidence.
double luxToLevel(double lux) {
  if (!lux.isFinite || lux < 0) return 0.0;
  if (lux <= 0) return 1.0;
  if (lux >= kAmbientBrightLux) return 0.0;
  final t = math.log(lux + 1) / math.log(kAmbientBrightLux + 1);
  return (1 - t).clamp(0.0, 1.0);
}

/// Lux to the 0-255 brightness token shown beside the live score (same
/// direction as the crop mean: low = dark). Lets the readout show a live
/// number every beat, even off-target when no probe runs.
double luxToBrightness(double lux) => 255 * (1 - luxToLevel(lux));

/// Window-max switch for live lux (see [kAmbientDarkLux]).
bool luxIsDark(double lux) => lux.isFinite && lux >= 0 && lux < kAmbientDarkLux;

/// Lux stream source. Production resolves the channel impl; widget tests
/// override with [FakeAmbientLight]. A source with no sensor yields an
/// empty stream (never an error) so the driver falls back silently.
abstract class AmbientLight {
  Stream<double> watch();
}

/// Channel impl over `org.iitbhilai.proximity/ambient_light` (MainActivity;
/// Android only). Missing plugin / no sensor / any error degrades to an
/// empty stream — never throws past the caller.
class ChannelAmbientLight implements AmbientLight {
  @visibleForTesting
  static const channel =
      EventChannel('org.iitbhilai.proximity/ambient_light');

  const ChannelAmbientLight();

  @override
  Stream<double> watch() {
    try {
      return channel.receiveBroadcastStream().map((e) {
        final v = (e as num?)?.toDouble();
        return v ?? double.nan;
      }).handleError((_) {});
    } catch (_) {
      return const Stream.empty();
    }
  }
}

/// Always-unavailable (iOS / desktop / tests without a sensor).
class UnavailableAmbientLight implements AmbientLight {
  const UnavailableAmbientLight();
  @override
  Stream<double> watch() => const Stream.empty();
}

/// Test-only: replays [luxes] then closes (or stays open when [leaveOpen]).
class FakeAmbientLight implements AmbientLight {
  final List<double> luxes;
  final bool leaveOpen;
  FakeAmbientLight({this.luxes = const [], this.leaveOpen = false});

  @override
  Stream<double> watch() async* {
    for (final l in luxes) {
      yield l;
    }
    if (leaveOpen) await Completer<void>().future;
  }
}

/// DI seam: production resolves the channel impl (Android sensor,
/// fail-soft elsewhere); widget tests override with [FakeAmbientLight].
final enrollAmbientLightProvider = Provider<AmbientLight>((ref) {
  return const ChannelAmbientLight();
});
