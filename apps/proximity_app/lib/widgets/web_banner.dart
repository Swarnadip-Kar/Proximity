// Web records-mode banner (modular UI): the web build is records-viewing
// only — marking attendance (BLE + face + hosting) needs the native app.
// Shown on records screens when [kIsWeb]; nothing on native.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../design/tokens.dart';
import 'prox_cards.dart';

class WebRecordsBanner extends StatelessWidget {
  const WebRecordsBanner({super.key});

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return const SizedBox.shrink();
    return const ProxCard(
      padding: EdgeInsets.all(ProxSpacing.md),
      child: Row(
        children: [
          Icon(Icons.info_outline),
          SizedBox(width: ProxSpacing.sm),
          Expanded(
            child: Text(
              'Records view only on web — marking attendance needs the '
              'native app. Download it to enroll, host, or get marked.',
            ),
          ),
        ],
      ),
    );
  }
}
