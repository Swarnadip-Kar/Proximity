import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_identity.dart';
import 'package:proximity_app/core/device_store.dart';

void main() {
  setUp(clearInstallIdCacheForTest);

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

  test('failed persist throws and never caches a phantom id', () async {
    // A swallowed write used to cache + return an id that never
    // persisted: every downstream claim then read as "another device"
    // (perpetual cooldown confusion). Now the write failure throws and
    // the next call serves the durable id once the store heals.
    final store = _FailingWriteStore()..failWrites = true;
    await expectLater(getOrCreateInstallId(store), throwsStateError);
    store.failWrites = false;
    const durable = 'ab12cd34ef56ab78ab12cd34ef56ab78';
    await store.writeInstallId(durable);
    expect(await getOrCreateInstallId(store), durable);
  });

  test('transient read failure rethrows, never mints a fork', () async {
    // A flaky install-id read must propagate (callers park/retry), not
    // resolve null into a freshly minted identity over existing data.
    final store = _UnavailableReadStore();
    await expectLater(
      getOrCreateInstallId(store),
      throwsA(isStateError),
    );
  });
}

/// InMemoryDeviceStore with scriptable install-id write failures.
class _FailingWriteStore extends InMemoryDeviceStore {
  bool failWrites = false;

  @override
  Future<void> writeInstallId(String id) async {
    if (failWrites) throw StateError('secure store unavailable');
    return super.writeInstallId(id);
  }
}

/// InMemoryDeviceStore whose install-id read fails transiently.
class _UnavailableReadStore extends InMemoryDeviceStore {
  @override
  Future<String?> readInstallId() async {
    throw StateError('Secure storage is temporarily unreadable — try again.');
  }
}
