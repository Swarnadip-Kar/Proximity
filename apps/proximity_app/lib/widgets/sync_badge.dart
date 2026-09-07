// Unsynced badge (Track 4 §4): N pending out of the SyncEngine outbox
// (sessions + manual queue + tombstones). Hidden when nothing is pending.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';

class UnsyncedBadge extends ConsumerWidget {
  const UnsyncedBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(deviceStoreProvider);
    return FutureBuilder<int>(
      future: syncEngine.pendingCount(store),
      builder: (context, snap) {
        final n = snap.data ?? 0;
        if (n <= 0) return const SizedBox.shrink();
        return Chip(
          avatar: const Icon(Icons.cloud_off_outlined, size: 16),
          label: Text('$n unsynced'),
          visualDensity: VisualDensity.compact,
        );
      },
    );
  }
}
