// Linux BlueZ D-Bus advertise shim (~§8: identical UUID semantics).
//
// universal_ble on Linux is scan-only, so professor laptops advertise the
// rotating UUID_P/UUID_S + fixed PROX_SVC through BlueZ LEAdvertisingManager1
// directly. Scan path stays universal_ble; this file is advertise-only.
//
// Layout mirrors the mobile path exactly:
//   ServiceUUIDs = [PROX_SVC, rotatingUuid], Type = peripheral,
//   LocalName = Proximity, Includes = [tx-power].
// peerW (scan-response alias) rides the advertisement data where BlueZ
// exposes it; roster-side HMAC recompute covers the rest (same as mobile).
library;

import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:proximity_protocol/protocol.dart';

const kBluezService = 'org.bluez';
const kBluezAdvMgrIface = 'org.bluez.LEAdvertisingManager1';
const kBluezAdvIface = 'org.bluez.LEAdvertisement1';
const kBluezDeviceIface = 'org.bluez.Device1';
const kAdvertPathPrefix = '/org/proximity/advert';

/// Pure advertisement property map (unit-tested without a bus).
Map<String, DBusValue> advertisementProps(String rotatingUuid) => {
      'Type': const DBusString('peripheral'),
      'ServiceUUIDs': DBusArray.string([kProxSvc, rotatingUuid]),
      'LocalName': const DBusString('Proximity'),
      'Includes': DBusArray.string(['tx-power']),
      'Discoverable': const DBusBoolean(true),
    };

class _AdvertisementObject extends DBusObject {
  final Map<String, DBusValue> props;
  _AdvertisementObject(DBusObjectPath path, this.props) : super(path);

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface == 'org.freedesktop.DBus.Properties' &&
        call.name == 'GetAll' &&
        call.values.length == 1 &&
        (call.values[0] as DBusString).value == kBluezAdvIface) {
      return DBusMethodSuccessResponse([DBusDict.stringVariant(props)]);
    }
    if (call.interface == kBluezAdvIface && call.name == 'Release') {
      return DBusMethodSuccessResponse([]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

/// Registers/unregisters one LE advertisement per rotation tick.
class BluezAdvertiser {
  DBusClient? _bus;
  _AdvertisementObject? _current;
  String? _adapterPath;
  int _serial = 0;

  bool get isAdvertising => _current != null;

  Future<void> _ensureBus() async {
    _bus ??= DBusClient.system();
    _adapterPath ??= await _findAdapter(_bus!);
  }

  /// Finds the first adapter exposing LEAdvertisingManager1.
  static Future<String> _findAdapter(DBusClient bus) async {
    final objs = await bus.callMethod(
      destination: kBluezService,
      path: DBusObjectPath('/'),
      interface: 'org.freedesktop.DBus.ObjectManager',
      name: 'GetManagedObjects',
    );
    final all = (objs.returnValues[0] as DBusDict).children;
    for (final entry in all.entries) {
      final path = (entry.key as DBusObjectPath).value;
      final ifaces = entry.value as DBusDict;
      for (final iface in ifaces.children.keys) {
        if ((iface as DBusString).value == kBluezAdvMgrIface) return path;
      }
    }
    throw StateError('No BlueZ adapter with LEAdvertisingManager1 found.');
  }

  /// Advertise [rotatingUuid] alongside fixed PROX_SVC (5s rotation:
  /// call again to republish; previous registration is released first).
  Future<void> advertise(String rotatingUuid) async {
    await _ensureBus();
    await release();
    final path =
        DBusObjectPath('$kAdvertPathPrefix${_serial++}');
    _current = _AdvertisementObject(path, advertisementProps(rotatingUuid));
    await _bus!.registerObject(_current!);
    await _bus!.callMethod(
      destination: kBluezService,
      path: DBusObjectPath(_adapterPath!),
      interface: kBluezAdvMgrIface,
      name: 'RegisterAdvertisement',
      values: [DBusObjectPath(path.value), DBusDict.stringVariant({})],
    );
  }

  Future<void> release() async {
    final cur = _current;
    _current = null;
    if (cur == null || _bus == null || _adapterPath == null) return;
    try {
      await _bus!.callMethod(
        destination: kBluezService,
        path: DBusObjectPath(_adapterPath!),
        interface: kBluezAdvMgrIface,
        name: 'UnRegisterAdvertisement',
        values: [DBusObjectPath(cur.path.value)],
      );
    } catch (_) {}
    try {
      await _bus!.unregisterObject(cur);
    } catch (_) {}
  }

  Future<void> close() async {
    await release();
    await _bus?.close();
    _bus = null;
    _adapterPath = null;
  }
}

/// Convenience: pack a rotating challenge UUID for the shim.
String shimChallengeUuid(Uint8List challenge8) =>
    UuidCodec.packChallenge(challenge8);
