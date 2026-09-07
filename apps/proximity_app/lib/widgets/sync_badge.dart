// Unsynced badge (Track 4 §4): N pending out of the SyncEngine outbox.
// Hidden when nothing is pending. [PendingCountChip] is shared with the
// pure SyncStatusStrip (trust_cards.dart) so both render the same chip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';

/// Pending-count chip (`N unsynced`); icon reflects reachability.
class PendingCountChip extends StatelessWidget {
  final int pending;
  final bool online;
  const PendingCountChip(
      {super.key, required this.pending, required this.online});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        online ? Icons.cloud_upload_outlined : Icons.cloud_off_outlined,
        size: 16,
      ),
      label: Text('$pending unsynced'),
      visualDensity: VisualDensity.compact,
    );
  }
}

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
        // Store read only (reachability unknown): historic offline icon.
        return PendingCountChip(pending: n, online: false);
      },
    );
  }
}
