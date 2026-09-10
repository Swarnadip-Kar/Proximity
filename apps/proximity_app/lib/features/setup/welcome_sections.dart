// Welcome step sections: hero moment + sign-in block.
//
// Split from welcome_screen.dart (presentation only — same copy, same
// guards, same motion). The screen owns the sign-in state machine and
// composes these; sections own the layout. Secondary professor prose
// sits collapsed behind a DetailsExpander (§4.7); the sign-in actions,
// the status/busy signals, and the one-device honesty line stay visible.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import 'setup_details.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_states.dart';

/// Hero moment: proximity rings emanating from a classroom mark, over a
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
  static const _loop = Duration(milliseconds: 2400);
  static const _tick = Duration(milliseconds: 50);
  Timer? _timer;
  var _progress = 0.0;
  var _armed = false;

  // The reduced-motion read must live here, not in initState:
  // MediaQuery is an inherited widget and initState may not register
  // inherited dependencies (red-screened on device as
  // dependOnInheritedWidgetOfExactType called before initState completed).
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
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Eyebrow: product category, letterspaced, live-accent color.
        Text(
          'PROXIMITY · CAMPUS ATTENDANCE',
          textAlign: TextAlign.center,
          style: text.labelLarge?.copyWith(
            color: scheme.secondary,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.0,
          ),
        ),
        const SizedBox(height: ProxSpacing.sm),
        SizedBox(
          height: 148,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size(220, 148),
                painter: _WelcomeRingsPainter(
                  progress: _progress,
                  primary: scheme.primary,
                  secondary: scheme.secondary,
                ),
              ),
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.35),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.groups_outlined,
                  size: 36,
                  color: scheme.onPrimary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: ProxSpacing.sm),
        // Display headline (Space Grotesk via the theme) + value subline
        // (Inter body): the zero-tap story — be in the room, get marked.
        Text(
          'Be there. Be marked.',
          textAlign: TextAlign.center,
          style: text.displaySmall?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.1,
          ),
        ),
        const SizedBox(height: ProxSpacing.sm),
        Text(
          'Students prove room presence over Bluetooth with a face check; '
          'professors host from their phone. Online once — offline in class.',
          textAlign: TextAlign.center,
          style: text.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _WelcomeRingsPainter extends CustomPainter {
  final double progress;
  final Color primary;
  final Color secondary;
  _WelcomeRingsPainter({
    required this.progress,
    required this.primary,
    required this.secondary,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // Three rings, phase-offset so one is always mid-expansion.
    for (var i = 0; i < 3; i++) {
      final t = ((progress + i / 3) % 1.0);
      final radius = 34 + t * 62;
      final alpha = (1 - t) * 0.45;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = (i.isEven ? primary : secondary).withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_WelcomeRingsPainter old) => old.progress != progress;
}

/// Sign-in block: title + one-device honesty + actions + status signals.
/// Professor prose (the may-skip line + the offline note) sits collapsed
/// behind DetailsExpander — same sentences verbatim, never reworded.
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
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Campus Attendance',
          textAlign: TextAlign.center,
          style: text.headlineMedium,
        ),
        const SizedBox(height: ProxSpacing.sm),
        Text(
          'One sign-in for everyone. Students must sign in — each Gmail can '
          'hold only one enrolled student device (checked online).',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
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
            style: text.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
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
          const SizedBox(height: ProxSpacing.md),
          const Center(child: CircularProgressIndicator()),
        ],
      ],
    );
  }
}
