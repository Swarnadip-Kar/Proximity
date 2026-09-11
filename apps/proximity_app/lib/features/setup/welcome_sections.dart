// Welcome step sections: hero moment + sign-in block.
//
// UI Overhaul: dramatic hero with animated radar sweep, staggered
// typography entrance, refined visual hierarchy. Sign-in actions use
// the new gradient buttons. Professor prose stays collapsed.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import 'setup_details.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_states.dart';

/// Hero moment: animated radar sweep with concentric proximity rings,
/// strong typographic hierarchy (letterspaced eyebrow → display headline
/// → value subline). Pure Flutter (CustomPainter + a 50ms progress timer
/// — no assets, no infinite ticker so `pumpAndSettle`-based tests still
/// settle). Static when reduced motion is on.
class WelcomeHeroSection extends StatefulWidget {
  const WelcomeHeroSection({super.key});

  @override
  State<WelcomeHeroSection> createState() => _WelcomeHeroSectionState();
}

class _WelcomeHeroSectionState extends State<WelcomeHeroSection> {
  static const _loop = Duration(milliseconds: 3000);
  static const _tick = Duration(milliseconds: 50);
  Timer? _timer;
  var _progress = 0.0;
  var _armed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_armed) return;
    _armed = true;
    if (!ProxMotion.reduced(context)) {
      _timer = Timer.periodic(_tick, (_) {
        if (!mounted) return;
        setState(() => _progress =
            (_progress + _tick.inMilliseconds / _loop.inMilliseconds) % 1.0);
      });
    } else {
      _progress = 0.35;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: ProxSpacing.lg),
        // Top header: category descriptor where the brand eyebrow was.
        // Color: c.statusMarked — the exact global "present" green from
        // the design tokens (same green as the present badges/status
        // language). Same typeface/weight as the eyebrow, scaled to a
        // readable secondary size (not the main text, but legible).
        ProxFadeSlideIn(
          delay: const Duration(milliseconds: 100),
          child: Text(
            'Campus Attendance System',
            textAlign: TextAlign.center,
            style: ProxType.label(color: c.statusMarked).copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 2.0,
              fontSize: 15,
            ),
          ),
        ),
        const SizedBox(height: ProxSpacing.xl),
        // Radar sweep hero.
        ProxHeroEntrance(
          child: SizedBox(
            height: 180,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Concentric rings + radar sweep.
                CustomPaint(
                  size: const Size(260, 180),
                  painter: _WelcomeRadarPainter(
                    progress: _progress,
                    brandColor: c.accentBrand,
                    markedColor: c.statusMarked,
                    surfaceColor: c.surfaceBase,
                  ),
                ),
                // Center beacon with breathing glow.
                ProxPulseGlow(
                  color: c.accentBrand,
                  blurRadius: 32,
                  child: Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: c.gradientBrand,
                      boxShadow: [
                        BoxShadow(
                          color: c.accentBrand.withValues(alpha: 0.4),
                          blurRadius: 32,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.sensors,
                      size: 32,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: ProxSpacing.xl),
        // Center brand: "PROXIMITY" as the screen's central text. Same
        // typeface, weight, purple (c.accentBrand) and letterspaced
        // treatment — only the size is scaled up (anchored to the
        // display-size token, not a new style).
        ProxFadeSlideIn(
          delay: const Duration(milliseconds: 300),
          child: Text(
            'PROXIMITY',
            textAlign: TextAlign.center,
            style: ProxType.label(color: c.accentBrand).copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 4.0,
              fontSize: ProxType.displaySize,
            ),
          ),
        ),
        const SizedBox(height: ProxSpacing.md),
        // Value subline.
        ProxFadeSlideIn(
          delay: const Duration(milliseconds: 450),
          child: Text(
            'Room presence over Bluetooth.\n'
            'Face check on-device. Offline in class.',
            textAlign: TextAlign.center,
            style: ProxType.body(color: c.contentSecondary).copyWith(
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

/// Radar sweep painter: 5 concentric rings with varying stroke widths,
/// gradient strokes, and a rotating sweep arc.
class _WelcomeRadarPainter extends CustomPainter {
  final double progress;
  final Color brandColor;
  final Color markedColor;
  final Color surfaceColor;

  _WelcomeRadarPainter({
    required this.progress,
    required this.brandColor,
    required this.markedColor,
    required this.surfaceColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // 5 concentric rings with staggered fade.
    for (var i = 0; i < 5; i++) {
      final t = ((progress + i / 5) % 1.0);
      final radius = 32 + t * 68;
      final alpha = (1 - t).clamp(0.0, 1.0) * 0.35;
      final strokeWidth = 1.0 + (1 - t) * 1.5;
      final color = i.isEven ? brandColor : markedColor;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = color.withValues(alpha: alpha),
      );
    }

    // Radar sweep arc: rotating gradient wedge.
    final sweepAngle = progress * 2 * math.pi;
    final sweepPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = brandColor.withValues(alpha: 0.5);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: 60),
      sweepAngle,
      math.pi / 3,
      false,
      sweepPaint,
    );

    // Small scattered dots at random-looking but deterministic positions.
    final dotPaint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < 8; i++) {
      final angle = (i * 0.785 + progress * 0.3);
      final dist = 35 + (i * 7.3) % 55;
      final dx = center.dx + dist * math.cos(angle);
      final dy = center.dy + dist * math.sin(angle);
      final dotAlpha = (0.15 + 0.2 * math.sin(progress * 6.28 + i)).clamp(0.0, 1.0);
      dotPaint.color = (i.isEven ? brandColor : markedColor)
          .withValues(alpha: dotAlpha);
      canvas.drawCircle(Offset(dx, dy), 2.5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(_WelcomeRadarPainter old) => old.progress != progress;
}

/// Sign-in block: title + one-device honesty + actions + status signals.
/// Professor prose (the may-skip line + the offline note) sits collapsed
/// behind DetailsExpander — same sentences verbatim, never reworded.
///
/// UI Overhaul: uses gradient ProxPrimaryButton, refined typography,
/// staggered entrance.
class WelcomeSignInSection extends StatelessWidget {
  final bool busy;
  final String status;
  final Future<void> Function() onSignIn;
  final Future<void> Function() onOfflineProf;

  const WelcomeSignInSection({
    super.key,
    required this.busy,
    required this.status,
    required this.onSignIn,
    required this.onOfflineProf,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Divider line.
        Container(
          height: 1,
          margin: const EdgeInsets.symmetric(
            horizontal: ProxSpacing.xxl,
            vertical: ProxSpacing.sm,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.transparent,
                c.divider,
                Colors.transparent,
              ],
            ),
          ),
        ),
        const SizedBox(height: ProxSpacing.md),
        Text(
          'Get Started',
          textAlign: TextAlign.center,
          style: ProxType.title(color: c.contentPrimary),
        ),
        const SizedBox(height: ProxSpacing.sm),
        Text(
          'One sign-in for everyone. Students must sign in — each Gmail can '
          'hold only one enrolled student device.',
          textAlign: TextAlign.center,
          style: ProxType.caption(color: c.contentSecondary).copyWith(
            height: 1.5,
          ),
        ),
        SetupDetails(
          title: 'For professors',
          child: Text(
            kIsWeb
                ? 'Professors may skip: classes then stay on this device only '
                    'until you sign in and sync.'
                : 'Professors may skip: classes then stay on this device only '
                    'until you sign in and sync. Offline professors keep '
                    'everything on this device. Sign in later to back up, '
                    'sync across devices, and share CSVs from the cloud.',
            style: ProxType.caption(color: c.contentSecondary),
          ),
        ),
        const SizedBox(height: ProxSpacing.xl),
        ProxPrimaryButton(
          icon: const Icon(Icons.login),
          label: const Text('Sign in with Google'),
          onPressed: busy ? null : onSignIn,
        ),
        // No offline hosting on web records builds (no BLE/HTTPS there).
        if (!kIsWeb) ...[
          const SizedBox(height: ProxSpacing.md),
          ProxSecondaryButton(
            icon: const Icon(Icons.present_to_all),
            label: const Text('Continue as Professor offline'),
            onPressed: busy ? null : onOfflineProf,
            expanded: true,
          ),
        ],
        if (status.isNotEmpty) ...[
          const SizedBox(height: ProxSpacing.md),
          ProxErrorNote(status),
        ],
        if (busy) ...[
          const SizedBox(height: ProxSpacing.lg),
          Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: c.accentBrand,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
