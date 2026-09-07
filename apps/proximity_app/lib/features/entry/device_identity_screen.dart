// S03 Device & identity — the "which device am I on" screen.
//
// Purpose: answers three questions in one place, split out of the old
// landing + enrollment clutter: which Gmail is signed in vs enrolled on
// this install, does this device hold the student key, and where does the
// signed-in Gmail stand on the one-device move rule (free to enroll /
// this device / eligible to move / waits out the week with an exact date).
// Also carries the offline-professor local-only note and sign-out.
//
// Behavior: binding/move status reuses the exact claim verdict
// ([entryStudentGate] — same reasons the server refuses), read best-effort
// and online-gated (offline shows the connect note, never a stale
// verdict). Web records builds hold no key and run no gate: they see the
// records banner instead. Sign-out clears auth + role cache + linked
// identity (see [entrySignOut]) and pops back to the entry screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../mode.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/web_banner.dart';
import 'entry_flow.dart';

/// Device & identity status. Pushed from the RoleHub (plain
/// MaterialPageRoute — no mode change, so preview flags and relaunch
/// routing are untouched).
class DeviceIdentityScreen extends ConsumerStatefulWidget {
  const DeviceIdentityScreen({super.key});

  @override
  ConsumerState<DeviceIdentityScreen> createState() =>
      _DeviceIdentityScreenState();
}

class _DeviceIdentityScreenState extends ConsumerState<DeviceIdentityScreen> {
  String _status = '';
  bool _busy = false;

  Future<StoredEnrollment?> _enrollment() async {
    try {
      return await ref.read(deviceStoreProvider).readEnrollment();
    } catch (_) {
      return null;
    }
  }

  /// Move status for the signed-in Gmail, or null when it cannot be
  /// determined (offline / unavailable / signed out). Never throws.
  Future<StudentGate?> _gate(String? email) async {
    if (email == null || email.isEmpty || !canUseFace()) return null;
    try {
      final cloud = ref.read(cloudSyncProvider);
      if (!cloud.available || !(await cloud.isOnline())) return null;
      return await entryStudentGate(ref, email);
    } catch (_) {
      return null;
    }
  }

  Future<void> _signOut() async {
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      await entrySignOut(ref);
    } catch (e) {
      if (mounted) {
        setState(() => _status = '$e'.replaceFirst('StateError: ', ''));
      }
      BleLog.log('STATE', 'entry sign out failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // Account stream is now null: the entry host shows Welcome. Pop this
    // page so back never lands on a signed-out identity screen.
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final acct = ref.watch(accountProvider).valueOrNull;
    final linked = ref.watch(linkedIdentityProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return AdaptiveScaffold(
      title: 'Device & identity',
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ProxStaggered(
              children: [
                const WebRecordsBanner(),
                Text(
                  'Which account, which device.',
                  textAlign: TextAlign.center,
                  style: text.titleLarge,
                ),
                const SizedBox(height: ProxSpacing.xs),
                Text(
                  'One Gmail holds both roles; one phone holds one student enrollment.',
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: ProxSpacing.lg),
                ProxSectionHeader(
                  title: 'Signed in',
                  padding: EdgeInsets.zero,
                ),
                if (acct == null)
                  const ProxSyncNote(
                      'Not signed in — sign in from the welcome screen.')
                else ...[
                  Text('Signed in as ${acct.displayName}',
                      textAlign: TextAlign.center,
                      style: text.titleMedium),
                  Text(acct.email,
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      )),
                  if (linked != null &&
                      linked.gmail.toLowerCase() !=
                          acct.email.toLowerCase()) ...[
                    const SizedBox(height: ProxSpacing.sm),
                    ProxErrorNote(
                      'Note: this device is enrolled as ${linked.gmail} — different from the signed-in account. '
                      'Wrong account? Switch below.',
                    ),
                  ],
                ],
                // Mobile-only: enrollment key + binding gate need the
                // device store + cloud claim + face/device trust stack,
                // none of which exists on web/desktop records builds
                // (Track 5 — removed, not disabled).
                if (canUseFace()) ...[
                  const ProxSectionHeader(title: 'This device'),
                  FutureBuilder<StoredEnrollment?>(
                    future: _enrollment(),
                    builder: (context, snap) {
                      if (snap.connectionState ==
                          ConnectionState.waiting) {
                        return const Center(
                            child: CircularProgressIndicator());
                      }
                      final e = snap.data;
                      if (e == null) {
                        return const ProxSyncNote(
                          'No student key on this device yet — enrollment creates one (device key + face, online once).',
                        );
                      }
                      final shortPk = e.pkHex.length <= 12
                          ? e.pkHex
                          : '${e.pkHex.substring(0, 12)}…';
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ProxStateBadge(
                              state: ProxState.marked,
                              label: 'Enrolled as ${e.email}'),
                          ProxSyncNote(
                            '${e.name} · ${e.roll} · key $shortPk',
                          ),
                        ],
                      );
                    },
                  ),
                  const ProxSectionHeader(title: 'Move status'),
                  if (acct == null)
                    const ProxSyncNote(
                        'Sign in to check this Gmail against the one-device rule.')
                  else
                    FutureBuilder<StudentGate?>(
                      future: _gate(acct.email),
                      builder: (context, snap) {
                        if (snap.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }
                        final gate = snap.data;
                        if (gate == null) {
                          return const ProxSyncNote(
                            'Connect to check move status — one enrolled device per Gmail is checked online.',
                          );
                        }
                        return _gateBody(gate);
                      },
                    ),
                  const SizedBox(height: ProxSpacing.sm),
                  const Divider(),
                  Text(
                    'Offline professors keep everything on this device. Sign in later '
                    'to back up, sync across devices, and share CSVs from the cloud.',
                    textAlign: TextAlign.center,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: ProxSpacing.sm),
                  const Text(
                    'Records view only here — enrollment, keys, and device moves live in the mobile app (Android/iOS).',
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: ProxSpacing.lg),
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
            ),
          ),
        ),
      ),
    );
  }

  /// Move-status body for a known gate verdict. Refusal copy comes from
  /// [studentClaimMessage] — the same words the enroll claim refuses with.
  Widget _gateBody(StudentGate gate) {
    switch (gate.verdict.claim) {
      case StudentClaim.firstBind:
        return const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProxStateBadge(
                state: ProxState.neutral, label: 'Not enrolled yet'),
            ProxSyncNote(
                'This install is free to enroll — first bind takes it.'),
          ],
        );
      case StudentClaim.sameDevice:
        return const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProxStateBadge(
                state: ProxState.marked,
                label: 'This device holds the enrollment'),
            ProxSyncNote('Re-keys and re-enrolls here are always free.'),
          ],
        );
      case StudentClaim.allowedMove:
        return const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProxStateBadge(
                state: ProxState.waiting, label: 'Eligible to move here'),
            ProxSyncNote(
                'The week since the last move has passed — enrolling here moves it (at most once a week).'),
          ],
        );
      case StudentClaim.cooldownBlocked:
      case StudentClaim.installConflict:
        return ProxErrorNote(
            studentClaimMessage(gate.verdict, gate.binding));
    }
  }
}
