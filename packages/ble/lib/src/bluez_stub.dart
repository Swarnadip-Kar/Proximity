// Web records-build stub for bluez.dart: identical public API, every call
// throws. The web app never advertises (records only); this exists so the
// Linux radio class compiles for web. Native Linux builds use bluez.dart
// (D-Bus). Mirror new shared-code members here or the web build fails
// loudly (by design).
library;

import 'dart:typed_data';

Never _web() =>
    throw UnsupportedError('records-only web build: no BLE advertise');

class BluezAdvertiser {
  bool get isAdvertising => _web();

  Future<void> advertise(String airServiceUuid,
          {required Uint8List airMfg}) =>
      _web();

  /// Advertise one legacy v1 UUID packet (no manufacturer data).
  Future<void> advertiseUuidOnly(String uuid128) => _web();

  Future<void> release() async {}
}
