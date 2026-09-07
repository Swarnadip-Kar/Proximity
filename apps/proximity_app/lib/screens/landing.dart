// Landing: thin entry router. Watches the signed-in account stream and
// shows Welcome (signed out) vs RoleHub (signed in). All sign-in, role,
// merge, claim-gate, and last-mode logic lives in the entry bundle
// (features/entry/entry_flow.dart + welcome/role_hub/device screens) —
// this file owns no auth state, no cloud calls, no navigation decisions.
// Preserves the PROX_MODE preview contract via main.dart home (this screen
// only serves AppMode.unset) and the web records guards via the entry
// screens themselves.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth.dart';
import '../features/entry/role_hub_screen.dart';
import '../features/entry/welcome_screen.dart';
import '../widgets/prox_scaffold.dart';
import '../widgets/prox_states.dart';

class LandingScreen extends ConsumerWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountAsync = ref.watch(accountProvider);
    return accountAsync.when(
      data: (acct) =>
          acct == null ? const WelcomeScreen() : RoleHubScreen(account: acct),
      loading: () => const ProxScreen(
        title: 'Proximity',
        child: ProxLoadingRow(label: 'Loading…'),
      ),
      error: (e, _) => ProxScreen(
        title: 'Proximity',
        child: ProxErrorNote('Sign-in state unreadable: $e'),
      ),
    );
  }
}
