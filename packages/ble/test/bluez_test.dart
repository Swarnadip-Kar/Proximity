import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:proximity_ble/src/bluez.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('advertisement props carry air SVC + manufacturer payload', () {
    final mfg = packAir(
      type: kAirTypeChallenge,
      token8: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      host: '10.50.19.107',
      port: 8443,
    )!;
    final props = advertisementProps(kAirSvc, airMfg: mfg);
    expect((props['Type'] as DBusString).value, 'peripheral');
    final uuids =
        (props['ServiceUUIDs'] as DBusArray).children.map((e) => (e as DBusString).value).toList();
    expect(uuids, [kAirSvc]);
    expect((props['LocalName'] as DBusString).value, 'Proximity');
    expect(props.containsKey('ManufacturerData'), isTrue);
  });

  test('air roundtrip on the shim path', () {
    final mfg = packAir(
      type: kAirTypeChallenge,
      token8: Uint8List.fromList(List.filled(8, 9)),
      host: '10.50.19.107',
      port: 8443,
    )!;
    expect(unpackAir(mfg)!.host, '10.50.19.107');
  });

  test('BluezAdvertiser starts idle', () {
    expect(BluezAdvertiser().isAdvertising, isFalse);
  });
}
