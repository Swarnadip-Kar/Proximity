import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:proximity_ble/src/bluez.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('advertisement props carry PROX_SVC + rotating UUID', () {
    final cj = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    final rotating = UuidCodec.packChallenge(cj);
    final props = advertisementProps(rotating);
    expect((props['Type'] as DBusString).value, 'peripheral');
    final uuids =
        (props['ServiceUUIDs'] as DBusArray).children.map((e) => (e as DBusString).value).toList();
    expect(uuids, [kProxSvc, rotating]);
    expect((props['LocalName'] as DBusString).value, 'Proximity');
  });

  test('challenge/response UUIDs differ on the shim path', () {
    final cj = Uint8List.fromList(List.filled(8, 9));
    expect(shimChallengeUuid(cj), UuidCodec.packChallenge(cj));
    expect(UuidCodec.isChallengeUuid(shimChallengeUuid(cj)), isTrue);
  });

  test('BluezAdvertiser starts idle', () {
    expect(BluezAdvertiser().isAdvertising, isFalse);
  });
}
