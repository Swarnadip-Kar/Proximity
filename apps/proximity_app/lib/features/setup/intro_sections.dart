// Enroll-intro sections: overview / online note / one-device rule /
// account / device key.
//
// guards, same single-entry roll field). The content widget owns the
// scope-aware Continue; account/key sections read the enrollment
// controller themselves. Angle detail and WiFi detail sit collapsed
// behind DetailsExpanders (§4.7); titles, essentials, actions, and the
// retry brief stay visible.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enrollment.dart';
import '../../design/tokens.dart';
import 'setup_details.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import 'enroll_widgets.dart';

/// What-happens overview: title + subtitle + retry brief + the 4-step
/// card. Step 3 keeps its angles list and the on-phone guarantee
/// visible; the capture-choreography middle sits collapsed.
class IntroOverviewSection extends StatelessWidget {
  const IntroOverviewSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Enroll this device',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: ProxSpacing.xs),
        Text(
          'One-time setup — about 2 minutes, online once. '
          'Your name imports from Gmail; type your ID number once below.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: ProxSpacing.lg),
        // Reassurance near the start: a friendly brief, never an error.
        const ProxCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.sentiment_satisfied_outlined),
              SizedBox(width: ProxSpacing.sm),
              Expanded(
                child: Text(
                  enrollRetryBrief,
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: ProxSpacing.md),
        ProxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _IntroStep(
                n: '1',
                title: 'Google account',
                detail: 'Picked up silently from sign-in — no second tap.',
              ),
              const SizedBox(height: ProxSpacing.sm),
              const _IntroStep(
                n: '2',
                title: 'Device key',
                detail: 'Generated on this phone, kept in secure storage.',
              ),
              const SizedBox(height: ProxSpacing.sm),
              const _IntroStep(
                n: '3',
                title: 'Five guided face angles',
                detail: 'Centre · Left · Right · Up · Down — '
                    'small turns and tilts. '
                    'The template never leaves this phone.',
              ),
              SetupDetails(
                title: 'What the five angles involve',
                child: Text(
                  'Head near-frontal throughout, one continuous camera '
                  'session, fully automatic: just rotate slowly with the '
                  'glow around the oval, each angle really angle-checked.',
                ),
              ),
              const SizedBox(height: ProxSpacing.sm),
              const _IntroStep(
                n: '4',
                title: 'Online claim',
                detail: 'One enrolled student device per Gmail, '
                    'checked online.',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _IntroStep extends StatelessWidget {
  final String n;
  final String title;
  final String detail;
  const _IntroStep({
    required this.n,
    required this.title,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.primary.withValues(alpha: 0.12),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
          ),
          child: Text(
            n,
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: ProxSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                detail,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Internet-once note: the online check + offline-later essentials stay
/// visible; the face-vector transport detail collapses.
class IntroOnlineSection extends StatelessWidget {
  const IntroOnlineSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ProxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.wifi_outlined),
              SizedBox(width: ProxSpacing.sm),
              Expanded(
                child: Text(
                  'Needs internet once — the one-device-per-Gmail check '
                  'runs online. Later attendance works fully offline.',
                ),
              ),
            ],
          ),
          SetupDetails(
            title: 'What goes over WiFi',
            child: Text(
              'During class your proof carries a compact face vector '
              '(numbers only, no photo) to the professor\u2019s phone '
              'over classroom WiFi — held in memory for that session '
              'only, never the cloud.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One-device-per-30-days rule with the manual-attendance pointer.
/// Essential and short — fully visible.
class IntroOneDeviceSection extends StatelessWidget {
  const IntroOneDeviceSection({super.key});

  @override
  Widget build(BuildContext context) {
    return const ProxCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.smartphone_outlined),
          SizedBox(width: ProxSpacing.sm),
          Expanded(
            child: Text(
              'One Gmail lives on one enrolled device at a time. A '
              'move to a new phone is allowed once every 30 days '
              '(unlimited times) — the exact re-enroll date shows if '
              'you try early. One phone holds one student Gmail. '
              'Stuck in between? Ask your professor for manual '
              'attendance (Request manual attendance in class).',
            ),
          ),
        ],
      ),
    );
  }
}

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
