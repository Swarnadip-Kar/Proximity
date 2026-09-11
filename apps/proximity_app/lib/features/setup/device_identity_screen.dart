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
import '../entry/entry_flow.dart';
import 'device_sections.dart';

/// Device & identity status. Pushed from the RoleHub (plain
/// MaterialPageRoute — no mode change, so preview flags and relaunch
/// routing are untouched).
class DeviceIdentityScreen extends ConsumerWidget {
  const DeviceIdentityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const AdaptiveScaffold(
      title: 'Device & identity',
      body: DeviceIdentityBody(),
    );
  }
}

/// Standalone scroll around the shared content below.
class DeviceIdentityBody extends ConsumerWidget {
  const DeviceIdentityBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: DeviceIdentityContent(),
        ),
      ),
    );
  }
}

/// Scroll-free content, shared by the standalone route above and the
/// SetupFlow combined device+intro step (mechanical extraction — the state
/// implementation below is verbatim, only the scroll wrapper moved up).
///
/// Thin composer over the [device_sections] widgets: owns the
/// store/gate reads and sign-out, sections own the layout.
class DeviceIdentityContent extends ConsumerStatefulWidget {
  const DeviceIdentityContent({super.key});

  @override
  ConsumerState<DeviceIdentityContent> createState() =>
      _DeviceIdentityContentState();
}

class _DeviceIdentityContentState extends ConsumerState<DeviceIdentityContent> {
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
    // Re-entry guard (the button disables on rebuild, but a second tap can
    // race the first frame): a double-tap must never double-sign-out.
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      await entrySignOut(ref, () => mounted);
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
    // Scroll-free content: the standalone route (DeviceIdentityBody
    // above) and the SetupFlow combined device+intro step own the scroll.
    return ProxStaggered(
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
        DeviceAccountSection(account: acct, linked: linked),
        // Mobile-only: enrollment key + binding gate need the
        // device store + cloud claim + face/device trust stack,
        // none of which exists on web/desktop records builds
        if (canUseFace()) ...[
          DeviceKeySection(loadEnrollment: _enrollment),
          DeviceMoveSection(email: acct?.email, loadGate: _gate),
          const SizedBox(height: ProxSpacing.sm),
          const Divider(),
          const DeviceOfflineNote(),
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
    );
  }
}
