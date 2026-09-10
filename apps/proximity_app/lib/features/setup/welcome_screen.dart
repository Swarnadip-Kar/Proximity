// S01 Welcome — the unauthenticated entry screen.
//
// Purpose: the hero moment + the value proposition + the way in. Shows
// what the app does (room-presence attendance for students, phone-hosted
// classes for professors), the one-Gmail honesty (students must sign in,
// professors may skip offline), and the sign-in action. Zero-tap state is
// value + sign-in: nothing here needs an account to read.
//
// Absorbs the signed-out branch of screens/landing.dart
// (_signedOutBody): same copy, same web guards (no offline hosting on web
// records builds), same mounted-guarded navigation. The rings hero is
// rebuilt here with real typographic hierarchy (theme display/body tokens
// — Space Grotesk display + Inter body via the app theme, intentional
// spacing) instead of the old title-plus-spinner placeholder rhythm.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/web_banner.dart';
import '../entry/entry_flow.dart';

/// Unauthenticated welcome. Hosted wherever the account stream is null
/// (proposed: landing router shows this when `accountProvider` is null).
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  String _status = '';
  bool _busy = false;

  Future<void> _run(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      await fn();
    } catch (e) {
      if (mounted)
        setState(() => _status = '$e'.replaceFirst('StateError: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() => _run(() async {
        final acct = await entrySignIn(ref);
        if (acct == null && mounted) {
          setState(() => _status = 'Sign-in cancelled.');
        }
        // Auth state streams into accountProvider; the role step renders
        // next (silent session adopt — the button is only the
        // fresh-install fallback).
      });

  // Direct tap, no busy wrapper (mirrors the old landing): setMode never
  // throws out (failures are caught inside) and there is no await before
  // the guarded goto.
  Future<void> _continueOfflineProf() =>
      entryContinueOfflineProf(ref, () => mounted);

  @override
  Widget build(BuildContext context) {
    return AdaptiveScaffold(
      title: 'Proximity',
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ProxStaggered(
              children: [
                const WebRecordsBanner(),
                const _WelcomeHero(),
                const SizedBox(height: ProxSpacing.lg),
                Text(
                  'Campus Attendance',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: ProxSpacing.sm),
                Text(
                  'One sign-in for everyone. Students must sign in — each Gmail can '
                  'hold only one enrolled student device (checked online). Professors '
                  'may skip: classes then stay on this device only until you sign in '
                  'and sync.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: ProxSpacing.xl),
                ProxPrimaryButton(
                  icon: const Icon(Icons.login),
                  label: const Text('Sign in with Google'),
                  onPressed: _busy ? null : _signIn,
                ),
                // No offline hosting on web records builds (no BLE/HTTPS there).
                if (!kIsWeb) ...[
                  const SizedBox(height: ProxSpacing.md),
                  ProxSecondaryButton(
                    icon: const Icon(Icons.present_to_all),
                    label: const Text('Continue as Professor offline'),
                    onPressed: _busy ? null : _continueOfflineProf,
                    expanded: true,
                  ),
                  const SizedBox(height: ProxSpacing.xs),
                  Text(
                    'Offline professors keep everything on this device. Sign in later '
                    'to back up, sync across devices, and share CSVs from the cloud.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
                if (_status.isNotEmpty) ...[
                  const SizedBox(height: ProxSpacing.md),
                  ProxErrorNote(_status),
                ],
                if (_busy) ...[
                  const SizedBox(height: ProxSpacing.md),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hero moment: proximity rings emanating from a classroom mark, over a
/// strong typographic hierarchy (letterspaced eyebrow → display headline
/// → value subline). Pure Flutter (CustomPainter + a 50ms progress timer
/// — no assets, no infinite ticker so `pumpAndSettle`-based tests still
/// settle). Static when reduced motion is on.
class _WelcomeHero extends StatefulWidget {
  const _WelcomeHero();

  @override
  State<_WelcomeHero> createState() => _WelcomeHeroState();
}

class _WelcomeHeroState extends State<_WelcomeHero> {
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
                painter: _RingsPainter(
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

class _RingsPainter extends CustomPainter {
  final double progress;
  final Color primary;
  final Color secondary;
  _RingsPainter({
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
  bool shouldRepaint(_RingsPainter old) => old.progress != progress;
}
