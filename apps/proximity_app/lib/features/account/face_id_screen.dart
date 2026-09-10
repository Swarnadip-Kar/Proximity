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
              Text(
                status,
                key: const Key('face-id-status'),
                style: ProxType.title(color: c.contentPrimary),
              ),
              if (!fresh) ...[
                const SizedBox(height: ProxSpacing.sm),
                const ProxSyncNote(
                  'Face recognition was improved — scan your face again. Your device key is kept.',
                ),
              ],
              const SizedBox(height: ProxSpacing.lg),
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
            ],
          );
        },
      ),
    );
  }
}
