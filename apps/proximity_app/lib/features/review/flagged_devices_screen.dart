// Flagged devices review (Track 5 required surface).
//
// Reason to exist: the server re-verifier (§3.4) admin-writes
// {attestationAnomaly, serverVerifiedAtMillis, serverVerifyReason} on
// studentDevices — but no screen showed them. Professors/admins review
// flagged devices here (within their own org) and respond via contact /
// manual attendance meanwhile.
//
// Design law (from §3.4 handoff, not relitigated):
// - query is studentDevices where attestationAnomaly == true (single-field
//   equality, no composite index) within the viewer's org;
// - rows show email / platform / claimed-vs-derived level /
//   serverVerifyReason / serverVerifiedAt / DKey fingerprint;
// - NO manual clear exists by design: a successful re-verify clears the
//   flag, re-enrollment resets the verdict for the new binding;
// - attendance already recorded under valid offline trust is NEVER
//   retroactively invalidated (stated on-screen, not just in the doc).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../design/tokens.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/trust_cards.dart';
import '../debug/debug_log_screen.dart';

/// Professor/admin review list for attestationAnomaly-flagged devices.
class FlaggedDevicesScreen extends ConsumerStatefulWidget {
  const FlaggedDevicesScreen({super.key});

  @override
  ConsumerState<FlaggedDevicesScreen> createState() =>
      _FlaggedDevicesScreenState();
}

class _FlaggedDevicesScreenState
    extends ConsumerState<FlaggedDevicesScreen> {
  bool _loading = true;
  bool _online = true;
  String _error = '';
  List<StudentDeviceDoc> _rows = [];
  String _org = '';

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final acct = ref.read(authServiceProvider).current ??
          await ref.read(accountProvider.future);
      final org = (acct?.org ?? '').trim().toLowerCase();
      final cloud = ref.read(cloudSyncProvider);
      var online = false;
      try {
        online = await cloud.isOnline().timeout(const Duration(seconds: 8));
      } catch (_) {
        online = false;
      }
      if (!online) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _online = false;
          _org = org;
          _error = 'You appear offline — flagged review needs internet.';
        });
        return;
      }
      final rows =
          await cloud.fetchFlaggedDevices(org: org, limit: 50);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _online = true;
        _org = org;
        _rows = rows;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e'.replaceFirst('StateError: ', '');
      });
    }
  }

  void _openLog() {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DebugLogScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return ProxScreen(
      title: 'Flagged devices',
      actions: [
        IconButton(
          icon: const Icon(Icons.terminal_outlined),
          tooltip: 'System log',
          onPressed: _openLog,
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
          onPressed: _loading ? null : _load,
        ),
      ],
      child: FlaggedDevicesBody(
        loading: _loading,
        error: _error,
        org: _org,
        online: _online,
        rows: _rows,
        onRefresh: _load,
      ),
    );
  }
}

/// Body split for testability (pure widget over plain args).
class FlaggedDevicesBody extends StatelessWidget {
  final bool loading;
  final String error;
  final String org;
  final bool online;
  final List<StudentDeviceDoc> rows;
  final Future<void> Function() onRefresh;
  const FlaggedDevicesBody({
    super.key,
    required this.loading,
    required this.error,
    required this.org,
    required this.online,
    required this.rows,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        shrinkWrap: true,
        children: [
          Text(
            'Devices flagged by server re-verification${org.isNotEmpty ? ' · $org' : ''}',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: ProxSpacing.xs),
          const Text(
            'Past attendance stands — a flag never retroactively invalidates it. '
            'Contact the student / mark manually meanwhile. A successful '
            're-verify clears the flag; re-enrollment resets it for the new binding. '
            'No manual clear exists by design.',
          ),
          const SizedBox(height: ProxSpacing.sm),
          SyncStatusStrip(
            pending: 0,
            online: online,
            note: online
                ? 'Online — showing flagged devices${org.isNotEmpty ? ' in $org' : ''}.'
                : 'Offline — flagged review needs internet.',
          ),
          const SizedBox(height: ProxSpacing.sm),
          if (loading)
            const Center(child: CircularProgressIndicator())
          else if (error.isNotEmpty)
            ProxErrorNote(error)
          else if (rows.isEmpty)
            const ProxEmptyState(
              message:
                  'No flagged devices. Re-verification runs on sync when an attestation window nears expiry.',
            )
          else
            for (var i = 0; i < rows.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: ProxSpacing.sm),
                child: _FlaggedRow(doc: rows[i]),
              ),
        ],
      ),
    );
  }
}

class _FlaggedRow extends StatelessWidget {
  final StudentDeviceDoc doc;
  const _FlaggedRow({required this.doc});

  @override
  Widget build(BuildContext context) {
    final verified = trustDateLabel(doc.serverVerifiedAtMillis);
    return ProxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            doc.email,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (doc.name.isNotEmpty)
            Text(
              '${doc.name}${doc.roll.isNotEmpty ? ' · ${doc.roll}' : ''}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          const SizedBox(height: ProxSpacing.xs),
          Wrap(
            spacing: ProxSpacing.sm,
            runSpacing: ProxSpacing.xs,
            children: [
              ProxStateBadge(
                state: ProxState.error,
                label:
                    'Claimed ${doc.attestationLevel.isEmpty ? 'NONE' : doc.attestationLevel}',
              ),
              if (doc.platform.isNotEmpty)
                Chip(
                  label: Text(doc.platform),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: ProxSpacing.xs),
          Text(
            [
              'DKey ${trustPkDFingerprint(doc.pkDHex)}',
              if (doc.serverVerifyReason.isNotEmpty)
                'Reason: ${doc.serverVerifyReason}',
              if (verified.isNotEmpty) 'Checked $verified',
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
