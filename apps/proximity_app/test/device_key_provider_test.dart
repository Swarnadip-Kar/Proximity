// sec(hwkey): deviceKeyProvider defaults — HW on mobile, fail-closed stub
// on records-only targets. SoftwareDeviceKey stays test-only (injected).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/device_identity/hw_device_key.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';

void main() {
  test('provider default is HwDeviceKey on mobile', () {
    final container = ProviderContainer();
    try {
      final key = container.read(deviceKeyProvider);
      expect(key, isA<HwDeviceKey>());
      expect(key.chainDERHex, isEmpty);
    } finally {
      container.dispose();
    }
  });

  test('provider default is UnavailableDeviceKey off mobile', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final container = ProviderContainer();
    try {
      expect(
          container.read(deviceKeyProvider), isA<UnavailableDeviceKey>());
    } finally {
      container.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
