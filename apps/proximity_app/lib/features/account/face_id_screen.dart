// `account/face-id` — the one Account sub-route that stays separate (§5.2).
//
// Reason it is isolated: this page carries the hard "never render a
// preview" rule (principle 6), so it is built WITHOUT the shared section
// layouts (`AccountChip`, `StudentCard`, any avatar) — plain text rows
// only, so no stray image widget can leak in. No thumbnail, no embedding,
// no preview ever rendered; no gallery reads anywhere (only the
// `verifierVer` tag string + the local stale check).
//
// Content: status line only (`Enrolled · <verifierVer>` / `Needs re-face`
// on version mismatch) + a low-emphasis `Re-scan face` fallback. Re-scan
// calls the SAME controller function the enroll-result screen calls
// (`restartFace` — key kept) and continues into the preserved standalone
// capture chain (`EnrollFlow.openCapture` → result). Fail-closed throughout:
// without a device key the capture screen itself refuses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/device_store.dart';
import '../../core/enrollment.dart';
import '../../core/platformx.dart';
import '../../core/sync/claim.dart';
import '../../design/tokens.dart';
import '../../widgets/fallback_button.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';

import '../../features/face_identity/face_blocked.dart';
import '../../features/face_identity/face_verifier.dart';
import '../setup/enroll_flow.dart';

/// Face-ID status page. Pushed from the student Account page with
/// `RouteSettings(name: 'account/face-id')`.
class FaceIdScreen extends ConsumerWidget {
  const FaceIdScreen({super.key});

  Future<StoredEnrollment?> _enrollment(WidgetRef ref) async {
    try {
      return await ref.read(deviceStoreProvider).readEnrollment();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Records-only devices never see face UI (same gate the enroll
    // screens use): blocked card, never a dead camera page.
    if (!canUseFace()) {
      return const ProxScreen(
        title: 'Face ID',
        child: FaceBlockedCard(flow: 'Face ID'),
      );
    }
    final currentVer = ref.watch(faceVerifierProvider).verifierVer;
    return ProxScreen(
      title: 'Face ID',
      child: FutureBuilder<StoredEnrollment?>(
        future: _enrollment(ref),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final e = snap.data;
          final fresh =
              e != null && e.faceId.isNotEmpty && !e.isFaceStale(currentVer);
          final status =
              fresh ? 'Enrolled · ${e.verifierVer}' : 'Needs re-face';
          final c = ProximityColors.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: ProxSpacing.sm),
              Text(
                status,
                key: const Key('face-id-status'),
                style: ProxType.title(color: c.contentPrimary),
              ),
              if (!fresh) ...[
                const SizedBox(height: ProxSpacing.md),
                const ProxSyncNote(
                  'Face recognition was improved — scan your face again. Your device key is kept.',
                ),
              ],
              const SizedBox(height: ProxSpacing.xl),
              _FaceRescanRules(),
              const SizedBox(height: ProxSpacing.xl),
              FallbackButton(
                label: 'Re-scan face',
                sheetTitle: 'Re-scan face',
                icon: Icons.face,
                buttonKey: const Key('face-id-rescan'),
                sheetBuilder: (sheetContext) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Your device key is kept — capture the 5 stills again. Attendance on the saved enrollment keeps working until the new capture validates.',
                      style: ProxType.body(color: c.contentPrimary),
                    ),
                    const SizedBox(height: ProxSpacing.md),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize:
                            const Size(64, ProxSpacing.minTap),
                        foregroundColor: c.accentBrand,
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(ProxRadii.button),
                        ),
                      ),
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        // Same function the enroll-result Re-scan calls:
                        // key kept, saved enrollment untouched until the
                        // new capture validates.
                        ref
                            .read(enrollmentControllerProvider.notifier)
                            .restartFace();
                        EnrollFlow.openCapture(context);
                      },
                      child: const Text('Continue to face scan'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: ProxSpacing.xl),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Inline rescan note (student face-id section only — no shared file).
//
// Presentation only: the 30-day face re-scan rule with REAL data — the
// rule line (days from [kFaceRescanCooldown], never a literal), the last
// + next-eligible dates when a rescan stamp exists (via [dateIsoOf]),
// and the refusal string verbatim when blocked (via
// [faceRescanCooldownMessage] — never paraphrased). Blocked state comes
// from the documented read-only accessor
// (`EnrollmentController.faceRescanBlockedUntil` — null/zero-stamp = no
// restriction shown beyond the rule line); no session internals in user
// view (no angles, retries, burns). The crucial rule line stays
// highlighted in a "Most important" callout via existing tokens
// (surfaceRaised fill + accentBrand border + cardSpecRadius, no
// square/flat regression).
// Text-only rows — never any thumbnail/preview (principle 6: no Image,
// no avatar, no gallery read here).
// ---------------------------------------------------------------------------

/// Plain-language re-scan note with the live 30-day rule, inline in the
/// Face ID page.
///
/// Read-only: the stamp is read from the device store and the blocked
/// verdict from [EnrollmentController.faceRescanBlockedUntil] — this
/// never stamps, never blocks. While the reads settle (or fail) only
/// the unconditional rows render, so a blocked student is never shown a
/// bare "allowed" state as fact — dates + refusal appear with the data.
class _FaceRescanRules extends ConsumerWidget {
  const _FaceRescanRules();

  Future<_FaceRescanInfo> _info(WidgetRef ref) async {
    int stamp = 0;
    try {
      final stored = await ref.read(deviceStoreProvider).readEnrollment();
      stamp = stored?.lastFaceRescanAtMillis ?? 0;
    } catch (_) {}
    DateTime? blockedUntil;
    try {
      blockedUntil = await ref
          .read(enrollmentControllerProvider.notifier)
          .faceRescanBlockedUntil();
    } catch (_) {
      blockedUntil = null;
    }
    return _FaceRescanInfo(stampMillis: stamp, blockedUntil: blockedUntil);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ProximityColors.of(context);
    final ruleDays = kFaceRescanCooldown.inDays;
    return FutureBuilder<_FaceRescanInfo>(
      future: _info(ref),
      builder: (context, snap) {
        final stamp = snap.data?.stampMillis ?? 0;
        final blockedUntil = snap.data?.blockedUntil;
        final lastIso = stamp > 0
            ? dateIsoOf(
                DateTime.fromMillisecondsSinceEpoch(stamp, isUtc: true))
            : null;
        final nextIso =
            blockedUntil != null ? dateIsoOf(blockedUntil.toUtc()) : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'About re-scanning',
              key: const Key('face-rules-title'),
              style: ProxType.title(color: c.contentPrimary),
            ),
            const SizedBox(height: ProxSpacing.md),
            Container(
              key: const Key('face-rules-important'),
              decoration: BoxDecoration(
                color: c.surfaceRaised,
                borderRadius: ProxRadii.cardSpecRadius,
                border: Border.all(color: c.accentBrand),
              ),
              padding: const EdgeInsets.all(ProxSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star_outline,
                          size: 16, color: c.accentBrand),
                      const SizedBox(width: ProxSpacing.xs),
                      Text(
                        'Most important',
                        style: ProxType.label(color: c.accentBrand),
                      ),
                    ],
                  ),
                  const SizedBox(height: ProxSpacing.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.check, size: 16, color: c.accentBrand),
                      const SizedBox(width: ProxSpacing.sm),
                      Expanded(
                        child: Text(
                          'Face re-scans are allowed once every $ruleDays days.',
                          key: const Key('face-rules-rule'),
                          style: ProxType.body(color: c.contentPrimary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: ProxSpacing.md),
            Text(
              'A re-scan replaces the face template on this phone — your device key, ID, and enrollment stay untouched.',
              key: const Key('face-rules-what'),
              style: ProxType.body(color: c.contentPrimary),
            ),
            Padding(
              padding: const EdgeInsets.only(top: ProxSpacing.sm),
              child: Text(
                'Tip: use good light on your face and hold still while scanning.',
                key: const Key('face-rules-tips'),
                style: ProxType.body(color: c.contentPrimary),
              ),
            ),
            if (lastIso != null)
              Padding(
                padding: const EdgeInsets.only(top: ProxSpacing.sm),
                child: Text(
                  'Last face scan: $lastIso.',
                  key: const Key('face-rules-last'),
                  style: ProxType.body(color: c.contentPrimary),
                ),
              ),
            if (nextIso != null)
              Padding(
                padding: const EdgeInsets.only(top: ProxSpacing.sm),
                child: Text(
                  'You can scan again on $nextIso.',
                  key: const Key('face-rules-next'),
                  style: ProxType.body(color: c.contentPrimary),
                ),
              ),
            if (blockedUntil != null)
              Padding(
                padding: const EdgeInsets.only(top: ProxSpacing.sm),
                child: Text(
                  faceRescanCooldownMessage(blockedUntil),
                  key: const Key('face-rules-refusal'),
                  style: ProxType.body(color: c.contentPrimary),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Stored rescan stamp + read-only blocked verdict for [_FaceRescanRules].
class _FaceRescanInfo {
  final int stampMillis;
  final DateTime? blockedUntil;
  const _FaceRescanInfo({required this.stampMillis, this.blockedUntil});
}
