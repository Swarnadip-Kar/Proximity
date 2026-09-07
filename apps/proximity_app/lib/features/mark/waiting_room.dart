// Waiting room (student mark): Connected/status + heartbeat presence.
// Join never starts the face scan — it registers presence (professor sees
// n waiting), pre-warms BLE, and parks here. When the window opens the
// room auto-advances to face check with no new taps.
//
// Motion intent: the Connected badge + status line swap via [ProxSwitcher]
// (system-driven, eased) so the open-flip reads as a continuation of this
// same screen — the shell then carries it into face check.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_states.dart';

class WaitingRoomView extends StatelessWidget {
  final bool connected;
  final String roomClass;
  final List<String> roundMarks;
  final VoidCallback onRequestManual;
  final VoidCallback onCancel;

  const WaitingRoomView({
    super.key,
    required this.connected,
    required this.roomClass,
    required this.roundMarks,
    required this.onRequestManual,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ProxFadeSlideIn(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ProxSwitcher(
                child: ProxStateBadge(
                  key: ValueKey<bool>(connected),
                  state: connected ? ProxState.active : ProxState.waiting,
                  label: connected ? 'Connected' : 'Not connected',
                  pulse: connected,
                ),
              ),
              const SizedBox(height: 12),
              ProxSwitcher(
                child: Text(
                  connected
                      ? 'Connected — waiting for professor to start marking'
                      : 'Not connected — check WiFi / IP',
                  key: ValueKey<bool>(connected),
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Attendance has not yet started for\n$roomClass.\nKeep this open — you will continue automatically when the professor starts marking.',
                textAlign: TextAlign.center,
              ),
              if (!connected) ...[
                const SizedBox(height: 8),
                Text(
                  'Honestly unreachable right now — check the IP and that both devices are on the same WiFi. Presence retries every 2s; hosting that ended returns you to the live list.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (roundMarks.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'This session: ${roundMarks.join(' · ')}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              ProxSecondaryButton(
                icon: const Icon(Icons.how_to_reg),
                label: const Text('Request manual attendance'),
                onPressed: onRequestManual,
              ),
              const SizedBox(height: 8),
              ProxSecondaryButton(
                label: const Text('Cancel'),
                onPressed: onCancel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
