// Account system sections — extracted verbatim from the page footers into
// the log + sign-out rows. No copy changed; sign-out still calls `entrySignOut`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/tokens.dart';
import '../../routes.dart';
import '../../widgets/prox_cards.dart';
import '../entry/entry_flow.dart';
import 'account_common.dart';

/// System-log row: opens the filterable terminal (`debug/log`).
class AccountSystemLogRow extends StatelessWidget {
  const AccountSystemLogRow({super.key});

  @override
  Widget build(BuildContext context) {
    return ProxListTile(
      key: const Key('account-system-log-row'),
      title: 'System log',
      subtitle: 'Filterable terminal',
      leading: const Icon(Icons.terminal_outlined),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => ProxNav.openDebugLog(context),
    );
  }
}

/// Sign-out row: separated bottom action (extra spacing owned by the page).
/// Direct `entrySignOut` call — the re-sign-in guard helper was dropped by
/// the product owner (verified zero references), so no confirm wrapper here.
///
/// Stale-stack + double-tap safe: the transition reset (root setup-flow
/// dismissed first per the product decision, then this tab popped to root)
/// runs BEFORE the sign-out so the previous identity's pushed screens can
/// never survive underneath; the mounted + busy guard drops rapid second
/// taps so a double-tap cannot double-sign-out (same key/label/icon —
/// the footer contract is unchanged).
class AccountSignOutButton extends ConsumerStatefulWidget {
  const AccountSignOutButton({super.key});

  @override
  ConsumerState<AccountSignOutButton> createState() =>
      _AccountSignOutButtonState();
}

class _AccountSignOutButtonState extends ConsumerState<AccountSignOutButton> {
  bool _busy = false;

  Future<void> _signOut() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      prepareAccountTransition(context);
      if (!mounted) return;
      await entrySignOut(ref, () => mounted);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ProxSpacing.sm),
      child: Center(
        child: TextButton.icon(
          key: const Key('account-sign-out'),
          style: TextButton.styleFrom(
            minimumSize: const Size(64, ProxSpacing.minTap),
          ),
          icon: const Icon(Icons.switch_account),
          label: const Text('Switch account (sign out)'),
          onPressed: _busy ? null : _signOut,
        ),
      ),
    );
  }
}
