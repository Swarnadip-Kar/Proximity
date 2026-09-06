// One-time online enrollment: Google session (picked up silently) →
// device key → on-device face → upload key+faceHash. Nothing to type —
// identity imports from Gmail.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/enrollment.dart';
import '../core/face_detect.dart';
import '../design/tokens.dart';
import '../main.dart';
import '../mode.dart';
import '../widgets/prox_buttons.dart';
import '../widgets/prox_motion.dart';
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
                          //
                          // Reassurance (not an error): good scans often take
                          // a few tries — holders should not feel they failed
                          // on retry two or three.
                          const Text(
                            'Getting a good scan sometimes takes 3–4 tries, no worries 🙂',
                            style: TextStyle(fontStyle: FontStyle.italic),
                          ),
                          const SizedBox(height: 8),
                          _AnimatedEnrollProgress(
                            done: st.angleSlots.where((d) => d).length,
                            total: enrollSlotNames.length,
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
                            _AngleRow(
                              done: st.angleSlots[i],
                              label:
                                  '${enrollSlotNames[i]} — ${enrollSlotHints[i]}',
                              delay: Duration(
                                  milliseconds: (i * 40)
                                      .clamp(0, 400)),
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
              _EnrollNotice(
                message: st.message,
                isError: st.phase == EnrollPhase.error,
              ),
              const SizedBox(height: 8),
              ProxSecondaryButton(
                label: Text(
                    st.phase == EnrollPhase.error ? 'Try again' : 'Dismiss'),
                onPressed: ctl.dismissError,
                expanded: false,
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
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Opacity(opacity: reached || n == 1 ? 1.0 : 0.45, child: child),
        ],
      ),
    );
  }
}

/// Animated enrollment progress: sweeps toward the new fraction over
/// [ProxDurations.medium] instead of jumping. Pure presentation — the
/// angle state underneath is unchanged.
class _AnimatedEnrollProgress extends StatelessWidget {
  final int done;
  final int total;
  const _AnimatedEnrollProgress({required this.done, required this.total});

  @override
  Widget build(BuildContext context) {
    final target = total == 0 ? 0.0 : done / total;
    if (ProxMotion.reduced(context)) {
      return LinearProgressIndicator(value: target);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: target),
      duration: ProxDurations.medium,
      curve: ProxCurves.standard,
      builder: (context, value, _) =>
          LinearProgressIndicator(value: value),
    );
  }
}

/// One angle row. When [done] flips false → true the check pops with a
/// short spring so "angle complete" reads as confirmation, distinct from
/// the error shake in [_EnrollNotice].
class _AngleRow extends StatelessWidget {
  final bool done;
  final String label;
  final Duration delay;
  const _AngleRow({
    required this.done,
    required this.label,
    this.delay = Duration.zero,
  });

  @override
  Widget build(BuildContext context) {
    final ok = Theme.of(context).colorScheme.primary;
    return ProxFadeSlideIn(
      delay: delay,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: ProxMotion.effective(context, ProxDurations.small),
              switchInCurve: ProxCurves.spring,
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: anim,
                child: child,
              ),
              child: Icon(
                done ? Icons.check_circle : Icons.circle_outlined,
                key: ValueKey<bool>(done),
                color: done ? ok : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }
}

/// Enrollment notice with two motion signatures, distinguishable before
/// reading a word:
/// - targeted rescan ("retry this angle": message names a rescan/retry of
///   an angle) → amber, gentle slide+fade in place.
/// - session failure (anything else at error phase) → error color, one
///   short horizontal shake.
class _EnrollNotice extends StatefulWidget {
  final String message;
  final bool isError;
  const _EnrollNotice({required this.message, required this.isError});

  @override
  State<_EnrollNotice> createState() => _EnrollNoticeState();
}

class _EnrollNoticeState extends State<_EnrollNotice>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  bool get _targeted {
    final m = widget.message.toLowerCase();
    return m.contains('rescan') ||
        m.contains('retry') ||
        m.contains('angle') ||
        m.contains('weakest');
  }

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: _targeted ? ProxDurations.medium : ProxDurations.small,
    )..forward();
  }

  @override
  void didUpdateWidget(_EnrollNotice old) {
    super.didUpdateWidget(old);
    if (old.message != widget.message) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final targeted = _targeted;
    final color = targeted ? ProxStateColors.of(context, ProxState.waiting) : scheme.error;
    final icon = targeted ? Icons.refresh : Icons.error_outline;
    if (ProxMotion.reduced(context)) {
      return _row(context, color, icon);
    }
    if (targeted) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: _c, curve: ProxCurves.standard),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.3),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: _c, curve: ProxCurves.standard)),
          child: _row(context, color, icon),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value.clamp(0.0, 1.0);
        final dx =
            t < 1.0 ? (1 - t) * 8 * _ShakeSin.impl(t * 3 * 6.28318530718) : 0.0;
        return Transform.translate(
          offset: Offset(dx, 0),
          child: Opacity(opacity: t < 0.25 ? t / 0.25 : 1, child: child),
        );
      },
      child: _row(context, color, icon),
    );
  }

  Widget _row(BuildContext context, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(ProxSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(ProxRadii.md),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: ProxSpacing.sm),
          Expanded(
            child: Text(widget.message, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

class _ShakeSin {
  static double impl(double x) {
    var n = x % 6.283185307179586;
    if (n > 3.141592653589793) n -= 6.283185307179586;
    if (n < -3.141592653589793) n += 6.283185307179586;
    final x2 = n * n;
    return n * (1 - x2 / 6 + x2 * x2 / 120);
  }
}
