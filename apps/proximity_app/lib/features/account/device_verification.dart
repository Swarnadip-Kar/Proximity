// Account → Device verification card (student + professor, one widget).
//
// Student: THIS phone's integrity standing — Verified (green) or
// Unverified (yellow) — same `IntegrityGate` verdict enrollment and
// marking use (rooted / hooked / tampered / emulator; debug alone never
// blocks).
//
// Professor: hosting trust standing — Verified means students can verify
// YOUR class key before sending any proof (pinned lecture key, ephemeral
// per hosting, signed windows, org-stamped writes). The underlying probe
// is the same `IntegrityGate` snapshot (advisory for hosting — a tainted
// prof phone still hosts offline), but the copy states prof guarantees,
// never root/hook language as the headline (prof has nothing to do with
// root — students verify the class key, not the prof phone's OS).
//
// Same small `VerdictBadge` and `DetailsExpander` language as every other
// status surface. Cache-first by design (see
// `IntegrityGate.lastVerdictFresh`): the card reads the startup snapshot —
// no native probe per page open. A stale or missing snapshot renders "not
// checked yet" with an explicit Check-now action that probes once on
// demand. The check runs on this phone only, nothing leaves the device.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security/integrity.dart';
import '../../design/tokens.dart';
import '../../widgets/details_expander.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/verdict_badge.dart';

/// Shared device-verification card for the student + professor Device
/// pages (and the offline professor page — same widget, no identity).
/// [forProfessor] switches the copy to hosting guarantees (lecture-key
/// pin, ephemeral keys, signed windows, org writes) instead of the
/// student root/hook/tamper headline. The badge still reflects the same
/// `IntegrityGate` snapshot (advisory for hosting — never blocks).
class DeviceVerificationCard extends ConsumerStatefulWidget {
  final bool forProfessor;
  const DeviceVerificationCard({super.key, this.forProfessor = false});

  @override
  ConsumerState<DeviceVerificationCard> createState() =>
      _DeviceVerificationCardState();
}

class _DeviceVerificationCardState
    extends ConsumerState<DeviceVerificationCard> {
  /// On-demand probe (Check-now only — null until tapped).
  Future<IntegrityVerdict>? _check;

  static String _taintLine(IntegrityVerdict v, {bool forProfessor = false}) {
    if (forProfessor) {
      // Prof headline never leads with root — hosting is advisory and
      // students verify the class key, not the prof OS. Name the taint
      // once, then state the hosting consequence.
      final what = v.rooted
          ? 'rooted or jailbroken'
          : v.hooked
              ? 'a hooking framework (Frida/Xposed) present'
              : v.tampered
                  ? 'tampered or re-signed'
                  : 'an emulator';
      return 'This device shows signs of being $what — you can still host '
          'offline, but publish the lecture key online so students see '
          'Verified instead of first-seen.';
    }
    if (v.rooted) {
      return 'This device looks rooted or jailbroken — a privileged OS '
          'can hide what apps do.';
    }
    if (v.hooked) {
      return 'A hooking framework (Frida/Xposed) is present — code can be '
          'injected into this app.';
    }
    if (v.tampered) {
      return 'This install looks tampered or re-signed — it may not be '
          'the released app.';
    }
    return 'This looks like an emulator — not a physical phone in the room.';
  }

  @override
  Widget build(BuildContext context) {
    final check = _check;
    if (check != null) {
      return FutureBuilder<IntegrityVerdict>(
        future: check,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final v = snap.data;
          if (v == null) return const SizedBox.shrink();
          return _card(context, v, checkedNote: 'Checked just now.');
        },
      );
    }
    final cached =
        IntegrityGate.lastVerdictFresh() ? IntegrityGate.lastVerdict : null;
    if (cached != null) {
      return _card(context, cached,
          checkedNote: 'Checked when the app started.');
    }
    return _notChecked(context);
  }

  /// No fresh snapshot on this launch: honest empty state + explicit
  /// opt-in probe (never an automatic native read from a facts page).
  Widget _notChecked(BuildContext context) {
    final c = ProximityColors.of(context);
    return ProxCard(
      key: const Key('device-verification-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.forProfessor
                ? 'Hosting verification'
                : 'Device verification',
            style: ProxType.title(color: c.contentPrimary),
          ),
          const SizedBox(height: ProxSpacing.xs),
          Text(
            'Not checked yet on this launch.',
            style: ProxType.caption(color: c.contentSecondary),
          ),
          const SizedBox(height: ProxSpacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(64, ProxSpacing.minTap),
              ),
              onPressed: () => setState(() {
                _check = IntegrityGate.performCheck();
              }),
              child: const Text('Check now'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, IntegrityVerdict v,
      {required String checkedNote}) {
    final c = ProximityColors.of(context);
    final clean = !v.blocksEnroll;
    final forProf = widget.forProfessor;
    return ProxCard(
      key: const Key('device-verification-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                forProf ? 'Hosting verification' : 'Device verification',
                style: ProxType.title(color: c.contentPrimary),
              ),
              const Spacer(),
              VerdictBadge(
                status: clean ? ProxStatus.marked : ProxStatus.review,
                label: clean ? 'Verified' : 'Unverified',
              ),
            ],
          ),
          const SizedBox(height: ProxSpacing.xs),
          Text(
            forProf
                ? (clean
                    ? 'This device can host trusted classes — students verify '
                        'your class key before sending any proof.${v.debug ? ' Debug build — expected on developer builds, never blocks hosting.' : ''}'
                    : '${_taintLine(v, forProfessor: true)} Hosting still '
                        'works offline.')
                : (clean
                    ? 'This device passes the integrity check — the same '
                        'check enrollment and marking use.${v.debug ? ' Debug build — expected on developer builds, never blocks.' : ''}'
                    : '${_taintLine(v)} Enrollment refuses on this device '
                        'and its marks get flagged for review.'),
            style: ProxType.caption(color: c.contentSecondary),
          ),
          Text(
            checkedNote,
            style: ProxType.caption(color: c.contentTertiary),
          ),
          DetailsExpander(
            title: 'What this means',
            child: Padding(
              padding: const EdgeInsets.only(bottom: ProxSpacing.xs),
              child: Text(
                forProf
                    ? 'Verified means students can verify YOUR class: your lecture key is pinned under your email (owner-only write), lecture keys are ephemeral per hosting (a stolen phone cannot host trusted classes long-term), every window is signed and checked before any proof is sent (mismatch refuses, first-seen shows Unverified until online), and sessions are org-stamped with owner-only writes.\n'
                        'Unverified never blocks hosting: you can still host offline — students see first-seen until you publish online, then it turns Verified.\n'
                        'The check runs on this phone only — nothing leaves the device.'
                    : 'Verified means this phone shows no sign of rooting, '
                        'hooking frameworks, tampering, or emulation — the same '
                        'signals payment apps check.\n'
                        'Unverified does not erase attendance by itself: you can '
                        'still join and mark, but the professor sees the flag and '
                        'may ask you to verify in person.\n'
                        'A developer (debug) build always shows Verified here. '
                        'The check runs on this phone only — nothing leaves the '
                        'device.',
                style: ProxType.caption(color: c.contentSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
