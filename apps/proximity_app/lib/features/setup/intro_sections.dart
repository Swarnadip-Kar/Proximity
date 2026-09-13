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
import '../../widgets/prox_states.dart';
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
///
/// Single-flight: the button disables while a generation is in flight.
/// Without this, rapid taps stack concurrent generations on the same
/// KeyStore alias + concurrent biometric prompts, and every run strands
/// (probe logged, no prompt, no error) — see generateKey budgets.
class IntroKeySection extends ConsumerStatefulWidget {
  const IntroKeySection({super.key});

  @override
  ConsumerState<IntroKeySection> createState() => _IntroKeySectionState();
}

class _IntroKeySectionState extends ConsumerState<IntroKeySection> {
  var _busy = false;

  Future<void> _generate() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(enrollmentControllerProvider.notifier).generateKey();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(enrollmentControllerProvider);
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
                    onPressed:
                        (!hasAccount || _busy) ? null : _generate,
                  )
                : Text(
                    'Key: ${st.pkHex.length >= 16 ? st.pkHex.substring(0, 16) : st.pkHex}…',
                  ),
          ),
          // Key-step failures are controller-state (never exceptions past
          // the button): render them here or a refused bind looks like
          // "nothing happened" and invites tap-stacking.
          if (!hasKey &&
              st.phase == EnrollPhase.error &&
              st.message.isNotEmpty) ...[
            const SizedBox(height: ProxSpacing.sm),
            ProxErrorNote(st.message),
          ],
        ],
      ),
    );
  }
}
