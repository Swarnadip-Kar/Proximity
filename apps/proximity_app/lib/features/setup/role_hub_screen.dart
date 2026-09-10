// S02 RoleHub — the authenticated entry screen.
//
// Purpose: resume, not choose. Shows who is signed in (+ held roles),
// continues last-mode-first with one tap (zero-tap state is the resume
// button), registers the first role or adds the other role on the same
// Gmail, warns on wrong-account (enrolled ≠ signed-in), and offers switch
// account + the Device & identity screen.
//
// Absorbs the signed-in branch of screens/landing.dart (_signedInBody +
// _roleFor + register/continue/stamp/merge): same role-cache seeding
// (fresh-install cloud fallback), same claim-gate verdicts, same web
// guards (no registration, no binding gate on web records builds), same
// copy and button labels so existing flows and widget tests are
// unaffected. All auth/role/cloud decisions live in entry_flow.dart;
// this file owns only the hub UI.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../mode.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/web_banner.dart';
import 'device_identity_screen.dart';
import 'entry_flow.dart';

/// Authenticated role hub. [account] comes from `accountProvider`
/// (proposed: landing router shows this when the stream is non-null).
class RoleHubScreen extends ConsumerStatefulWidget {
  final SignedAccount account;
  const RoleHubScreen({super.key, required this.account});

  @override
  ConsumerState<RoleHubScreen> createState() => _RoleHubScreenState();
}

class _RoleHubScreenState extends ConsumerState<RoleHubScreen> {
  String _status = '';
  bool _busy = false;
  final _profNameCtrl = TextEditingController();
  bool _profNameSeeded = false;

  /// Cached role futures per account email: a fresh `future:` every build
  /// refires fetchRole/writeRole on each rebuild — cache by email so
  /// rebuilds reuse it.
  final Map<String, Future<Map<String, String>?>> _roleFutures = {};

  @override
  void dispose() {
    _profNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        setState(() => _status = '$e'.replaceFirst('StateError: ', ''));
      }
      BleLog.log('STATE', 'entry hub action failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _registerProf() => _run(() => entryRegisterProf(
      ref, () => mounted, widget.account, _profNameCtrl.text));

  Future<void> _registerStudent() =>
      _run(() => entryRegisterStudent(ref, () => mounted, widget.account));

  Future<void> _continueWithRole(
          Map<String, String> role, String which) =>
      _run(
          () => entryContinueWithRole(ref, () => mounted, widget.account, role, which));

  Future<void> _signOut() => _run(() => entrySignOut(ref));

  void _openDeviceIdentity() {
    BleLog.log('NAV', 'entry open device & identity');
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DeviceIdentityScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final acct = widget.account;
    if (!_profNameSeeded) {
      _profNameCtrl.text = acct.displayName;
      _profNameSeeded = true;
    }
    final linked = ref.watch(linkedIdentityProvider);
    final roleFuture = _roleFutures.putIfAbsent(
        acct.email.toLowerCase(), () => entryRoleFor(ref, acct));
    return AdaptiveScaffold(
      title: 'Proximity',
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: FutureBuilder<Map<String, String>?>(
              future: roleFuture,
              builder: (context, snap) {
                final role = snap.data;
                final emailOk = role != null &&
                    (role['email'] ?? '').toLowerCase() ==
                        acct.email.toLowerCase();
                final held =
                    emailOk ? roleSet(role) : const <String>{};
                final hasProf = held.contains('prof');
                final hasStudent = held.contains('student');
                // Last-used mode first — relaunch and return visits
                // default here.
                final ordered = {
                  if (roleLastMode(role) == 'student' && hasStudent)
                    'student',
                  if (roleLastMode(role) != 'student' && hasProf) 'prof',
                  if (roleLastMode(role) == 'student' && hasProf) 'prof',
                  if (roleLastMode(role) != 'student' && hasStudent)
                    'student',
                }.toList();
                return ProxStaggered(
                  children: [
                    ProxIdentityHeader(
                        displayName: acct.displayName,
                        email: acct.email,
                        heldLabel:
                            emailOk ? entryHeldLabel(role) : ''),
                    if (linked != null &&
                        linked.gmail.toLowerCase() !=
                            acct.email.toLowerCase()) ...[
                      const SizedBox(height: ProxSpacing.sm),
                      ProxErrorNote(
                        'Note: this device is enrolled as ${linked.gmail} — different from the signed-in account. '
                        'Wrong account? Switch below.',
                      ),
                    ],
                    const SizedBox(height: ProxSpacing.lg),
                    if (snap.connectionState == ConnectionState.waiting &&
                        role == null) ...[
                      const Center(child: CircularProgressIndicator()),
                    ] else if (!hasProf && !hasStudent) ...[
                      // Web records builds register nothing (no
                      // enrollment/hosting there): roles arrive from the
                      // cloud seed above, registered on the native app.
                      if (kIsWeb) ...[
                        const WebRecordsBanner(),
                        const SizedBox(height: ProxSpacing.sm),
                        const Text(
                          'This sign-in holds no Proximity role yet. Register once '
                          'in the native app, then return here to view records.',
                          textAlign: TextAlign.center,
                        ),
                      ] else if (!canUseFace()) ...[
                        // Records-only desktop (Track 5): professor
                        // registration only — no student enrollment UI
                        // here at all (no dead route to it). Students
                        // enroll once in the mobile app.
                        Text(
                          'Register this sign-in as professor (this desktop is records + hosting):',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: ProxSpacing.sm),
                        TextField(
                          controller: _profNameCtrl,
                          decoration: const InputDecoration(
                            labelText:
                                'Professor display name (for Register as Professor)',
                            helperText:
                                'Gmail name is the default; shown to students.',
                          ),
                        ),
                        const SizedBox(height: ProxSpacing.sm),
                        ProxPrimaryButton(
                          icon: const Icon(Icons.present_to_all),
                          label: const Text('Register as Professor'),
                          onPressed: _busy ? null : _registerProf,
                        ),
                        const SizedBox(height: ProxSpacing.xs),
                        const Text(
                          'Student enrollment runs once in the mobile app (Android/iOS) — '
                          'this desktop stays records + hosting only.',
                          textAlign: TextAlign.center,
                        ),
                      ] else ...[
                        Text(
                          'Register this sign-in (once per account):',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: ProxSpacing.sm),
                        TextField(
                          controller: _profNameCtrl,
                          decoration: const InputDecoration(
                            labelText:
                                'Professor display name (for Register as Professor)',
                            helperText:
                                'Gmail name is the default; shown to students.',
                          ),
                        ),
                        const SizedBox(height: ProxSpacing.sm),
                        ProxPrimaryButton(
                          icon: const Icon(Icons.present_to_all),
                          label: const Text('Register as Professor'),
                          onPressed: _busy ? null : _registerProf,
                        ),
                        const SizedBox(height: ProxSpacing.sm),
                        ProxSecondaryButton(
                          icon: const Icon(Icons.school),
                          label: const Text('Register as Student'),
                          onPressed: _busy ? null : _registerStudent,
                          expanded: true,
                        ),
                        const SizedBox(height: ProxSpacing.xs),
                        Text(
                          'Same Gmail can hold both roles — switch anytime. Professor '
                          'works on many devices; student enrollment lives on exactly '
                          'one device (moves to a new phone once a month).',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                    ] else ...[
                      for (var i = 0; i < ordered.length; i++) ...[
                        if (i == 0)
                          ProxPrimaryButton(
                            icon: Icon(ordered[i] == 'prof'
                                ? Icons.present_to_all
                                : Icons.school),
                            label: Text(ordered[i] == 'prof'
                                ? 'Continue as Professor'
                                : 'Continue as Student'),
                            onPressed: _busy
                                ? null
                                : () =>
                                    _continueWithRole(role!, ordered[i]),
                          )
                        else
                          ProxSecondaryButton(
                            icon: Icon(ordered[i] == 'prof'
                                ? Icons.present_to_all
                                : Icons.school),
                            label: Text(ordered[i] == 'prof'
                                ? 'Continue as Professor'
                                : 'Continue as Student'),
                            onPressed: _busy
                                ? null
                                : () =>
                                    _continueWithRole(role!, ordered[i]),
                            expanded: true,
                          ),
                        if (i == 0 && roleLastMode(role).isNotEmpty)
                          const Padding(
                            padding:
                                EdgeInsets.only(top: ProxSpacing.xs),
                            child: Text(
                              'Last used — continues where you left off.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        const SizedBox(height: ProxSpacing.sm),
                      ],
                      // No extra registration on web records builds; no
                      // student registration on records-only desktops
                      // (Track 5 — removed, not disabled).
                      if (!kIsWeb && (!hasProf || (canUseFace() && !hasStudent))) ...[
                        Text(
                          'Add the other role on this same sign-in:',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: ProxSpacing.sm),
                        if (!hasProf)
                          ProxSecondaryButton(
                            icon: const Icon(Icons.present_to_all),
                            label: const Text('Register as Professor'),
                            onPressed: _busy ? null : _registerProf,
                            expanded: true,
                          ),
                        if (!hasStudent && canUseFace())
                          ProxSecondaryButton(
                            icon: const Icon(Icons.school),
                            label: const Text('Register as Student'),
                            onPressed: _busy ? null : _registerStudent,
                            expanded: true,
                          ),
                        const SizedBox(height: ProxSpacing.xs),
                        Text(
                          'Professor works on many devices; student enrollment lives '
                          'on exactly one device — it can move to a new phone once '
                          'a week (unlimited times).',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                      if (hasProf && !kIsWeb) ...[
                        const SizedBox(height: ProxSpacing.sm),
                        const Divider(),
                        Text(
                          'A student who lost their phone waits out the week for '
                          're-enrollment — meanwhile mark them manually from the '
                          'take-attendance screen (Request manual attendance or '
                          'direct entry). No reset shortcut exists by design.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                    ],
                    const SizedBox(height: ProxSpacing.sm),
                    TextButton.icon(
                      icon: const Icon(Icons.devices_outlined),
                      label: const Text('Device & identity'),
                      onPressed: _busy ? null : _openDeviceIdentity,
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.switch_account),
                      label: const Text('Switch account (sign out)'),
                      onPressed: _busy ? null : _signOut,
                    ),
                    if (_status.isNotEmpty) ...[
                      const SizedBox(height: ProxSpacing.sm),
                      ProxErrorNote(_status),
                    ],
                    if (_busy) ...[
                      const SizedBox(height: ProxSpacing.sm),
                      const Center(child: CircularProgressIndicator()),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
