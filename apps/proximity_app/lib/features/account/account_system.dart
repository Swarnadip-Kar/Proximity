// Account system sections — extracted verbatim from the page footers in
// `account_screen.dart` (presentational split only): system-log row +
// sign-out row. No copy changed; sign-out still calls `entrySignOut`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/tokens.dart';
import '../../routes.dart';
import '../../widgets/prox_cards.dart';
import '../entry/entry_flow.dart';

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
class AccountSignOutButton extends ConsumerWidget {
  const AccountSignOutButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          onPressed: () {
            unawaited(entrySignOut(ref));
          },
        ),
      ),
    );
  }
}
