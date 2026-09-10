// SetupFlow combined device+intro step (§3.3): the device identity/key
// facts and the pre-capture context share ONE step screen — a single
// scroll, key facts first, then the intro's own Continue CTA — rather than
// two full pushes, since neither requires independent input, only
// acknowledgement. Step content only: the stepper chrome (progress line,
// step slides, back routing) lives in screens/setup_flow_screen.dart.
library;

import 'package:flutter/material.dart';

import '../../main.dart';
import 'device_identity_screen.dart';
import 'enroll_intro.dart';

/// Combined "Confirm device" step: [DeviceIdentityContent] (which account,
/// which device, move status) followed by [EnrollIntroContent] (what
/// happens, account pickup, device key, Continue to face scan).
class DeviceIntroStep extends StatelessWidget {
  const DeviceIntroStep({super.key});

  @override
  Widget build(BuildContext context) {
    return const AdaptiveScaffold(
      title: 'Confirm device',
      body: SingleChildScrollView(
        key: ValueKey('setup-combined-scroll'),
        child: Column(
          children: [
            DeviceIdentityContent(),
            EnrollIntroContent(),
          ],
        ),
      ),
    );
  }
}
