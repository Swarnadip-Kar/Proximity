// Real BLE radios behind the pure [BlePlatformDelegate] interface.
//
// [UniversalBleRadio] (Android/iOS/macOS/Windows): scan filtered on the
// fixed 16-bit [kAirSvc], advertise [kAirSvc + air manufacturer payload]
// via universal_ble peripheral, GATT client fallback (MTU 517 where
// exposed). v2 air bytes everywhere (protocol/air.dart) — identical
// semantics all OS: everything fits the 31B primary packet, so no
// platform depends on scan responses.
// [LinuxBleRadio]: universal_ble scan + BlueZ D-Bus advertise shim
// (universal_ble on Linux is scan-only).
// peerW: unused by the v2 air path (kept for the GATT fallback); the
// professor matches radio sightings by response token instead.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:universal_ble/universal_ble.dart';

import 'platformx.dart' as platformx;

/// Shared BLE engine (one radio per device).
final bleEngineProvider = Provider<ProxBleEngine>((ref) {
  throw UnimplementedError('Override in main / tests');
});

/// Injectable permission gate (faked in widget tests).
final blePermissionProvider = Provider<Future<bool> Function()>((ref) {
  return ensureBlePermissions;
});

enum BtState { on, off, unavailable }

/// Bluetooth power state. Desktop/unsupported returns [BtState.on] only
/// when the stack reports usable; simulators report unavailable.
Future<BtState> bluetoothState() async {
  try {
    final s = await UniversalBle.getBluetoothAvailabilityState();
    return switch (s) {
      AvailabilityState.poweredOn => BtState.on,
      AvailabilityState.poweredOff => BtState.off,
      _ => BtState.unavailable,
    };
  } catch (_) {
    return BtState.unavailable;
  }
}

/// System enable prompt (Android only; Apple has no API — user goes to
/// Settings). Returns true when the radio reports powered on afterwards.
Future<bool> requestEnableBluetooth() async {
  try {
    if (platformx.isAndroid) {
      final ok = await UniversalBle.enableBluetooth();
      if (!ok) return false;
      return await bluetoothState() == BtState.on;
    }
  } catch (_) {
    return false;
  }
  return false;
}

/// One-shot UI prompt when Bluetooth is off. Log-only failures ("Bluetooth
/// not enabled" buried in logcat) are invisible: both live screens call
/// this on entry so the user gets a tappable Turn-on instead. A successful
/// Turn-on immediately retries a scan deferred while the radio was off
/// (the engine also self-polls, so enabling via Settings heals too).
/// Test-safe: faked [btPowerProvider] values other than off skip silently,
/// and the enable call never throws out of the dialog.
Future<void> promptEnableBluetoothIfOff(
    BuildContext context, WidgetRef ref) async {
  BtState s;
  try {
    s = await ref.read(btPowerProvider)();
  } catch (_) {
    return;
  }
  if (s != BtState.off || !context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Bluetooth is off'),
      content: const Text(
          'Turn it on to see classes and prove presence — without it the app can neither hear nor announce.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () async {
            var ok = false;
            try {
              ok = await requestEnableBluetooth();
            } catch (_) {
              ok = false;
            }
            if (ctx.mounted) Navigator.of(ctx).pop(ok);
          },
          child: const Text('Turn on'),
        ),
      ],
    ),
  );
  if (ok == true) {
    try {
      await ref.read(bleEngineProvider).retryPendingScan();
    } catch (_) {}
  }
}

/// Injectable camera-permission gate for the face-scan screen
/// (faked in widget tests).
final cameraPermissionProvider = Provider<Future<bool> Function()>((ref) {
  return () => ensureBlePermissions(camera: true);
});

/// Injectable BT-power gate (faked in widget tests).
final btPowerProvider = Provider<Future<BtState> Function()>((ref) {
  return bluetoothState;
});

/// Maps platform scan results to air sightings (v2 and legacy v1).
///
/// Thin adapter over the pure protocol [AirParser]: converts the platform
/// [BleDevice] to an [AirScan] record, delegates parsing, and maps the
/// pure [AirSighting] to [BleSighting]. All parse semantics plus the three
/// probe log lines live in `package:proximity_protocol` (pure-Dart,
/// covered by protocol tests); the logs flow verbatim via [BleLog.log].
class AirParserAdapter {
  final AirParser _parser = AirParser();

  BleSighting? map(BleDevice d) {
    final hit = _parser.map(
      AirScan(
        services: List<String>.of(d.services),
        manufacturerData: [
          for (final m in d.manufacturerDataList)
            AirMfg(m.companyId, m.payload),
        ],
        serviceData: Map<String, Uint8List>.of(d.serviceData),
        rssi: d.rssi,
      ),
      log: BleLog.log,
    );
    if (hit == null) return null;
    return BleSighting(
      version: hit.version,
      type: hit.type,
      token8: hit.token8,
      ipHost: hit.ipHost,
      ipPort: hit.ipPort,
      legacy: hit.legacy,
      legacyUuid: hit.legacyUuid,
      relayed: hit.relayed,
      denseHint: hit.denseHint,
      rssiDbm: hit.rssiDbm,
      at: hit.at,
    );
  }
}

class UniversalBleRadio implements BlePlatformDelegate {
  void Function(BleSighting)? _onSight;
  final AirParserAdapter _parser = AirParserAdapter();
  @override
  String get platformName => 'universal_ble';

  @override
  Future<void> startAirPacket(String airServiceUuid, Uint8List airMfg,
      {List<int>? scanResponse}) async {
    // v2 air packet (protocol/air.dart): fixed 16-bit [kAirSvc] + 18B
    // manufacturer payload, 29B total in the PRIMARY advertisement —
    // identical bytes on Android/Linux/macOS/Windows.
    BleLog.log('BLE', 'ADV start ${BleLog.shortUuid(airServiceUuid)}…');
    await UniversalBlePeripheral.stopAdvertising();
    try {
      await UniversalBlePeripheral.startAdvertising(
        services: [airServiceUuid],
        manufacturerData: ManufacturerData(kAirCompanyId, airMfg),
      );
      BleLog.log('BLE', 'ADV on air ${BleLog.shortUuid(airServiceUuid)}…');
    } catch (e) {
      BleLog.log(
          'BLE', 'ADV FAILED ${BleLog.shortUuid(airServiceUuid)}…: $e');
      rethrow;
    }
  }

  @override
  Future<void> startLegacyUuid(String uuid128) async {
    // Legacy v1 single-UUID packet (challenge in low bytes, no IP).
    // Used on stacks whose peripheral layout can't be trusted with
    // extras (Apple) — students parse both formats, relays preserve them.
    BleLog.log('BLE', 'ADV start v1 uuid=${BleLog.shortUuid(uuid128)}…');
    await UniversalBlePeripheral.stopAdvertising();
    try {
      await UniversalBlePeripheral.startAdvertising(services: [uuid128]);
      BleLog.log('BLE', 'ADV on air v1 uuid=${BleLog.shortUuid(uuid128)}…');
    } catch (e) {
      BleLog.log('BLE', 'ADV FAILED v1 uuid=${BleLog.shortUuid(uuid128)}…: $e');
      rethrow;
    }
  }

  @override
  Future<void> stopAdvertising() =>
      UniversalBlePeripheral.stopAdvertising();

  @override
  Future<void> startScanning(void Function(BleSighting s) onSight) async {
    _onSight = onSight;
    UniversalBle.onScanResult = (BleDevice d) {
      final s = _parser.map(d);
      // Most neighbours parse to nothing and drop silently here; the
      // parser logs FCD2 halves so air visibility stays debuggable.
      if (s != null) _onSight?.call(s);
    };
    // Unfiltered scan: v1 rotating UUIDs share no common service with v2,
    // so hardware filtering would drop one format. Parsing in [AirParser]
    // is the filter.
    BleLog.log('BLE', 'scan start (unfiltered, dual-format)');
    try {
      await UniversalBle.startScan();
      BleLog.log('BLE', 'scan active');
    } catch (e) {
      BleLog.log('BLE', 'scan start FAILED: $e');
      rethrow;
    }
  }

  @override
  Future<void> stopScanning() async {
    UniversalBle.onScanResult = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    _onSight = null;
  }
}

/// Linux prof host: BlueZ D-Bus advertise shim + universal_ble scan.
/// NOTE: universal_ble ships no Linux native backend, so scanning on Linux
/// is unverified — advertising (this shim) and HTTPS serving are the tested
/// Linux paths; verify scan on a real Linux host before relying on it.
class LinuxBleRadio extends UniversalBleRadio {
  final BluezAdvertiser _bluez = BluezAdvertiser();
  @override
  String get platformName => 'linux-bluez';

  @override
  Future<void> startAirPacket(String airServiceUuid, Uint8List airMfg,
      {List<int>? scanResponse}) async {
    // serviceUuid is always [kAirSvc]; the air packet carries everything.
    await _bluez.advertise(airServiceUuid, airMfg: airMfg);
  }

  @override
  Future<void> startLegacyUuid(String uuid128) async {
    await _bluez.advertiseUuidOnly(uuid128);
  }

  @override
  Future<void> stopAdvertising() => _bluez.release();
}

BlePlatformDelegate platformRadio() {
  if (platformx.isLinux) return LinuxBleRadio();
  return UniversalBleRadio();
}

/// One-time onboarding prompts.
///
/// [camera]: also request camera (face scan). Host/attendance-start flows
/// pass false — camera is requested at the face-scan screen instead, so a
/// denied camera can never surface as a *Bluetooth* error (Bug 1).
/// Desktop returns true with no prompts (the OS handles radio access).
Future<bool> ensureBlePermissions({bool camera = false}) async {
  if (kIsWeb) return true;
  try {
    if (platformx.isAndroid) {
      final req = [
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
        if (camera) Permission.camera,
      ];
      final res = await req.request();
      final btOk = (res[Permission.bluetoothScan]?.isGranted ?? false) &&
          (res[Permission.bluetoothAdvertise]?.isGranted ?? false) &&
          (res[Permission.bluetoothConnect]?.isGranted ?? false);
      if (!camera) return btOk;
      final cam = res[Permission.camera];
      return btOk && (cam?.isGranted ?? false);
    }
    if (platformx.isIOS || platformx.isMacOS) {
      // No runtime Bluetooth prompt exists on Apple platforms; the OS asks
      // on first radio use (Info.plist usage strings are bundled).
      if (!camera) return true;
      final cam = await Permission.camera.request();
      return cam.isGranted || cam.isLimited;
    }
  } catch (_) {
    return false;
  }
  return true;
}
