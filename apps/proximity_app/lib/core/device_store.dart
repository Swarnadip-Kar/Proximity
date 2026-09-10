// On-device persistence: secure enrollment (key seed, identity, template)
// + class-history list. No face photos — template is an embedding vector;
// the key seed never leaves secure hardware-backed storage.
//
// [SecureDeviceStore] (prod) splits across flutter_secure_storage
// (enrollment secrets) and shared_preferences (history JSON).
// [InMemoryDeviceStore] drives tests and sim demos.
//
// (store_base, record_helpers, secure_store, memory_store). This file is
// don't change. The abstract [DeviceStore] method set is unchanged.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sync/store/store_base.dart';

export 'sync/store/memory_store.dart';
export 'sync/store/record_helpers.dart';
export 'sync/store/secure_store.dart';
export 'sync/store/store_base.dart';

final deviceStoreProvider = Provider<DeviceStore>((ref) {
  throw UnimplementedError('Override in main / tests');
});
