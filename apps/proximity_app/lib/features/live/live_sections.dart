// Live focused section screens (Track 5 split).
//
// Reason to exist: the live host (`TakeAttendanceScreen`) was one 800-line
// page carrying setup + header + roster + inbox + direct-add + recovery.
// Each section below is ONE purpose, readable mid-lecture without the
// control cluster, and directly deep-linkable (`live/<course>/roster`
// etc.). They read the same live host driver the host screen owns —
// pushed atop a hosting host they show live data; opened cold (no host
// below) they show guidance instead of a dead list, never a crash.
//
// Behavior is unchanged: decisions delegate to the host driver (the same
// narrow interface the host screen uses); drafts/snapshots stay owned by
// the host visit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';

import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../core/host_driver.dart';
import '../../core/sync_hook.dart';
import '../../design/tokens.dart';
import '../../widgets/clock.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import '../debug/debug_log_screen.dart';
import 'direct_add.dart';
import 'live_roster.dart';
import 'manual_inbox.dart';

/// Shared shell for live sections: title + back to the host screen.
class _LiveSectionShell extends StatelessWidget {
  final String title;
  final String reason;
  final Widget child;
  const _LiveSectionShell({
    required this.title,
    required this.reason,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ProxScreen(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            reason,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: ProxSpacing.sm),
          child,
        ],
      ),
    );
  }
}

/// Guidance when no live host owns this course (cold deep-link).
Widget _noHostNote(String course) => ProxSyncNote(
      'No live host for $course on this device right now — open Take attendance on its course to host, then return here.',
    );

/// Waiting + present (intersection) + partial + search, without the
/// Start⇄Stop cluster. For mid-lecture reading of who is where.
class LiveRosterScreen extends ConsumerWidget {
  final String course;
  const LiveRosterScreen({super.key, required this.course});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    HostDriver? driver;
    try {
      driver = ref.watch(hostDriverProvider);
    } catch (_) {
      driver = null;
    }
    final d = driver;
    if (d == null) {
      return _LiveSectionShell(
        title: 'Roster · $course',
        reason: 'Who is waiting, present, or partial — live.',
        child: _noHostNote(course),
      );
    }
    return _LiveSectionShell(
      title: 'Roster · $course',
      reason: 'Who is waiting, present, or partial — live.',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WaitingListSection(waitingRows: d.waitingRows),
          const SizedBox(height: ProxSpacing.sm),
          MarkedRosterSection(tally: d.tally),
        ],
      ),
    );
  }
}

/// Manual approvals where they happen (near top, bulk actions).
class LiveInboxScreen extends ConsumerWidget {
  final String course;
  const LiveInboxScreen({super.key, required this.course});

  Future<void> _decide(
      WidgetRef ref, String email, bool approve) async {
    try {
      await ref.read(hostDriverProvider).decideManual(email, approve);
      BleLog.log(ProxLogTags.state,
          'manual ${approve ? 'approved' : 'rejected'} $email (section)');
    } catch (_) {}
    try {
      final store = ref.read(deviceStoreProvider);
      final cloud = ref.read(cloudSyncProvider);
      final prof = await readSyncProf(ref);
      final tally = ref.read(hostDriverProvider).tally;
      if (tally.size > 0) {
        final now = DateTime.now();
        await syncEngine.noteLocalSave(
          store: store,
          cloud: cloud,
          prof: prof,
          record: tally.toClassRecord(
            courseId: course,
            classLabel: course,
            dateIso: dateIsoOf(now),
            timestampIso: now.toUtc().toIso8601String(),
          ),
        );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    HostDriver? driver;
    try {
      driver = ref.watch(hostDriverProvider);
    } catch (_) {
      driver = null;
    }
    final d = driver;
    if (d == null) {
      return _LiveSectionShell(
        title: 'Inbox · $course',
        reason: 'Approve or reject manual requests — mid-class.',
        child: _noHostNote(course),
      );
    }
    return _LiveSectionShell(
      title: 'Inbox · $course',
      reason: 'Approve or reject manual requests — mid-class.',
      child: ManualInboxSection(
        pending: d.manualPending,
        onApproveOne: (e) => _decide(ref, e, true),
        onRejectOne: (e) => _decide(ref, e, false),
        onDecide: (emails, approve) async {
          for (final e in emails) {
            try {
              await ref.read(hostDriverProvider).decideManual(e, approve);
            } catch (_) {}
          }
        },
      ),
    );
  }
}

/// Direct manual entry without scrolling past the roster.
class LiveAddScreen extends ConsumerWidget {
  final String course;
  const LiveAddScreen({super.key, required this.course});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    HostDriver? driver;
    try {
      driver = ref.watch(hostDriverProvider);
    } catch (_) {
      driver = null;
    }
    final d = driver;
    if (d == null) {
      return _LiveSectionShell(
        title: 'Add · $course',
        reason: 'Add one student by hand — directory search fills the fields.',
        child: _noHostNote(course),
      );
    }
    return _LiveSectionShell(
      title: 'Add · $course',
      reason: 'Add one student by hand — directory search fills the fields.',
      child: DirectAddSection(
        course: course,
        sessionId: '',
        onAdd: ({required String name, required String roll, required String email}) async {
          await d.addManualEntry(email: email, name: name, roll: roll);
        },
        isPresent: (email) => d.tally.confirmed
            .any((r) => r.email == email.toLowerCase()),
      ),
    );
  }
}

/// Hosting setup (name, IP, discovery assumptions) before Start.
class LiveSetupScreen extends ConsumerWidget {
  final String course;
  const LiveSetupScreen({super.key, required this.course});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _LiveSectionShell(
      title: 'Setup · $course',
      reason: 'Hosting setup before Start — back to the host to begin.',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ProxSyncNote(
            'Setup lives on the live host screen (name, announce IP, discovery assumptions). '
            'This section names the step so live/<course>/setup deep-links land somewhere real.',
          ),
          const SizedBox(height: ProxSpacing.sm),
          TextButton.icon(
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back to live host'),
            onPressed: () => Navigator.of(context).pop(),
          ),
          TextButton.icon(
            icon: const Icon(Icons.terminal_outlined),
            label: const Text('System log'),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DebugLogScreen())),
          ),
        ],
      ),
    );
  }
}
