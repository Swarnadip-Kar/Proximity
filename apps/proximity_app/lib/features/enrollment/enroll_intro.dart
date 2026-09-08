// EnrollIntro — bundle step 1: pre-context + account + device key.
//
// Gives the squeezed enrollment room to breathe: what happens
// (account → key → 5 angles → online claim), the internet-once note, the
// one-device-per-30-days explainer with its manual-attendance pointer, and
// the friendly retry brief near the start. Then account pickup (silent —
// students signed in on the landing) and the device key. The face scan
// itself lives on EnrollCapture; the claim outcome on EnrollResult.
//
// Web: student registration stays a native-only pointer (no camera /
// enrollment on records builds).
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enrollment.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../features/face_identity/face_blocked.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import 'enroll_flow.dart';
import 'enroll_widgets.dart';

class EnrollIntroScreen extends ConsumerStatefulWidget {
  const EnrollIntroScreen({super.key});

  @override
  ConsumerState<EnrollIntroScreen> createState() => _EnrollIntroScreenState();
}

class _EnrollIntroScreenState extends ConsumerState<EnrollIntroScreen> {
  var _logged = false;

  @override
  void initState() {
    super.initState();
    // Silent account pickup (post-frame: pickup notifies listeners).
    // Fresh installs with no session keep the manual sign-in button below.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
          ref.read(enrollmentControllerProvider.notifier).pickUpAccount());
      if (!_logged) {
        _logged = true;
        EnrollLog.nav('enroll intro shown');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Desktop/web are records-only (Track 5): no enrollment UI here at
    // all — the blocked card is the whole screen, never a disabled form.
    // Deep-links to enroll/* on records-only devices redirect to records
    // guidance (see ProxRoutes.mobileGuardRedirect); this is the second
    // gate for direct pushes.
    if (!canUseFace()) {
      return ProxScreen(
        title: 'Enroll this device',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FaceBlockedCard(flow: 'Face enrollment'),
            const SizedBox(height: ProxSpacing.md),
            ProxSecondaryButton(
              label: const Text('Back'),
              expanded: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
    }
    final st = ref.watch(enrollmentControllerProvider);
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    final hasAccount = st.account != null;
    final hasKey = st.pkHex.isNotEmpty;
    return ProxScreen(
      title: 'Enroll this device',
      child: ProxStaggered(
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
          const ProxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _IntroStep(
                  n: '1',
                  title: 'Google account',
                  detail: 'Picked up silently from sign-in — no second tap.',
                ),
                SizedBox(height: ProxSpacing.sm),
                _IntroStep(
                  n: '2',
                  title: 'Device key',
                  detail: 'Generated on this phone, kept in secure storage.',
                ),
                SizedBox(height: ProxSpacing.sm),
                _IntroStep(
                  n: '3',
                  title: 'Five guided face angles',
                  detail: 'Centre · Left · Right · Up · Down — '
                      'small turns and tilts, head near-frontal throughout, '
                      'one continuous camera session, fully automatic: just '
                      'rotate slowly with the glow around the oval, each '
                      'angle really angle-checked. '
                      'The template never leaves this phone.',
                ),
                SizedBox(height: ProxSpacing.sm),
                _IntroStep(
                  n: '4',
                  title: 'Online claim',
                  detail: 'One enrolled student device per Gmail, '
                      'checked online.',
                ),
              ],
            ),
          ),
          const SizedBox(height: ProxSpacing.md),
          const ProxCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.wifi_outlined),
                SizedBox(width: ProxSpacing.sm),
                Expanded(
                  child: Text(
                    'Needs internet once — the one-device-per-Gmail check '
                    'runs online. Later attendance works fully offline. '
                    'During class your proof carries a compact face vector '
                    '(numbers only, no photo) to the professor\u2019s phone '
                    'over classroom WiFi — held in memory for that session '
                    'only, never the cloud.',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: ProxSpacing.md),
          const ProxCard(
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
          ),
          const SizedBox(height: ProxSpacing.lg),
          if (kIsWeb)
            const ProxCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline),
                  SizedBox(width: ProxSpacing.sm),
                  Expanded(
                    child: Text(
                      'Student registration needs the native app — the web '
                      'build is records-viewing only (no camera or '
                      'enrollment here).',
                    ),
                  ),
                ],
              ),
            )
          else ...[
            ProxCard(
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
                      key: ValueKey(
                          st.account!.email.toLowerCase()),
                      initialValue: st.roll,
                      onChanged: ctl.setRoll,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: ProxSpacing.md),
            ProxCard(
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
                                !hasAccount ? null : ctl.generateKey,
                          )
                        : Text(
                            'Key: ${st.pkHex.length >= 16 ? st.pkHex.substring(0, 16) : st.pkHex}…',
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: ProxSpacing.lg),
            ProxPrimaryButton(
              icon: const Icon(Icons.face),
              label: const Text('Continue to face scan'),
              // The scan needs the key first — never silently drop.
              onPressed: !hasKey
                  ? null
                  : () {
                      EnrollLog.nav(
                          'intro → capture (key ${st.pkHex.length >= 8 ? st.pkHex.substring(0, 8) : st.pkHex}…)');
                      EnrollFlow.openCapture(context);
                    },
            ),
            if (!hasKey)
              const ProxSyncNote(
                'Sign in and generate the device key to continue.',
              ),
          ],
        ],
      ),
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
