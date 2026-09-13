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

/// Stable phone id across reinstalls ('' when unavailable — desktop, web,
// VM tests, or any plugin failure). Trimmed, never null.
Future<String> getStableHardwareDeviceId() async {
  try {
    final info = DeviceInfoPlugin();
    try {
      final android =
          await info.androidInfo.timeout(const Duration(seconds: 4));
      final id = android.id.trim();
      if (id.isNotEmpty) return id;
    } catch (_) {
      // Not Android (or plugin missing) — try iOS below.
    }
    try {
      final ios = await info.iosInfo.timeout(const Duration(seconds: 4));
      return (ios.identifierForVendor ?? '').trim();
    } catch (_) {
      // Not iOS either (desktop/web/VM) — no stable id.
    }
  } catch (_) {}
  return '';
}
