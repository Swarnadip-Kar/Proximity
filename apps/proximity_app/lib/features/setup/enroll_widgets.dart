// Enrollment bundle shared vocabulary (feature-local).
//
// The squeezed single-page enrollment is split into Account & key /
// Capture / Result; these widgets + copy keep the three screens reading
// as one flow.
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

/// Decision-point log for the bundle, via the shared BleLog pattern:
/// - FACE: why a rescan targets which slot(s), what the controller dropped.
/// - NAV: bundle moves (opened, account&key→capture, capture→result, done).
/// - SYNC: why the online claim was refused (or linked).
abstract final class EnrollLog {
  static void face(String msg) => BleLog.log('FACE', msg);
  static void nav(String msg) => BleLog.log('NAV', msg);
  static void sync(String msg) => BleLog.log('SYNC', msg);
}

/// THE instructional text of the capture session: one static prompt,
/// shown once, never changing mid-flow (narrating checker state is what
/// flickered — guidance now comes from the rim sweep, silent).
const enrollCapturePrompt = 'Rotate your face slowly, following the glow.';

/// THE single ID-number entry of the bundle (entered exactly once, on the
/// account & key step; the result step shows it readonly). One entry, one
/// validation (the controller's fail-closed roll check at Save) — never a
/// second prompt. Owns its controller, seeded from [initialValue] and
/// re-seeded when it changes externally (account switch clears the draft).
class EnrollRollField extends StatefulWidget {
  final String initialValue;
  final ValueChanged<String> onChanged;
  const EnrollRollField(
      {super.key, this.initialValue = '', required this.onChanged});

  @override
  State<EnrollRollField> createState() => _EnrollRollFieldState();
}

class _EnrollRollFieldState extends State<EnrollRollField> {
  late final TextEditingController _c =
      TextEditingController(text: widget.initialValue);

  @override
  void didUpdateWidget(EnrollRollField old) {
    super.didUpdateWidget(old);
    if (old.initialValue != widget.initialValue &&
        widget.initialValue != _c.text) {
      _c.text = widget.initialValue;
      _c.selection = TextSelection.collapsed(offset: _c.text.length);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      decoration: const InputDecoration(
        labelText: 'ID Number',
        helperText: 'Required. Saved with your profile.',
      ),
      textInputAction: TextInputAction.done,
      onChanged: widget.onChanged,
    );
  }
}

/// opened the bundle. Forward pushes name their routes (see EnrollFlow) so
/// Done lands on the opener, never mid-bundle.
abstract final class EnrollNav {
  static const routePrefix = 'enroll/';

  static void finish(BuildContext context) {
    EnrollLog.nav('enroll done — leaving bundle');
    Navigator.of(context).popUntil((route) {
      final name = route.settings.name;
      if (name == null) return true;
      if (name.startsWith(routePrefix)) return false;
      // Still-capture sheet (ProxRoutes.faceCapture, literal to avoid a
      // routes import cycle) is part of the bundle — pop it too.
      if (name == 'face/capture') return false;
      return true;
    });
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
    final color = targeted
        ? ProxStateColors.of(context, ProxState.waiting)
        : scheme.error;
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
