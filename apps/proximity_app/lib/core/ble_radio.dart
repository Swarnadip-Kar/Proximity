// Real BLE radios behind the pure [BlePlatformDelegate] interface.
//
// [UniversalBleRadio] (Android/iOS/macOS/Windows): scan via universal_ble
// filtered on PROX_SVC, advertise [PROX_SVC + rotating UUID] via
// universal_ble peripheral, GATT client fallback (MTU 517 where exposed).
// UUID-only payloads everywhere — identical semantics all OS.
// [LinuxBleRadio]: universal_ble scan + BlueZ D-Bus advertise shim
// (universal_ble on Linux is scan-only).
// peerW scan-response alias: exposed where the platform stack surfaces
// scan-response bytes; elsewhere the professor recomputes R_IDj per roster
// entry (500 HMACs per batch, trivial) — same security, no stable MACs.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:universal_ble/universal_ble.dart';

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
    if (!kIsWeb && Platform.isAndroid) {
      final ok = await UniversalBle.enableBluetooth();
      if (!ok) return false;
      return await bluetoothState() == BtState.on;
    }
  } catch (_) {
    return false;
  }
  return false;
}

/// Injectable BT-power gate (faked in widget tests).
final btPowerProvider = Provider<Future<BtState> Function()>((ref) {
  return bluetoothState;
});

BleSighting _mapDevice(BleDevice d) {
  var uuid = '';
  for (final s in d.services) {
    final u = UuidCodec.normalize(s);
    if (UuidCodec.isChallengeUuid(u) || UuidCodec.isResponseUuid(u)) {
      uuid = u;
      break;
    }
  }
  return BleSighting(
    uuid: uuid.isEmpty ? d.deviceId : uuid,
    rssiDbm: d.rssi ?? -127,
    at: DateTime.now().toUtc(),
  );
}

class UniversalBleRadio implements BlePlatformDelegate {
  void Function(BleSighting)? _onSight;
  @override
  String get platformName => 'universal_ble';

  @override
  Future<void> startAdvertising(String serviceUuid, String rotatingUuid,
      {List<int>? scanResponse}) async {
    await UniversalBlePeripheral.stopAdvertising();
    await UniversalBlePeripheral.startAdvertising(
      services: [serviceUuid, rotatingUuid],
    );
  }

  @override
  Future<void> stopAdvertising() =>
      UniversalBlePeripheral.stopAdvertising();

  @override
  Future<void> startScanning(void Function(BleSighting s) onSight) async {
    _onSight = onSight;
    UniversalBle.onScanResult = (BleDevice d) {
      final s = _mapDevice(d);
      if (s.isChallenge || s.isResponse) _onSight?.call(s);
    };
    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [kProxSvc]),
    );
  }

  @override
  Future<void> stopScanning() async {
    UniversalBle.onScanResult = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    _onSight = null;
  }

  @override
  Future<Uint8List?> gattRead(
      String deviceId, String serviceUuid, String charUuid) async {
    try {
      await UniversalBle.connect(deviceId);
      final v = await UniversalBle.read(deviceId, serviceUuid, charUuid);
      await UniversalBle.disconnect(deviceId);
      return Uint8List.fromList(v);
    } catch (_) {
      try {
        await UniversalBle.disconnect(deviceId);
      } catch (_) {}
      return null;
    }
  }

  @override
  Future<void> gattWrite(String deviceId, String serviceUuid,
      String charUuid, Uint8List value) async {
    try {
      await UniversalBle.connect(deviceId);
      await UniversalBle.write(deviceId, serviceUuid, charUuid, value);
      await UniversalBle.disconnect(deviceId);
    } catch (_) {
      try {
        await UniversalBle.disconnect(deviceId);
      } catch (_) {}
    }
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
  Future<void> startAdvertising(String serviceUuid, String rotatingUuid,
      {List<int>? scanResponse}) async {
    // serviceUuid is always PROX_SVC; the rotating UUID carries the secret.
    await _bluez.advertise(rotatingUuid);
  }

  @override
  Future<void> stopAdvertising() => _bluez.release();
}

BlePlatformDelegate platformRadio() {
  if (!kIsWeb && Platform.isLinux) return LinuxBleRadio();
  return UniversalBleRadio();
}

/// One-time onboarding prompts (Bluetooth + location for scan on Android).
/// Returns true when radio may start. Desktop returns true (OS handles it).
Future<bool> ensureBlePermissions() async {
  if (kIsWeb) return true;
  try {
    if (Platform.isAndroid) {
      final res = await [
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
        Permission.camera,
      ].request();
      return (res[Permission.bluetoothScan]?.isGranted ?? false) &&
          (res[Permission.bluetoothAdvertise]?.isGranted ?? false) &&
          (res[Permission.bluetoothConnect]?.isGranted ?? false);
    }
    if (Platform.isIOS || Platform.isMacOS) {
      final cam = await Permission.camera.request();
      return cam.isGranted || cam.isLimited;
    }
  } catch (_) {
    return false;
  }
  return true;
}
