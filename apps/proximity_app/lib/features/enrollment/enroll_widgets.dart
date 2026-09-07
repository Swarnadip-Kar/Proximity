// Enrollment bundle shared vocabulary (feature-local).
//
// The squeezed single-page enrollment is split into Intro / Capture /
// Result; these widgets + copy keep the three screens reading as one flow.
// Motion follows the app language: user taps spring (ProxCurves.spring),
// system arrivals ease (ProxCurves.standard), every duration routes through
// ProxMotion so reduced-motion degrades to instant-but-correct. Nothing here
// gates actions — all animation is interruptible presentation.
//
// Decision-point logging (FACE/NAV/SYNC) rides the shared BleLog ring, so
// the on-screen terminal and `adb logcat` carry the same history.
import 'package:flutter/material.dart';
import 'package:proximity_ble/ble.dart';

import '../../core/face_detect.dart';
import '../../design/tokens.dart';
import '../../widgets/prox_motion.dart';

/// Friendly retry brief — reassurance, never an error. Shown near the start
/// of Intro + Capture, and repeated under targeted rescans so retry two or
/// three never reads as failure.
const enrollRetryBrief =
    'Getting a good scan sometimes takes 3–4 tries, no worries 🙂';

/// Decision-point log for the bundle, via the shared BleLog pattern:
/// - FACE: why a rescan targets which slot(s), what the controller dropped.
/// - NAV: bundle moves (opened, intro→capture, capture→result, done).
/// - SYNC: why the online claim was refused (or linked).
abstract final class EnrollLog {
  static void face(String msg) => BleLog.log('FACE', msg);
  static void nav(String msg) => BleLog.log('NAV', msg);
  static void sync(String msg) => BleLog.log('SYNC', msg);
}

/// Bundle navigation helper: pops every `enroll/…` route back to whatever
/// opened the bundle. Forward pushes name their routes (see EnrollFlow) so
/// Done lands on the opener, never mid-bundle.
abstract final class EnrollNav {
  static const routePrefix = 'enroll/';

  static void finish(BuildContext context) {
    EnrollLog.nav('enroll done — leaving bundle');
    Navigator.of(context).popUntil((route) =>
        route.settings.name == null ||
        !route.settings.name!.startsWith(routePrefix));
  }
}

/// Animated slot progress: sweeps toward the new fraction over
/// [ProxDurations.medium] instead of jumping. Pure presentation.
class EnrollProgress extends StatelessWidget {
  final int done;
  final int total;
  const EnrollProgress({super.key, required this.done, required this.total});

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

/// One angle row. When [done] flips false → true the check pops with a short
/// spring (user progress → spring); distinct from the error shake below.
class EnrollAngleRow extends StatelessWidget {
  final bool done;
  final String label;
  final Duration delay;
  const EnrollAngleRow({
    super.key,
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
            const SizedBox(width: ProxSpacing.sm),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }
}

/// Bundle notice with two motion signatures, distinguishable before reading:
/// - targeted rescan ("retry this angle") → amber, gentle slide+fade.
/// - session failure (anything else) → error color, one short shake.
class EnrollNotice extends StatefulWidget {
  final String message;
  final bool isError;
  const EnrollNotice({super.key, required this.message, required this.isError});

  @override
  State<EnrollNotice> createState() => _EnrollNoticeState();
}

class _EnrollNoticeState extends State<EnrollNotice>
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
  void didUpdateWidget(EnrollNotice old) {
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
    final color =
        targeted ? ProxStateColors.of(context, ProxState.waiting) : scheme.error;
    final icon = targeted ? Icons.refresh : Icons.error_outline;
    if (ProxMotion.reduced(context)) {
      return _row(color, icon);
    }
    if (targeted) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: _c, curve: ProxCurves.standard),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.3),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: _c, curve: ProxCurves.standard)),
          child: _row(color, icon),
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
      child: _row(color, icon),
    );
  }

  Widget _row(Color color, IconData icon) {
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

/// Pose-guidance indicator for the guided scan: oval + progress sweep with a
/// direction marker for the active angle (arrow at the edge, dot for
/// Centre). Pure Flutter (AnimationController + CustomPainter, no assets).
///
/// Display-only: the real yaw/pitch gates live in the shared camera loop
/// (face_detect `poseOkWithRef`, enforced by FaceCaptureScreen) — this
/// never gates anything and never intercepts taps. Fixed size so it never
/// moves layout; the nudge-in replays when [target] changes (system-driven
/// → eased), and reduced-motion shows the static frame.
class EnrollPoseGuide extends StatefulWidget {
  final PoseTarget target;
  final double progress;
  final bool active;
  const EnrollPoseGuide({
    super.key,
    required this.target,
    required this.progress,
    this.active = true,
  });

  @override
  State<EnrollPoseGuide> createState() => _EnrollPoseGuideState();
}

class _EnrollPoseGuideState extends State<EnrollPoseGuide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: ProxDurations.medium);
    _c.forward();
  }

  @override
  void didUpdateWidget(EnrollPoseGuide old) {
    super.didUpdateWidget(old);
    if (old.target != widget.target) {
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
    final dial = SizedBox(
      width: 148,
      height: 176,
      child: CustomPaint(
        painter: _EnrollPosePainter(
          target: widget.target,
          progress: widget.progress.clamp(0.0, 1.0),
          base: scheme.outline,
          ring: scheme.primary,
        ),
      ),
    );
    if (ProxMotion.reduced(context) || !widget.active) return dial;
    return FadeTransition(
      opacity: CurvedAnimation(parent: _c, curve: ProxCurves.standard),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.12),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _c, curve: ProxCurves.standard)),
        child: dial,
      ),
    );
  }
}

class _EnrollPosePainter extends CustomPainter {
  final PoseTarget target;
  final double progress;
  final Color base;
  final Color ring;
  _EnrollPosePainter({
    required this.target,
    required this.progress,
    required this.base,
    required this.ring,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width - 28,
      height: size.height - 28,
    );
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = base,
    );
    if (progress > 0.005) {
      canvas.drawArc(
        rect,
        -3.141592653589793 / 2,
        2 * 3.141592653589793 * progress.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..color = ring,
      );
    }
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = ring;
    final c = size.center(Offset.zero);
    switch (target) {
      case PoseTarget.left:
        _arrow(canvas, Offset(6, c.dy), -1, 0, fill);
      case PoseTarget.right:
        _arrow(canvas, Offset(size.width - 6, c.dy), 1, 0, fill);
      case PoseTarget.up:
        _arrow(canvas, Offset(c.dx, 6), 0, -1, fill);
      case PoseTarget.down:
        _arrow(canvas, Offset(c.dx, size.height - 6), 0, 1, fill);
      case PoseTarget.any:
      case PoseTarget.front:
        canvas.drawCircle(c, 5, fill);
    }
  }

  void _arrow(Canvas canvas, Offset tip, double dx, double dy, Paint paint) {
    const len = 14.0;
    const half = 8.0;
    final bx = tip.dx - dx * len;
    final by = tip.dy - dy * len;
    // Perpendicular offsets for the triangle base.
    final px = -dy * half;
    final py = dx * half;
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(bx + px, by + py)
        ..lineTo(bx - px, by - py)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(_EnrollPosePainter old) =>
      old.target != target ||
      old.progress != progress ||
      old.base != base ||
      old.ring != ring;
}
