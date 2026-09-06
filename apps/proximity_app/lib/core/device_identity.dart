// App-install identity for the single-student-device binding.
//
// No reliable cross-platform hardware ID exists (Android ANDROID_ID resets,
// iOS offers nothing stable), so the binding key is an app-generated 128-bit
// UUID persisted in secure storage (Keystore/Keychain). Properties:
//   - stable across restarts and app updates on the same install;
//   - app-data clear / reinstall regenerates it (counts as a device move,
//     subject to the weekly cooldown);
//   - app clones, dual-app copies and work profiles hold SEPARATE secure
//     storage, so a clone gets its own installId and counts as a different
//     device — the same phone can never hold two student enrollments.
// Identity here is only ever (pkHex, installId) joined against the cloud
// studentDevices/deviceInstalls docs (see cloud_sync claim logic).
library;

import 'dart:math';

import 'device_store.dart';

/// Generates a 128-bit hex install ID. [random] is injectable for tests.
String newInstallId([Random? random]) {
  final r = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Returns the persisted install ID, creating and storing one on first run.
Future<String> getOrCreateInstallId(DeviceStore store) async {
  try {
    final existing = await store.readInstallId();
    if (existing != null && existing.isNotEmpty) return existing;
  } catch (_) {}
  final id = newInstallId();
  try {
    await store.writeInstallId(id);
  } catch (_) {}
  return id;
}
