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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/web_banner.dart';
import '../entry/entry_flow.dart';
import 'welcome_sections.dart';

/// Unauthenticated welcome. Hosted wherever the account stream is null
/// (proposed: landing router shows this when `accountProvider` is null).
///
/// Thin composer over [WelcomeHeroSection] + [WelcomeSignInSection]: owns
/// the sign-in/offline state machine, sections own the copy layout.
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
                const WelcomeHeroSection(),
                const SizedBox(height: ProxSpacing.lg),
                WelcomeSignInSection(
                  busy: _busy,
                  status: _status,
                  onSignIn: _signIn,
                  onOfflineProf: _continueOfflineProf,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
