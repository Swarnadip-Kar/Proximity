// Flash assist — screen light for dark enrollment sessions.
//
// Dark rooms defeat guidance, not just scoring: the preview stays black
// (the still-capture metering the scorer sees never reaches it), the
// holder cannot position, and pose reads fail for dozens of beats. The
// industry answer for front-camera darkness is ADDED light, not refused
// capture: the Android Camera2 screen-flash guide (white overlay + max
// brightness + external-flash AE mode + precapture convergence), Snap's
// ring light, and commercial identity SDKs pairing brightness checks with
// flash. Turning the camera's auto-exposure off is NOT the answer:
// device-dependent AWB/AF fallout when AE is off, the Flutter camera
// plugin exposes no 3A controls, and it shifts the MiniFASNet input
// distribution the scorer was calibrated on.
//
// v1 here is pure Flutter + one tiny window-brightness channel (Android
// only — every other platform fail-softs to ring-border-only, see
// [ChannelScreenBrightnessControl]): while the session believes it is
// dark ([flashAssist] on the session driver) the preview paints a bright
// border ring (real light on the holder's face — the phone is held close)
// and [FlashAssistSync] maxes the window brightness, restoring the
// previous value afterwards. Continuous assist, not per-shot synced flash
// (takePicture timing lives inside the camera plugin): simpler, and it
// also fixes the dark preview itself. No AE mode changes, no capture
// gating — warn-only presentation, same as the DIM hints that drive it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Window-brightness control, 0.0 (dark) .. 1.0 (max). Out-of-range writes
/// are clamped by implementations. Previous-value restore is the caller's
/// job (see [FlashAssistSync]) — this interface only reads and writes.
abstract class ScreenBrightnessControl {
  /// Current window brightness, or null when unknown (web, desktop, tests
  /// without a channel mock, native failure). Never throws.
  Future<double?> current();

  /// Sets the window brightness. Best-effort: never throws (fail-soft like
  /// every other optional native hop in this app).
  Future<void> set(double value);
}

/// Channel implementation over `org.iitbhilai.proximity/screen_brightness`
/// (MainActivity; Android only — no AppDelegate side, so iOS/macOS resolve
/// here and fail soft by design until a native side ships).
/// `getBrightness` returns the window's `screenBrightness` (-1.0 = follows
/// system — a valid value restored verbatim, never clamped).
/// `setBrightness` takes 0.0..1.0. Every hop carries a deadline and
/// degrades to null/no-op — unit tests, dead engine, and non-Android
/// platforms never hang the UI.
class ChannelScreenBrightnessControl implements ScreenBrightnessControl {
  @visibleForTesting
  static const channel =
      MethodChannel('org.iitbhilai.proximity/screen_brightness');

  static const _hopBudget = Duration(seconds: 3);

  const ChannelScreenBrightnessControl();

  @override
  Future<double?> current() async {
    if (kIsWeb) return null;
    try {
      final v = await channel
          .invokeMethod<double>('getBrightness')
          .timeout(_hopBudget);
      if (v == null || !v.isFinite) return null;
      return v.clamp(-1.0, 1.0);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> set(double value) async {
    if (kIsWeb) return;
    // -1.0 = follow system (clear the window override). Must pass through
    // verbatim — clamping it to 0.0 strands the window at darkest and
    // Android reports "brightness controlled by another app".
    final v = value < 0 ? -1.0 : value.clamp(0.0, 1.0);
    try {
      await channel.invokeMethod<void>(
          'setBrightness', {'value': v}).timeout(
          _hopBudget);
    } catch (_) {}
  }
}

/// Test-only fake (same role FakeFaceVerifier plays): scripted [current],
/// recorded [sets]. Never shipped (DI wires the channel impl).
class FakeScreenBrightnessControl implements ScreenBrightnessControl {
  double? scriptedCurrent;
  final List<double> sets = [];
  FakeScreenBrightnessControl({this.scriptedCurrent});

  @override
  Future<double?> current() async => scriptedCurrent;

  @override
  Future<void> set(double value) async {
    sets.add(value);
  }
}

/// DI seam: production resolves the channel impl (Android native,
/// fail-soft elsewhere); widget tests override with
/// [FakeScreenBrightnessControl].
final enrollScreenBrightnessProvider =
    Provider<ScreenBrightnessControl>((ref) {
  return const ChannelScreenBrightnessControl();
});

/// Declarative shell: maxes the window brightness while [active] is true
/// and restores the previous value when it flips false or this widget
/// leaves the tree (cancel, save-advance, pop). Renders nothing
/// ([SizedBox.shrink]) — it only owns the side effect, so the session
/// driver stays side-effect free (it merely exposes `flashAssist`).
///
/// Restore paths: deactivate (a bright probe lands), dispose (cancel pops
/// the screen, save auto-advances past it). A missed restore self-heals:
/// window brightness dies with the window (background/kill). Late async
/// completions are guarded (an `_apply` that loses a race with deactivate
/// never writes max after the restore).
class FlashAssistSync extends StatefulWidget {
  final bool active;
  final ScreenBrightnessControl control;
  const FlashAssistSync(
      {super.key, required this.active, required this.control});

  @override
  State<FlashAssistSync> createState() => _FlashAssistSyncState();
}

class _FlashAssistSyncState extends State<FlashAssistSync> {
  double? _previous;
  var _applied = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) unawaited(_apply());
  }

  @override
  void didUpdateWidget(FlashAssistSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      unawaited(_apply());
    } else {
      unawaited(_restore());
    }
  }

  @override
  void dispose() {
    if (_applied) {
      final prev = _previous;
      _applied = false;
      _previous = null;
      // Unknown previous still clears (follow system) — leaving max applied
      // strands the window and Android reports "brightness controlled by
      // another app" after back navigation (same Activity window survives).
      unawaited(widget.control.set(prev ?? -1.0));
    }
    super.dispose();
  }

  Future<void> _apply() async {
    if (_applied) return;
    _applied = true;
    try {
      _previous = await widget.control.current();
    } catch (_) {
      _previous = null;
    }
    // Lost the race with deactivate/dispose: never write max now (the
    // restore already ran or will run with what it captured).
    if (!mounted || !_applied) return;
    try {
      await widget.control.set(1.0);
    } catch (_) {}
  }

  Future<void> _restore() async {
    if (!_applied) return;
    _applied = false;
    final prev = _previous;
    _previous = null;
    // Same clear-on-unknown rule as dispose (see above).
    try {
      await widget.control.set(prev ?? -1.0);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
