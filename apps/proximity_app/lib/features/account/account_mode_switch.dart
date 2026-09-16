//
// Mode-switch row (Account menu): a compact button that behaves EXACTLY
// like the student mark screen's top-right mode action (`screens/student_home.dart` AppBar — mirrored
// call-for-call, never reinvented):
//   IconButton(
//     icon: const Icon(Icons.switch_account),
//     tooltip: 'Switch mode',
//     onPressed: () => setMode(ref, AppMode.unset),
//   )
// Same icon, same `Switch mode` vocabulary (the mark action's tooltip,
// verbatim), same `setMode(ref, AppMode.unset)` exit path → landing hub.
// Attendance/network contracts untouched.
//
// Handoff: the hub owns acquire/switch checks from here on — landing→hub
// resume covers register + continue for both roles (see
// `features/entry/entry_flow.dart`, read-only context), so role
// acquire/switch checks live in exactly one place. Refusal/gate/enrollment
// semantics unchanged (all enforced downstream at the hub as today).
//
// Compact by constraint: button only, no prose, no header, no status. The
// button uses the existing `TextButton.icon` component (same component as
// the `AccountSignOutButton` footer row in `account_system.dart`), so no
// new button language is invented. Renders for ANY signed-in account
// (single-role included) — no role fetch, no gating, no hidden states.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth.dart';
import '../../design/tokens.dart';
import '../../mode.dart';
import 'account_common.dart';

/// One-button mode exit, composed INSIDE the Account pages (never a
/// shell-level affordance — `shells.dart` is read-only).
///
/// Stale-stack safe: the transition reset (root setup-flow dismissed first
/// per the product decision, then this tab popped to root) runs BEFORE the
/// mirrored `setMode(ref, AppMode.unset)` exit, so the previous identity's
/// pushed screens can never survive underneath. Mounted + busy guarded so
/// rapid taps cannot double-exit (same icon/label/key contract).
class AccountModeSwitch extends ConsumerStatefulWidget {
  final SignedAccount acct;
  const AccountModeSwitch({required this.acct, super.key});

  @override
  ConsumerState<AccountModeSwitch> createState() => _AccountModeSwitchState();
}

class _AccountModeSwitchState extends ConsumerState<AccountModeSwitch> {
  bool _busy = false;

  Future<void> _switchMode() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      prepareAccountTransition(context);
      if (!mounted) return;
      await setMode(ref, AppMode.unset);
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
          key: const Key('account-mode-switch'),
          style: TextButton.styleFrom(
            minimumSize: const Size(64, ProxSpacing.minTap),
          ),
          icon: const Icon(Icons.switch_account),
          label: const Text('Switch mode'),
          onPressed: _busy ? null : _switchMode,
        ),
      ),
    );
  }
}
