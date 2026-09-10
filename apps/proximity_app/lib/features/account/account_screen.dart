// Account tab — one consolidated page per shell (§5.1 student, §5.3 prof).
//
// Presentation + navigation-structure rebuild, NOT a behavior change. Every
// fact below is read from the same sources the pre-auth screens already
// read (account stream, linked identity, local StoredEnrollment, the claim
// gate verdict, install/host-name store reads); only the widget tree
// changes. Decisions stay in `entry_flow.dart` / the enrollment
// controller — this file calls the same functions (`entrySignOut`,
// `entryStudentGate`, `studentClaimMessage`, `restartFace` is face-id's).
//
// Student page owns: profile header, enrollment status + re-enroll entry,
// read-only ID, device key (short form) + move status, offline/hosting
// note (collapsed), Face-ID row (pushes `account/face-id`), theme control,
// system-log row, sign-out. Professor page owns: header, device/key facts,
// theme, system log, sign-out — NO Face-ID section/route, NO enrollment
// section.
//
// Frozen-copy rule: claim/move/refusal strings come from
// `studentClaimMessage` verbatim; move cadence reads `once a month`
// (code is 30-day `kStudentMoveCooldown` — gap 6).
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../mode.dart';
import '../../routes.dart';
import '../../widgets/account_chip.dart';
import '../../widgets/details_expander.dart';
import '../../widgets/fallback_button.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/trust_cards.dart';
import '../../widgets/web_banner.dart';
import '../entry/entry_flow.dart';
import '../face_identity/face_verifier.dart';
import '../setup/welcome_screen.dart';
import 'face_id_screen.dart';
import 'theme_mode.dart';

/// Label + value row. Values truncate (never wrap a card open); full IDs
/// use [mono] for the short-code-string face (§2.2) with soft-wrap.
class _FactRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;

  const _FactRow(this.label, this.value, {super.key, this.mono = false});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: ProxSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: ProxType.label(color: c.contentSecondary),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: mono
                ? ProxType.monoBody(color: c.contentPrimary)
                : ProxType.body(color: c.contentPrimary),
            softWrap: true,
          ),
        ],
      ),
    );
  }
}

/// Local enrollment read. Never throws (null = none on file).
Future<StoredEnrollment?> _readEnrollment(WidgetRef ref) async {
  try {
    return await ref.read(deviceStoreProvider).readEnrollment();
  } catch (_) {
    return null;
  }
}

/// Move status for the signed-in Gmail, or null when it cannot be
/// determined (offline / unavailable / signed out). Same online-gated,
/// never-stale read the pre-auth device screen uses — never a stale
/// verdict. Never throws.
Future<StudentGate?> _moveGate(WidgetRef ref, String? email) async {
  if (email == null || email.isEmpty || !canUseFace()) return null;
  try {
    final cloud = ref.read(cloudSyncProvider);
    if (!cloud.available || !(await cloud.isOnline())) return null;
    return await entryStudentGate(ref, email);
  } catch (_) {
    return null;
  }
}

/// Pushes the standalone enrollment entry (preserved `enroll/intro` chain:
/// intro → capture → result). Same screens the setup flow composes.
void _openEnrollEntry(BuildContext context) {
  ProxNav.pushNamed(context, ProxRoutes.enrollIntro);
}

/// Fallback-weight sheet body for enroll / re-enroll / move entries: one
/// explanation + one outlined continue into the preserved enroll chain.
Widget _enrollSheetBody(
  BuildContext pageContext,
  WidgetRef ref, {
  required String body,
}) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(body, style: ProxType.body()),
      const SizedBox(height: ProxSpacing.md),
      // Outlined (secondary weight): entries stay fallback rows, never a
      // full-width primary button on the page itself.
      Builder(
        builder: (sheetContext) {
          final c = ProximityColors.of(sheetContext);
          return OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(64, ProxSpacing.minTap),
              foregroundColor: c.accentBrand,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(ProxRadii.button),
              ),
            ),
            onPressed: () {
              Navigator.of(sheetContext).pop();
              _openEnrollEntry(pageContext);
            },
            child: const Text('Continue to enrollment'),
          );
        },
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Student page (§5.1).
// ---------------------------------------------------------------------------

/// Student Account tab root. Signed out renders the same Welcome the hub
/// route renders (the tab's signed-out behavior is unchanged).
class StudentAccountScreen extends ConsumerWidget {
  const StudentAccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acct = ref.watch(accountProvider).valueOrNull;
    if (acct == null) return const WelcomeScreen();
    // Header: AccountChip large (56dp avatar). photoUrl is null — a photo
    // field was verified ABSENT from SignedAccount, so no auth plumbing is
    // invented here; the chip's own errorBuilder→initials fallback renders
    // the deterministic initials avatar (flag stands, same as NAV-G3).
    // Sits on the subtle gradient.brand wash via largeHeader (§2.5 — the
    // ONLY gradient on this page).
    final header = AccountChip(
      displayName: acct.displayName,
      email: acct.email,
      photoUrl: null,
      largeHeader: true,
    );
    return ProxScreen(
      title: 'Account',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const WebRecordsBanner(),
          header,
          if (!canUseFace()) ...[
            const SizedBox(height: ProxSpacing.sm),
            const Text(
              'Records view only here — enrollment, keys, and device moves live in the mobile app (Android/iOS).',
              textAlign: TextAlign.center,
            ),
          ] else ...[
            const ProxSectionHeader(title: 'Enrollment'),
            _EnrollmentSection(acct: acct),
            const ProxSectionHeader(title: 'ID'),
            _IdRow(acct: acct),
            const ProxSectionHeader(title: 'Face ID'),
            _FaceIdRow(acct: acct),
            const ProxSectionHeader(title: 'Device'),
            _DeviceSection(acct: acct),
          ],
          const ProxSectionHeader(title: 'Theme'),
          const _ThemeRow(),
          const SizedBox(height: ProxSpacing.sm),
          ProxListTile(
            key: const Key('account-system-log-row'),
            title: 'System log',
            subtitle: 'Filterable terminal',
            leading: const Icon(Icons.terminal_outlined),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => ProxNav.openDebugLog(context),
          ),
          const SizedBox(height: ProxSpacing.xl),
          const Divider(),
          Center(
            child: TextButton.icon(
              key: const Key('account-sign-out'),
              icon: const Icon(Icons.switch_account),
              label: const Text('Switch account (sign out)'),
              onPressed: () {
                unawaited(entrySignOut(ref));
              },
            ),
          ),
          const SizedBox(height: ProxSpacing.lg),
        ],
      ),
    );
  }
}

/// Enrollment section: date enrolled, organization, trust-tier badge +
/// plain-language explainer (collapsed), re-enroll entry when relevant.
class _EnrollmentSection extends ConsumerWidget {
  final SignedAccount acct;
  const _EnrollmentSection({required this.acct});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<StoredEnrollment?>(
      future: _readEnrollment(ref),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final e = snap.data;
        if (e == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ProxSyncNote(
                'No student key on this device yet — enrollment creates one (device key + face, online once).',
              ),
              const SizedBox(height: ProxSpacing.sm),
              FallbackButton(
                label: 'Enroll this device',
                sheetTitle: 'Enroll this device',
                icon: Icons.school_outlined,
                buttonKey: const Key('account-enroll-entry'),
                sheetBuilder: (sheetContext) => _enrollSheetBody(
                  context,
                  ref,
                  body:
                      'One-time setup — about 2 minutes, online once. Your Gmail claims its single student-device slot; then attendance works fully offline.',
                ),
              ),
            ],
          );
        }
        final org = e.org.isNotEmpty
            ? e.org
            : (acct.org.isNotEmpty ? acct.org : 'Not set');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ProxStateBadge(
                state: ProxState.marked, label: 'Enrolled as ${e.email}'),
            _FactRow('Date enrolled', dateIsoOf(e.enrolledAt.toUtc())),
            _FactRow('Organization', org),
            const SizedBox(height: ProxSpacing.sm),
            DeviceTrustBadge(
              level: e.attestationLevel,
              attestedUntilMillis:
                  e.attestedUntil.toUtc().millisecondsSinceEpoch,
              pkDHex: e.pkDHex,
            ),
            DetailsExpander(
              title: 'What this means',
              child: Text(
                'FULL and STD mean this phone holds a hardware-backed device key — attendance is confirmed automatically. '
                'STALE means the attestation is older than the 14-day grace period — attendance still confirms, re-attest soon. '
                'NONE means a software key with no hardware tier claimed — attendance still marks through the flagged device-none-fallback, with every other check still run.',
                style: ProxType.body(),
              ),
            ),
            FallbackButton(
              label: 'Re-enroll this device',
              sheetTitle: 'Re-enroll this device',
              icon: Icons.refresh_outlined,
              buttonKey: const Key('account-reenroll-entry'),
              sheetBuilder: (sheetContext) => _enrollSheetBody(
                context,
                ref,
                body:
                    'Same-install re-keys and re-enrolls are always free. Your current enrollment keeps working until the new one saves.',
              ),
            ),
          ],
        );
      },
    );
  }
}

/// ID row — GAP 2 verdict: READ-ONLY. No server-side write path exists for
/// the roll post-enrollment (`FirestoreCloudSync.writeStudentDevice`
/// throws; the roll is stamped only by the atomic `claimStudentDevice`
/// transaction at enrollment; the directory row is written by that same
/// claim, never by hand). Exposing edit would be new business logic, out
/// of scope — so this renders the value with no TextField, and the gap is
/// reported in INTEGRATION_LOG.md.
class _IdRow extends ConsumerWidget {
  final SignedAccount acct;
  const _IdRow({required this.acct});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linked = ref.watch(linkedIdentityProvider);
    return FutureBuilder<StoredEnrollment?>(
      future: _readEnrollment(ref),
      builder: (context, snap) {
        final stored = snap.data;
        final roll = (linked != null && linked.roll.isNotEmpty)
            ? linked.roll
            : (stored != null ? stored.roll : '');
        return _FactRow(
          'ID number',
          roll.isNotEmpty ? roll : 'Not set',
          mono: roll.isNotEmpty,
          key: const Key('account-id-row'),
        );
      },
    );
  }
}

/// Face-ID row: status pushes the isolated `account/face-id` page.
class _FaceIdRow extends ConsumerWidget {
  final SignedAccount acct;
  const _FaceIdRow({required this.acct});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentVer = ref.watch(faceVerifierProvider).verifierVer;
    return FutureBuilder<StoredEnrollment?>(
      future: _readEnrollment(ref),
      builder: (context, snap) {
        final e = snap.data;
        final fresh =
            e != null && e.faceId.isNotEmpty && !e.isFaceStale(currentVer);
        return ProxListTile(
          key: const Key('account-face-id-row'),
          title: 'Face ID',
          subtitle: fresh ? 'Enrolled' : 'Needs re-face',
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

/// Device section: local key facts + move status + collapsed
/// offline/hosting note. Refusal copy comes from `studentClaimMessage`
/// verbatim — the same words the enroll claim refuses with.
class _DeviceSection extends ConsumerWidget {
  final SignedAccount acct;
  const _DeviceSection({required this.acct});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<StoredEnrollment?>(
      future: _readEnrollment(ref),
      builder: (context, enrollSnap) {
        final e = enrollSnap.data;
        return FutureBuilder<StudentGate?>(
          future: _moveGate(ref, acct.email),
          builder: (context, gateSnap) {
            final loading =
                enrollSnap.connectionState == ConnectionState.waiting ||
                    gateSnap.connectionState == ConnectionState.waiting;
            if (loading) {
              return const Center(child: CircularProgressIndicator());
            }
            final gate = gateSnap.data;
            final binding = gate?.binding;
            // Device model: no device-info plumbing exists anywhere (same
            // class as the photo gap — not invented). The existing signal
            // is the claim-stamped platform label, else the local one.
            final platform =
                (binding != null && binding.platform.trim().isNotEmpty)
                    ? binding.platform
                    : defaultTargetPlatform.name;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FactRow('Device model', platform),
                if (e == null)
                  const ProxSyncNote(
                    'No student key on this device yet — enrollment creates one (device key + face, online once).',
                  )
                else ...[
                  const SizedBox(height: ProxSpacing.sm),
                  ProxStateBadge(
                      state: ProxState.marked, label: 'Enrolled as ${e.email}'),
                  ProxSyncNote(
                    '${e.name} · ${e.roll} · key ${_shortKey(e.pkHex)}',
                  ),
                ],
                const SizedBox(height: ProxSpacing.sm),
                _moveStatus(context, ref, gate),
                DetailsExpander(
                  title: 'Offline & hosting',
                  child: Text(
                    'Offline professors keep everything on this device. Sign in later to back up, sync across devices, and share CSVs from the cloud.',
                    style: ProxType.body(),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Move-status body for a known gate verdict. Trust tier rides below
  /// every verdict when a binding exists (never silent).
  Widget _moveStatus(BuildContext context, WidgetRef ref, StudentGate? gate) {
    if (gate == null) {
      return const ProxSyncNote(
        'Connect to check move status — one enrolled device per Gmail is checked online.',
      );
    }
    final b = gate.binding;
    final trust = b == null
        ? null
        : DeviceTrustBadge(
            level: b.attestationLevel,
            attestedUntilMillis: b.attestedUntilMillis,
            pkDHex: b.pkDHex,
          );
    switch (gate.verdict.claim) {
      case StudentClaim.firstBind:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ProxStateBadge(
                state: ProxState.neutral, label: 'Not enrolled yet'),
            const ProxSyncNote(
                'This install is free to enroll — first bind takes it.'),
            if (trust != null) ...[
              const SizedBox(height: ProxSpacing.sm),
              trust,
            ],
          ],
        );
      case StudentClaim.sameDevice:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ProxStateBadge(state: ProxState.marked, label: 'Active'),
            const ProxSyncNote('Re-keys and re-enrolls here are always free.'),
            if (trust != null) ...[
              const SizedBox(height: ProxSpacing.sm),
              trust,
            ],
          ],
        );
      case StudentClaim.allowedMove:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ProxStateBadge(
                state: ProxState.waiting, label: 'Eligible to move here'),
            const ProxSyncNote(
                'The 30 days since the last move have passed — enrolling here moves it (at most once a month).'),
            FallbackButton(
              label: 'Move to this device',
              sheetTitle: 'Move to this device',
              icon: Icons.smartphone_outlined,
              buttonKey: const Key('account-move-entry'),
              sheetBuilder: (sheetContext) => _enrollSheetBody(
                context,
                ref,
                body:
                    'Enrolling here moves this Gmail\u2019s single student-device slot to this phone (moves are unlimited, at most one per 30 days). Until it saves, nothing changes.',
              ),
            ),
            if (trust != null) ...[
              const SizedBox(height: ProxSpacing.sm),
              trust,
            ],
          ],
        );
      case StudentClaim.cooldownBlocked:
      case StudentClaim.installConflict:
        final retry = gate.verdict.retryAfter;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (gate.verdict.claim == StudentClaim.cooldownBlocked &&
                retry != null)
              ProxStateBadge(
                state: ProxState.waiting,
                label: 'Move cooldown until ${dateIsoOf(retry.toUtc())}',
              ),
            ProxErrorNote(studentClaimMessage(gate.verdict, gate.binding)),
            if (trust != null) ...[
              const SizedBox(height: ProxSpacing.sm),
              trust,
            ],
          ],
        );
    }
  }
}

String _shortKey(String pkHex) {
  final h = pkHex.trim();
  if (h.isEmpty) return 'no key';
  return h.length <= 12 ? h : '${h.substring(0, 12)}…';
}

/// Theme row: Dark/Light/System 3-way segmented control, inline (the one
/// row that's a control, not a push). No checkboxes anywhere.
class _ThemeRow extends ConsumerWidget {
  const _ThemeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final c = ProximityColors.of(context);
    // §10 narrow breakpoint: three icon+label segments overflow below
    // 360dp at large system type, so narrow renders label-only segments
    // (words carry the choice; icons return at ≥360dp).
    final narrow = ProxLayout.isNarrow(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Theme',
          style: ProxType.label(color: c.contentSecondary),
        ),
        const SizedBox(height: ProxSpacing.sm),
        SegmentedButton<ThemeMode>(
          key: const Key('account-theme-control'),
          style: SegmentedButton.styleFrom(
            minimumSize: const Size(64, ProxSpacing.minTap),
          ),
          segments: [
            ButtonSegment(
              value: ThemeMode.system,
              label: const Text('System'),
              icon: narrow ? null : const Icon(Icons.settings_suggest_outlined),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              label: const Text('Light'),
              icon: narrow ? null : const Icon(Icons.light_mode_outlined),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              label: const Text('Dark'),
              icon: narrow ? null : const Icon(Icons.dark_mode_outlined),
            ),
          ],
          selected: {mode},
          onSelectionChanged: (s) {
            unawaited(ref.read(themeModeProvider.notifier).set(s.first));
          },
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Professor page (§5.3): same consolidated pattern, scoped to professor
// facts — header, device/key facts, theme, system log, sign out. NO Face-ID
// section/route, NO enrollment-status section.
// ---------------------------------------------------------------------------

/// Professor Account tab root. Signed out renders Welcome, same as the
/// student page and the hub route before it.
class ProfAccountScreen extends ConsumerWidget {
  const ProfAccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acct = ref.watch(accountProvider).valueOrNull;
    if (acct == null) return const WelcomeScreen();
    final header = AccountChip(
      displayName: acct.displayName,
      email: acct.email,
      photoUrl: null,
      largeHeader: true,
    );
    return ProxScreen(
      title: 'Account',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const WebRecordsBanner(),
          header,
          const ProxSectionHeader(title: 'This device'),
          _ProfDeviceFacts(acct: acct),
          const ProxSectionHeader(title: 'Theme'),
          const _ThemeRow(),
          const SizedBox(height: ProxSpacing.sm),
          ProxListTile(
            key: const Key('account-system-log-row'),
            title: 'System log',
            subtitle: 'Filterable terminal',
            leading: const Icon(Icons.terminal_outlined),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => ProxNav.openDebugLog(context),
          ),
          const SizedBox(height: ProxSpacing.xl),
          const Divider(),
          Center(
            child: TextButton.icon(
              key: const Key('account-sign-out'),
              icon: const Icon(Icons.switch_account),
              label: const Text('Switch account (sign out)'),
              onPressed: () {
                unawaited(entrySignOut(ref));
              },
            ),
          ),
          const SizedBox(height: ProxSpacing.lg),
        ],
      ),
    );
  }
}

/// Professor device/key facts: install ID (read-only, never created by
/// viewing) + registered display name. Professors hold no SKey/DKey
/// enrollment, so there is no key/trust tier to show — and none is
/// invented.
class _ProfDeviceFacts extends ConsumerWidget {
  final SignedAccount acct;
  const _ProfDeviceFacts({required this.acct});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<String?>>(
      future: _profFacts(ref),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final installId = (snap.data ?? const [null, null])[0] ?? '';
        final hostName = (snap.data ?? const [null, null])[1] ?? '';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _FactRow('Device model', defaultTargetPlatform.name),
            _FactRow(
              'Install ID',
              installId.trim().isEmpty
                  ? 'Not assigned yet'
                  : _shortKey(installId),
              mono: installId.trim().isNotEmpty,
            ),
            _FactRow(
              'Display name',
              hostName.trim().isNotEmpty ? hostName.trim() : acct.displayName,
            ),
          ],
        );
      },
    );
  }

  /// Read-only facts. `readInstallId` never creates one (unlike the
  /// claim-time `getOrCreateInstallId`): viewing Account must not write.
  Future<List<String?>> _profFacts(WidgetRef ref) async {
    String? installId;
    String hostName = '';
    try {
      installId = await ref.read(deviceStoreProvider).readInstallId();
    } catch (_) {
      installId = null;
    }
    try {
      hostName = await ref.read(deviceStoreProvider).readHostName();
    } catch (_) {
      hostName = '';
    }
    return [installId, hostName];
  }
}
