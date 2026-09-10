//
// consolidated-page direction (one sectioned page + DetailsExpander).
// The root is now compact by hard constraint: header chip + mode switch +
// plain navigation rows only (Enrollment >, Device >, Face ID >,
// System log >) + inline Appearance theme at the end (above sign-out) +
// small sign-out action. No explainer cards, no embedded sections, no long
// prose on the root; every fact block lives exactly one level down in its
// in behavior into:
// - Enrollment (+ editable ID + inline device/binding rules) → `account_enrollment_page.dart`
// - Device (facts + trust honesty + inline days/why) → `account_device_page.dart`
// - Appearance (theme) → inline `AccountThemeRow` at the root end (no sub-page)
// - Face ID (existing screen, student+enrolled only, inline rescan rules)
// - System log (existing debug/log)
//
// Preserved from prior ## Account entries: per-account scoping,
// re-enroll gating (no enroll CTA while enrolled — now enforced in the
// sub-pages), photo (`AccountHeaderCard` passthrough), switch behavior
// (`AccountModeSwitch` runs the identical continue/register machinery).
//
// `studentClaimMessage` verbatim; move cadence reads `once a month`
// (code is 30-day `kStudentMoveCooldown` — gap 6).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../mode.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/web_banner.dart';
import '../setup/welcome_screen.dart';
import 'account_common.dart';
import 'account_device_page.dart';
import 'account_enrollment_page.dart';
import 'account_header.dart';
import 'account_mode_switch.dart';
import 'account_system.dart';
import 'account_theme.dart';
import 'face_id_screen.dart';

// ---------------------------------------------------------------------------
// Student menu root (§5 overridden → compact menu).
// ---------------------------------------------------------------------------

/// Student Account tab root. Signed out renders the same Welcome the hub
/// route renders (the tab's signed-out behavior is unchanged).
class StudentAccountScreen extends ConsumerWidget {
  const StudentAccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acct = ref.watch(accountProvider).valueOrNull;
    if (acct == null) return const WelcomeScreen();
    final header = AccountHeaderCard(acct: acct);
    final recordsOnly = !canUseFace();
    return ProxScreen(
      title: 'Account',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const WebRecordsBanner(),
          const SizedBox(height: ProxSpacing.sm),
          header,
          const SizedBox(height: ProxSpacing.lg),
          AccountModeSwitch(acct: acct),
          const SizedBox(height: ProxSpacing.md),
          if (recordsOnly)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: ProxSpacing.lg),
              child: Text(
                'Records view only here — enrollment, keys, and device moves live in the mobile app (Android/iOS).',
                textAlign: TextAlign.center,
              ),
            )
          else ...[
            ProxListTile(
              key: const Key('account-row-enrollment'),
              title: 'Enrollment',
              leading: const Icon(Icons.school_outlined),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    settings:
                        const RouteSettings(name: 'account/enrollment'),
                    builder: (_) => AccountEnrollmentPage(acct: acct),
                  ),
                );
              },
            ),
            const SizedBox(height: ProxSpacing.sm),
            ProxListTile(
              key: const Key('account-row-device'),
              title: 'Device',
              leading: const Icon(Icons.smartphone_outlined),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    settings: const RouteSettings(name: 'account/device'),
                    builder: (_) => AccountDevicePage(acct: acct),
                  ),
                );
              },
            ),
            const SizedBox(height: ProxSpacing.sm),
          ],
          if (!recordsOnly) ...[
            _StudentFaceIdEntry(acct: acct),
            const SizedBox(height: ProxSpacing.sm),
          ],
          const AccountSystemLogRow(),
          const SizedBox(height: ProxSpacing.xl),
          const ProxSectionHeader(title: 'Appearance'),
          const SizedBox(height: ProxSpacing.sm),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: ProxSpacing.sm),
            child: AccountThemeRow(),
          ),
          const SizedBox(height: ProxSpacing.xl),
          const Divider(),
          const SizedBox(height: ProxSpacing.md),
          const AccountSignOutButton(),
          const SizedBox(height: ProxSpacing.lg),
        ],
      ),
    );
  }
}

/// Face-ID menu entry: student+enrolled only (existing screen). Scoped to
/// the current account (stale-account fix): another Gmail's enrollment
/// never opens this account's Face ID row.
class _StudentFaceIdEntry extends ConsumerWidget {
  final SignedAccount acct;
  const _StudentFaceIdEntry({required this.acct});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linked = ref.watch(linkedIdentityProvider);
    return FutureBuilder(
      future: readAccountEnrollment(ref),
      builder: (context, snap) {
        if (!enrolledForAccount(acct, linked, snap.data)) {
          return const SizedBox.shrink();
        }
        return ProxListTile(
          key: const Key('account-row-face-id'),
          title: 'Face ID',
          leading: const Icon(Icons.face),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                settings: const RouteSettings(name: 'account/face-id'),
                builder: (_) => const FaceIdScreen(),
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Professor menu root (§5.3, same compact pattern, scoped to professor
// facts — header, mode tabs, device, appearance, system log, sign out.
// NO Face-ID row, NO enrollment row.
// ---------------------------------------------------------------------------

/// Professor Account tab root. Signed out renders Welcome, same as the
/// student page and the hub route before it.
class ProfAccountScreen extends ConsumerWidget {
  const ProfAccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acct = ref.watch(accountProvider).valueOrNull;
    if (acct == null) return const WelcomeScreen();
    final header = AccountHeaderCard(acct: acct);
    return ProxScreen(
      title: 'Account',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const WebRecordsBanner(),
          const SizedBox(height: ProxSpacing.sm),
          header,
          const SizedBox(height: ProxSpacing.lg),
          AccountModeSwitch(acct: acct),
          const SizedBox(height: ProxSpacing.md),
          ProxListTile(
            key: const Key('account-row-device'),
            title: 'Device',
            leading: const Icon(Icons.smartphone_outlined),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  settings: const RouteSettings(name: 'account/device'),
                  builder: (_) => AccountProfDevicePage(acct: acct),
                ),
              );
            },
          ),
          const SizedBox(height: ProxSpacing.sm),
          const AccountSystemLogRow(),
          const SizedBox(height: ProxSpacing.xl),
          const ProxSectionHeader(title: 'Appearance'),
          const SizedBox(height: ProxSpacing.sm),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: ProxSpacing.sm),
            child: AccountThemeRow(),
          ),
          const SizedBox(height: ProxSpacing.xl),
          const Divider(),
          const SizedBox(height: ProxSpacing.md),
          const AccountSignOutButton(),
          const SizedBox(height: ProxSpacing.lg),
        ],
      ),
    );
  }
}
