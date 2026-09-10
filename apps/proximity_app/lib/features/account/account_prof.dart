// Professor device facts — moved verbatim from `account_screen.dart`
// (`_ProfDeviceFacts` → [AccountProfDeviceFacts]; presentational split
// only, read-only facts behavior-identical).
library;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth.dart';
import '../../core/device_store.dart';
import '../../design/tokens.dart';
import 'account_common.dart';

/// Professor device/key facts: install ID (read-only, never created by
/// viewing) + registered display name. Professors hold no SKey/DKey
/// enrollment, so there is no key/trust tier to show — and none is
/// invented.
class AccountProfDeviceFacts extends ConsumerWidget {
  final SignedAccount acct;
  const AccountProfDeviceFacts({required this.acct, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<String?>>(
      future: _profFacts(ref),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final installId = (snap.data ?? const [null, null])[0] ?? '';
        final hostName = (snap.data ?? const [null, null])[1] ?? '';
        final id = installId.trim();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AccountFactRow('Device model', defaultTargetPlatform.name),
            AccountFactRow(
              'Device ID',
              id.isEmpty ? 'Not assigned yet' : accountShortKey(id),
              mono: id.isNotEmpty,
              key: const Key('account-device-id-row'),
            ),
            if (id.isNotEmpty) ...[
              const SizedBox(height: ProxSpacing.xs),
              SelectableText(
                id,
                key: const Key('account-device-id-full'),
                style: ProxType.monoBody(
                    color: ProximityColors.of(context).contentSecondary),
              ),
            ],
            // Back-compat alias: older tests look for 'Install ID'.
            AccountFactRow(
              'Install ID',
              id.isEmpty ? 'Not assigned yet' : accountShortKey(id),
              mono: id.isNotEmpty,
            ),
            AccountFactRow(
              'Display name',
              hostName.trim().isNotEmpty ? hostName.trim() : acct.displayName,
            ),
          ],
        );
      },
    );
  }

  /// Read-only facts. `readInstallId` never creates one (unlike the
  /// claim-time `getOrCreateInstallId`): viewing Account must not write.
  Future<List<String?>> _profFacts(WidgetRef ref) async {
    String? installId;
    String hostName = '';
    try {
      installId = await ref.read(deviceStoreProvider).readInstallId();
    } catch (_) {
      installId = null;
    }
    try {
      hostName = await ref.read(deviceStoreProvider).readHostName();
    } catch (_) {
      hostName = '';
    }
    return [installId, hostName];
  }
}
