// Enroll-intro sections: account / device key.
//
// Account/key sections read the enrollment controller themselves and
// share the single-entry roll field (keyed by account so a switch
// rebuilds it empty, never with stale text).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enrollment.dart';
import '../../design/tokens.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import 'enroll_widgets.dart';

/// Google-account card: silent pickup display + the single ID-number
/// entry (typed once here, shown readonly on the save step).
class IntroAccountSection extends ConsumerWidget {
  const IntroAccountSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(enrollmentControllerProvider);
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    return ProxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '1 · Google account',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: ProxSpacing.sm),
          if (st.account == null)
            ProxPrimaryButton(
              icon: const Icon(Icons.login),
              label: const Text('Sign in with Google'),
              onPressed: ctl.signIn,
            )
          else ...[
            Text(
              'Signed in as ${st.account!.displayName}\n'
              '${st.account!.email}',
            ),
            const SizedBox(height: ProxSpacing.sm),
            // Single entry: typed once here, shown readonly on the
            // save step (shared component, keyed by account so a
            // switch rebuilds it empty, never with stale text).
            EnrollRollField(
              key: ValueKey(st.account!.email.toLowerCase()),
              initialValue: st.roll,
              onChanged: ctl.setRoll,
            ),
          ],
        ],
      ),
    );
  }
}

/// Device-key card: generate action or the created-key prefix.
class IntroKeySection extends ConsumerWidget {
  const IntroKeySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(enrollmentControllerProvider);
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    final hasAccount = st.account != null;
    final hasKey = st.pkHex.isNotEmpty;
    return ProxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '2 · Device key',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: ProxSpacing.sm),
          Opacity(
            opacity: hasAccount ? 1.0 : 0.45,
            child: !hasKey
                ? ProxPrimaryButton(
                    // Silent-skip guard: no key without sign-in.
                    label: const Text('Generate device key'),
                    onPressed: !hasAccount ? null : ctl.generateKey,
                  )
                : Text(
                    'Key: ${st.pkHex.length >= 16 ? st.pkHex.substring(0, 16) : st.pkHex}…',
                  ),
          ),
        ],
      ),
    );
  }
}
