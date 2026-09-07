// One-line degradation-ladder status (Track 4 §2): the same rung order
// the BleLog carries, rendered as a single caption line. [active] brackets
// the current rung (-1 = path order only, for screens without rung state).
library;

import 'package:flutter/material.dart';
import 'package:proximity_transport/transport.dart';

class LadderLine extends StatelessWidget {
  final int active;
  const LadderLine({super.key, this.active = -1});

  @override
  Widget build(BuildContext context) {
    return Text(
      'Path: ${formatLadderLine(active)}',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
