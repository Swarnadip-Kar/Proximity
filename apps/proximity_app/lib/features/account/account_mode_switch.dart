// One-button mode switch — tester-directed simplification.
//
// Product-owner override (One-button mode switch): REPLACES the Prof|Student
// segmented tabs + inline register entries from ## Account overhaul. ONE
// compact button that behaves EXACTLY like the student mark screen's
// top-right mode action (`screens/student_home.dart` AppBar — mirrored
// call-for-call, never reinvented):
//   IconButton(
//     icon: const Icon(Icons.switch_account),
//     tooltip: 'Switch mode',
//     onPressed: () => setMode(ref, AppMode.unset),
//   )
// Same icon, same `Switch mode` vocabulary (the mark action's tooltip,
// verbatim), same `setMode(ref, AppMode.unset)` exit path → landing hub.
// Presentation/navigation only; frozen copy-semantics/timings/thresholds/
// network untouched.
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

/// One-button mode exit, composed INSIDE the Account pages (never a
/// shell-level affordance — `shells.dart` is read-only).
class AccountModeSwitch extends ConsumerWidget {
  final SignedAccount acct;
  const AccountModeSwitch({required this.acct, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          onPressed: () => setMode(ref, AppMode.unset),
        ),
      ),
    );
  }
}
