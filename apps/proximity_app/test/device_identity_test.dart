import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_identity.dart';
import 'package:proximity_app/core/device_store.dart';

void main() {
  test('newInstallId is 128-bit hex, stable via store', () async {
    final a = newInstallId(Random(1));
    final b = newInstallId(Random(2));
    expect(a.length, 32);
    expect(b.length, 32);
    expect(a, isNot(b));
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(a), isTrue);
    final store = InMemoryDeviceStore();
    final first = await getOrCreateInstallId(store);
    expect(await getOrCreateInstallId(store), first);
  });
}
