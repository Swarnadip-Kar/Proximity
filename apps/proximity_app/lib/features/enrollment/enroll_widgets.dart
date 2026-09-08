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

import '../../design/tokens.dart';

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

/// Guided-enrollment angle instructions, in [faceEnrollSlots] capture order.
/// Short imperative copy per angle (Android-face-unlock-style): what to do
/// with the head, held near-frontal throughout. Each angle is REALLY gated
/// at capture (PoseGate euler windows on the still) — the copy tells the
/// user what the gate will check, it never pretends detection that isn't
/// there. The plugin owns match tolerance, not the angles.
class EnrollAngleInstruction {
  final String title;
  final String detail;
  const EnrollAngleInstruction(this.title, this.detail);
}

const enrollAngleInstructions = <EnrollAngleInstruction>[
  EnrollAngleInstruction(
    'Look straight',
    'Face the camera — eyes on the lens, face centred in the oval, hold still.',
  ),
  EnrollAngleInstruction(
    'Turn slightly left',
    'Small turn left — keep both eyes visible to the camera, hold still.',
  ),
  EnrollAngleInstruction(
    'Turn slightly right',
    'Small turn right — keep both eyes visible to the camera, hold still.',
  ),
  EnrollAngleInstruction(
    'Tilt slightly up',
    'Chin up just a touch — eyes still on the lens, hold still.',
  ),
  EnrollAngleInstruction(
    'Tilt slightly down',
    'Chin down just a touch — eyes still on the lens, hold still.',
  ),
];

/// Angle progress dots: one dot per enrollment still (filled = captured,
/// ring = current, dim = upcoming). Plain containers on the shared spacing
/// scale — static, timer-free (unlike the pulsing [ProxDot]), so tests
/// settle and idle screens stay cheap.
class EnrollAngleDots extends StatelessWidget {
  final int done;
  final int total;
  final int current;
  const EnrollAngleDots(
      {super.key, required this.done, required this.total, this.current = 0});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Captured $done of $total angles',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < total; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: ProxSpacing.xs),
              child: Container(
                key: ValueKey('angle-dot-$i'),
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < done ? scheme.primary : Colors.transparent,
                  border: Border.all(
                    color: i == current && i >= done
                        ? scheme.primary
                        : scheme.onSurfaceVariant.withValues(alpha: 0.5),
                    width: i == current && i >= done ? 2.5 : 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
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
