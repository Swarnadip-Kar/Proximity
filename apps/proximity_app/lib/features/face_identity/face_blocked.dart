// Blocked-state card for records-only devices (desktop/web): face and
// device-binding flows redirect here instead of landing on dead ends.
// Shown by the L2 route guard (records/mine guidance) and asserted by
// every face screen (L1) — tested in face_identity_test.dart.
library;

import 'package:flutter/material.dart';

import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../widgets/prox_cards.dart';

/// Guidance card for mobile-only flows on records-only devices.
class FaceBlockedCard extends StatelessWidget {
  final String flow;
  const FaceBlockedCard({super.key, this.flow = 'Face enrollment'});

  @override
  Widget build(BuildContext context) {
    // per-screen Card+Padding copies.
    return ProxCard(
      padding: const EdgeInsets.all(ProxSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.smartphone_outlined),
              const SizedBox(width: ProxSpacing.sm),
              Expanded(
                child: Text(
                  '$flow needs the mobile app',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: ProxSpacing.sm),
          Text(
            canUseFace()
                ? 'Face verification is available on this device — sign in and try again.'
                : 'This ${_deviceLabel()} is records-only: enrollment and marking run on Android/iOS, where the face check and device key stay on-device. Your records below are unaffected.',
          ),
          const SizedBox(height: ProxSpacing.sm),
          const Text(
              'On your phone: sign in → enroll this device → join the class to mark.'),
        ],
      ),
    );
  }

  String _deviceLabel() {
    if (isWeb) return 'browser';
    if (isMacOS || isWindows || isLinux) return 'desktop';
    return 'device';
  }
}
