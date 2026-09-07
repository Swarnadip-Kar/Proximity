// BLE engine: identical air bytes on every OS (§5.2, §6.1, §6.2).
//
// Over-the-air format (v2, see protocol/air.dart): fixed 16-bit service
// UUID [kAirSvc] + manufacturer payload (company [kAirCompanyId]):
// magic 'PX', ver, type (challenge/response), token(8B), ipv4(4B),
// port BE16. 29B total in the PRIMARY advertisement packet on every
// platform — no scan-response dependence, no per-OS packet layout.
//
// Platform mapping (outside this pure-Dart core):
//  - scan/connect: `universal_ble` (Android/iOS/macOS/Windows/Linux),
//    filtered on [kAirSvc]
//  - advertise: `universal_ble` peripheral (Android/iOS/macOS/Windows)
//  - Linux advertise: BlueZ LEAdvertisingManager1 D-Bus shim (same bytes)
//  - scan restarts: ≥5s between restarts (Android scanner rate-limit guard).
//
// Layout (M4 radio slim): this barrel re-exports the split core under
// src/ — sighting.dart [BleSighting], delegate.dart
// [BlePlatformDelegate]+[FakeBleRadio], engine.dart [ProxBleEngine] (relay
// admission in relay.dart, challenge waiters in challenge_wait.dart, both
// part of the engine library). Public API is unchanged, so host/student
// drivers are untouched.
library proximity_ble;

export 'src/bluez.dart' if (dart.library.html) 'src/bluez_stub.dart';
export 'src/ble_log.dart';
export 'src/sighting.dart';
export 'src/delegate.dart';
export 'src/engine.dart';
