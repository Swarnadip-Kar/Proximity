// Stable hardware device id for the same-phone reclaim (claim.dart).
//
// Android ANDROID_ID / iOS identifierForVendor via device_info_plus: stable
// across app reinstalls on the same phone, no permission, no hardware-ID
// entitlements. A true uninstall wipes the gallery, the installId, and the
// Keystore keys by design (face MUST be re-scanned); this id exists ONLY so
// the 30-day move cooldown does not misfire on a same-phone reinstall —
// the reclaim still requires Gmail auth (rules: owner-only write) + a fresh
// face scan + a fresh HW-bound key.
//
// Security honesty: ANDROID_ID resets on factory reset and
// identifierForVendor resets when every vendor app is removed; a rooted
// attacker can spoof either — but spoofing alone buys nothing without the
// Gmail session AND the live face AND fresh secure hardware, i.e. a fully
// compromised account anyway. The SERVER enforces the match (rules
// isSamePhoneReclaim) — the client assertion alone is worthless.
//
// Fail-soft: any failure (desktop records builds, web, VM tests, plugin
// missing) yields '' — no reclaim, exactly the old behavior. No dart:io
// here (web records builds compile this file): platform mismatches throw
// inside the plugin getters and fall through to ''.
library;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _hwChannel = MethodChannel('org.iitbhilai.proximity/hardware_id');

/// Injectable hardware-id source. Production always uses
/// [getStableHardwareDeviceId]; tests override [source] (with tearDown
/// reset) because the real function awaits native channels whose
/// Timer-based deadlines never advance under flutter_test's FakeAsync —
/// awaiting it directly in a widget test hangs forever. Mirrors the
/// `IntegrityGate.probe` precedent.
class HardwareDeviceIds {
  HardwareDeviceIds._();
  static Future<String> Function() source = getStableHardwareDeviceId;
}

/// Stable phone id across reinstalls ('' when unavailable — desktop, web,
// VM tests, or any plugin failure). Trimmed, never null.
//
// Every native hop carries a deadline: an unanswered MethodChannel (unit
// tests, dead engine) must degrade to '' instead of hanging the caller
// forever — entry gates await this on the UI path.
Future<String> getStableHardwareDeviceId() async {
  if (kIsWeb) return '';
  const hopBudget = Duration(seconds: 4);

  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      final String? aid = await _hwChannel
          .invokeMethod<String>('getAndroidId')
          .timeout(hopBudget);
      if (aid != null && aid.trim().isNotEmpty) {
        return aid.trim();
      }
    } catch (_) {
      // Method channel failed — fall back to device_info_plus below.
    }
    try {
      final info = DeviceInfoPlugin();
      final android =
          await info.androidInfo.timeout(hopBudget);
      final id = android.id.trim();
      if (id.isNotEmpty) return id;
    } catch (_) {}
  } else if (defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      final info = DeviceInfoPlugin();
      final ios = await info.iosInfo.timeout(hopBudget);
      final id = (ios.identifierForVendor ?? '').trim();
      if (id.isNotEmpty) return id;
    } catch (_) {}
  }

  return '';
}
