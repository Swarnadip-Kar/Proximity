// Role-hub sections: register / resume / add-role / footer.
//
// Split from role_hub_screen.dart (presentation only — same copy, same
// guards, same button labels). The screen owns the role-future cache, the
// busy/status state machine, and the entry_flow calls; sections own the
// layout. Secondary prose sits collapsed behind DetailsExpanders (§4.7);
// headers, buttons, fields, warnings, and status signals stay visible.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/platformx.dart';
import '../../design/tokens.dart';
import 'setup_details.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/web_banner.dart';

/// First-run registration (no held role yet). Web registers nothing;
/// records-only desktops register professor only; mobile registers both.
/// Long prose is collapsed — actions stay visible.
class RoleRegisterSection extends StatelessWidget {
  final TextEditingController profNameCtrl;
  final bool busy;
  final Future<void> Function() onRegisterProf;
  final Future<void> Function() onRegisterStudent;

  const RoleRegisterSection({
    super.key,
    required this.profNameCtrl,
    required this.busy,
    required this.onRegisterProf,
    required this.onRegisterStudent,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    // Web records builds register nothing (no enrollment/hosting there):
    // roles arrive from the cloud seed above, registered on the native app.
    if (kIsWeb) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          WebRecordsBanner(),
          SizedBox(height: ProxSpacing.sm),
          Text(
            'This sign-in holds no Proximity role yet. Register once '
            'in the native app, then return here to view records.',
            textAlign: TextAlign.center,
          ),
        ],
      );
    }
    if (!canUseFace()) {
      // Records-only desktop (Track 5): professor registration only — no
      // student enrollment UI here at all (no dead route to it). Students
      // enroll once in the mobile app.
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Register this sign-in as professor (this desktop is records + hosting):',
            textAlign: TextAlign.center,
            style: text.titleSmall,
          ),
          const SizedBox(height: ProxSpacing.sm),
          TextField(
            controller: profNameCtrl,
            decoration: const InputDecoration(
              labelText: 'Professor display name (for Register as Professor)',
              helperText: 'Gmail name is the default; shown to students.',
            ),
          ),
          const SizedBox(height: ProxSpacing.sm),
          ProxPrimaryButton(
            icon: const Icon(Icons.present_to_all),
            label: const Text('Register as Professor'),
            onPressed: busy ? null : onRegisterProf,
          ),
          SetupDetails(
            title: 'Why only professor here?',
            child: Text(
              'Student enrollment runs once in the mobile app (Android/iOS) — '
              'this desktop stays records + hosting only.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Register this sign-in (once per account):',
          textAlign: TextAlign.center,
          style: text.titleSmall,
        ),
        const SizedBox(height: ProxSpacing.sm),
        TextField(
          controller: profNameCtrl,
          decoration: const InputDecoration(
            labelText: 'Professor display name (for Register as Professor)',
            helperText: 'Gmail name is the default; shown to students.',
          ),
        ),
        const SizedBox(height: ProxSpacing.sm),
        ProxPrimaryButton(
          icon: const Icon(Icons.present_to_all),
          label: const Text('Register as Professor'),
          onPressed: busy ? null : onRegisterProf,
        ),
        const SizedBox(height: ProxSpacing.sm),
        ProxSecondaryButton(
          icon: const Icon(Icons.school),
          label: const Text('Register as Student'),
          onPressed: busy ? null : onRegisterStudent,
          expanded: true,
        ),
        SetupDetails(
          title: 'About holding both roles',
          child: Text(
            'Same Gmail can hold both roles — switch anytime. Professor '
            'works on many devices; student enrollment lives on exactly '
            'one device (moves to a new phone once a month).',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// Resume: last-used mode first, one tap to continue.
class RoleResumeSection extends StatelessWidget {
  final Map<String, String> role;
  final List<String> ordered;
  final String lastMode;
  final bool busy;
  final Future<void> Function(Map<String, String>, String) onContinue;

  const RoleResumeSection({
    super.key,
    required this.role,
    required this.ordered,
    required this.lastMode,
    required this.busy,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < ordered.length; i++) ...[
          if (i == 0)
            ProxPrimaryButton(
              icon: Icon(ordered[i] == 'prof'
                  ? Icons.present_to_all
                  : Icons.school),
              label: Text(ordered[i] == 'prof'
                  ? 'Continue as Professor'
                  : 'Continue as Student'),
              onPressed:
                  busy ? null : () => onContinue(role, ordered[i]),
            )
          else
            ProxSecondaryButton(
              icon: Icon(ordered[i] == 'prof'
                  ? Icons.present_to_all
                  : Icons.school),
              label: Text(ordered[i] == 'prof'
                  ? 'Continue as Professor'
                  : 'Continue as Student'),
              onPressed:
                  busy ? null : () => onContinue(role, ordered[i]),
              expanded: true,
            ),
          if (i == 0 && lastMode.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: ProxSpacing.xs),
              child: Text(
                'Last used — continues where you left off.',
                textAlign: TextAlign.center,
              ),
            ),
          const SizedBox(height: ProxSpacing.sm),
        ],
      ],
    );
  }
}

/// Add-the-other-role + lost-phone guidance. Registration stays visible;
/// the one-device rule and the lost-phone paragraph collapse.
class RoleAddRoleSection extends StatelessWidget {
  final bool hasProf;
  final bool hasStudent;
  final bool busy;
  final Future<void> Function() onRegisterProf;
  final Future<void> Function() onRegisterStudent;

  const RoleAddRoleSection({
    super.key,
    required this.hasProf,
    required this.hasStudent,
    required this.busy,
    required this.onRegisterProf,
    required this.onRegisterStudent,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // No extra registration on web records builds; no student
        // registration on records-only desktops (Track 5 — removed, not
        // disabled).
        if (!kIsWeb && (!hasProf || (canUseFace() && !hasStudent))) ...[
          Text(
            'Add the other role on this same sign-in:',
            textAlign: TextAlign.center,
            style: text.titleSmall,
          ),
          const SizedBox(height: ProxSpacing.sm),
          if (!hasProf)
            ProxSecondaryButton(
              icon: const Icon(Icons.present_to_all),
              label: const Text('Register as Professor'),
              onPressed: busy ? null : onRegisterProf,
              expanded: true,
            ),
          if (!hasStudent && canUseFace())
            ProxSecondaryButton(
              icon: const Icon(Icons.school),
              label: const Text('Register as Student'),
              onPressed: busy ? null : onRegisterStudent,
              expanded: true,
            ),
          SetupDetails(
            title: 'About the one-device rule',
            child: Text(
              'Professor works on many devices; student enrollment lives '
              'on exactly one device — it can move to a new phone once '
              'a month (unlimited moves, at most one per 30 days).',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
        if (hasProf && !kIsWeb) ...[
          const SizedBox(height: ProxSpacing.sm),
          const Divider(),
          SetupDetails(
            title: 'Lost your phone?',
            child: Text(
              'A student who lost their phone can re-enroll once the lost '
              'device has been offline 60 days — meanwhile mark them manually from the '
              'take-attendance screen (Request manual attendance or '
              'direct entry). No reset shortcut exists by design.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }
}

/// Footer: Device & identity entry, switch-account, and status signals.
class RoleFooterSection extends StatelessWidget {
  final bool busy;
  final String status;
  final void Function() onDeviceIdentity;
  final Future<void> Function() onSignOut;

  const RoleFooterSection({
    super.key,
    required this.busy,
    required this.status,
    required this.onDeviceIdentity,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: ProxSpacing.sm),
        TextButton.icon(
          icon: const Icon(Icons.devices_outlined),
          label: const Text('Device & identity'),
          onPressed: busy ? null : onDeviceIdentity,
        ),
        TextButton.icon(
          icon: const Icon(Icons.switch_account),
          label: const Text('Switch account (sign out)'),
          onPressed: busy ? null : onSignOut,
        ),
        if (status.isNotEmpty) ...[
          const SizedBox(height: ProxSpacing.sm),
          ProxErrorNote(status),
        ],
        if (busy) ...[
          const SizedBox(height: ProxSpacing.sm),
          const Center(child: CircularProgressIndicator()),
        ],
      ],
    );
  }
}
