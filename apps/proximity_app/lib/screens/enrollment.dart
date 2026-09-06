// One-time online enrollment: Google session (picked up silently) →
// device key → on-device face → upload key+faceHash. Nothing to type —
// identity imports from Gmail.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/enrollment.dart';
import '../core/face_detect.dart';
import '../main.dart';
import '../mode.dart';
import 'face_capture.dart';

class EnrollmentScreen extends ConsumerStatefulWidget {
  const EnrollmentScreen({super.key});

  @override
  ConsumerState<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

class _EnrollmentScreenState extends ConsumerState<EnrollmentScreen> {
  @override
  void initState() {
    super.initState();
    // Silent account pickup: students signed in on the landing before
    // reaching here — no second Google tap. Post-frame: pickup notifies
    // listeners (setState during build is illegal). Fresh installs with
    // no session keep the manual sign-in button below.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref
          .read(enrollmentControllerProvider.notifier)
          .pickUpAccount());
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(enrollmentControllerProvider);
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    // Explicit step gates (never phase.index: EnrollPhase.error sorts last
    // and must NOT read as done — a failed capture shows the Scan button
    // again with score 0, never the success copy).
    final hasAccount = st.account != null;
    final hasKey = st.pkHex.isNotEmpty;
    final hasFace = st.phase == EnrollPhase.faceDone ||
        st.phase == EnrollPhase.uploaded;
    return AdaptiveScaffold(
      title: 'Enroll this device',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _step(1, 'Google sign-in', true,
                child: st.account == null
                    ? FilledButton.icon(
                        icon: const Icon(Icons.login),
                        label: const Text('Sign in with Google'),
                        onPressed: ctl.signIn,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                              'Signed in as ${st.account!.displayName}\n${st.account!.email}'),
                          const SizedBox(height: 8),
                          TextField(
                            decoration: const InputDecoration(
                              labelText: 'ID Number',
                              helperText:
                                  'Required. Saved with your profile.',
                            ),
                            onChanged: ctl.setRoll,
                          ),
                        ],
                      )),
            _step(2, 'Device key', hasAccount,
                child: !hasKey
                    ? FilledButton(
                        // Silent-skip guard: no key without sign-in.
                        onPressed:
                            !hasAccount ? null : ctl.generateKey,
                        child: const Text('Generate device key'),
                      )
                    : Text('Key: ${st.pkHex.substring(0, 16)}…')),
            _step(3, 'Face enrollment (on-device)', hasKey,
                child: !hasFace
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // One tap, one camera page: remaining angles only —
                          // centre, left, right, top, bottom — each gated
                          // live by its pose zone with 0.70 pair scores.
                          // The camera exits ONLY on success (all remaining
                          // angles clear) or Cancel (completed angles kept);
                          // a weak angle never pops partial. Completed
                          // angles are never re-captured: resume passes ONLY
                          // the missing slots, mapped back by index.
                          LinearProgressIndicator(
                            value: st.angleSlots.where((d) => d).length /
                                enrollSlotNames.length,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${st.angleSlots.where((d) => d).length} of ${enrollSlotNames.length} angles captured',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 8),
                          for (var i = 0;
                              i < enrollSlotNames.length;
                              i++)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  Icon(
                                    st.angleSlots[i]
                                        ? Icons.check_circle
                                        : Icons.circle_outlined,
                                    color: st.angleSlots[i]
                                        ? Colors.green
                                        : null,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '${enrollSlotNames[i]} — ${enrollSlotHints[i]}',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            icon: const Icon(Icons.face),
                            label: Text(scanButtonLabel(st.angleSlots)),
                            // Never silently drop: Scan needs the key first.
                            onPressed: !hasKey
                                ? null
                                : () async {
                                    // All five angles are pose-gated live
                                    // (centre/left/right/top/bottom zones).
                                    // A section completes only when the face
                                    // IS at the right angle AND its best
                                    // embedded pair clears [kEnrollSectionScoreMin]
                                    // (0.70 — same bar the controller
                                    // re-validates, so the camera can never
                                    // demand more than the controller
                                    // accepts). The page stays open until
                                    // every remaining angle does (or Cancel).
                                    // Resume scans ONLY the missing slots.
                                    const allTargets = [
                                      PoseTarget.front,
                                      PoseTarget.left,
                                      PoseTarget.right,
                                      PoseTarget.up,
                                      PoseTarget.down,
                                    ];
                                    final allTitles = [
                                      for (var i = 0;
                                          i < enrollSlotNames.length;
                                          i++)
                                        '${enrollSlotNames[i]} — ${enrollSlotHints[i]}',
                                    ];
                                    final missing =
                                        missingSlots(st.angleSlots);
                                    if (missing.isEmpty) return;
                                    final targets = [
                                      for (final m in missing)
                                        allTargets[m]
                                    ];
                                    final titles = [
                                      for (final m in missing)
                                        allTitles[m]
                                    ];
                                    final frames =
                                        await Navigator.of(context)
                                            .push<List<Uint8List>>(
                                       MaterialPageRoute(
                                           builder: (_) =>
                                                 FaceCaptureScreen(
                                                  // Five angles need headroom:
                                                  // ~18 stills per angle at
                                                  // real-world cadence.
                                                  maxFrames: 90,
                                                  // Stay open: a weak angle
                                                  // keeps its camera across
                                                  // rounds until its pair
                                                  // clears the shared 0.70
                                                  // bar — the page exits
                                                  // ONLY on success or
                                                  // Cancel (which keeps
                                                  // completed angles).
                                                  stayOpen: true,
                                                  sectionScoreMin:
                                                      kEnrollSectionScoreMin,
                                                 sectionTargets: targets,
                                                 sectionTitles: titles,
                                                 scorer: ctl.embedder,
                                               )),
                                    );
                                    if (frames != null &&
                                        frames.isNotEmpty) {
                                      // Sections complete in order as best
                                      // pairs: pair k belongs to slot
                                      // missing[k] — completed angles are
                                      // never overwritten.
                                      final pairs =
                                          slotPairs(frames);
                                      for (var k = 0;
                                          k < pairs.length &&
                                              k < missing.length;
                                          k++) {
                                        await ctl.captureSlot(
                                            missing[k], pairs[k]);
                                      }
                                    }
                                  },
                          ),
                          // Escape hatch: one angle stuck in a drop→rescan
                          // loop (usually Top — see the pitch coaching in
                          // the controller) must never trap the holder.
                          // Clears ALL slot progress (key kept) so the next
                          // tap re-scans all five from a fresh start.
                          // Shown once at least one angle has landed.
                          if (st.angleSlots.any((d) => d))
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.refresh),
                                label: const Text(
                                    'Start over (clear all angles)'),
                                onPressed: ctl.restartFace,
                              ),
                            ),
                        ],
                      )
                    : st.restored && st.faceScore <= 0
                        ? const Text(
                            'Device key restored — no fresh face match yet (no score invented). Your saved enrollment still works for attendance; re-scan below to verify again.')
                        : Text(
                            'Face detected and enrolled on this device (match score ${st.faceScore.toStringAsFixed(2)}). Template never leaves this phone.')),
            if (st.phase == EnrollPhase.uploaded) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.face),
                label: const Text('Re-scan face'),
                onPressed: ctl.restartFace,
              ),
            ],
            _step(4, 'Save', hasFace,
                child: st.phase != EnrollPhase.uploaded
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FilledButton(
                            // Fail-closed UI: disabled until all 5 angles
                            // validate — one scanned section can never move
                            // forward (controller re-validates too).
                            onPressed: !hasFace
                                ? null
                                : () async {
                                    final id = await ctl.upload();
                                    if (id != null && context.mounted) {
                                      ref
                                          .read(linkedIdentityProvider
                                              .notifier)
                                          .state = id;
                                    }
                                  },
                            child: const Text('Save enrollment'),
                          ),
                          if (!hasFace)
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                'Complete all 5 face angles above to enable Save.',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                        ],
                      )
                    : const Text('✓ Enrolled. Identity linked for attendance.',
                        style: TextStyle(fontSize: 16))),
            if (st.phase == EnrollPhase.uploaded) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
            if (st.message.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(st.message, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: ctl.dismissError,
                child: Text(
                    st.phase == EnrollPhase.error ? 'Try again' : 'Dismiss'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _step(int n, String title, bool reached, {required Widget child}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('$n. $title',
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Opacity(opacity: reached || n == 1 ? 1.0 : 0.45, child: child),
        ],
      ),
    );
  }
}
