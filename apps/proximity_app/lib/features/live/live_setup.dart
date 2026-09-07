// Live setup (prof live): everything the professor configures BEFORE the
// first Start — display name, announce-IP picker, visibility guidance, and
// the Bluetooth/permission error line.
//
// This section is idle-time only: once the window is LIVE the header owns
// the screen and this collapses to the server line + errors. Nothing here
// is always-on mid-class (per the approved IA).
library;

import 'package:flutter/material.dart';

import '../../widgets/prox_cards.dart';
import '../../widgets/prox_states.dart';

/// Lets the professor pick which local IP to announce when several NICs
/// show up (VPN vs WiFi) — the top cause of "students can't find me".
/// Returns the picked IP, or null when cancelled/unchanged.
Future<String?> showAnnounceIpDialog(
  BuildContext context, {
  required List<String> allIps,
  required String currentIp,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Announce on'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final ip in allIps)
              ProxListTile(
                title: ip,
                trailing: ip == currentIp ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(ip),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}
/// Pre-window setup block. [hosting] false + no error reads as the
/// transient 'Starting host…' line; the name field + visibility guidance
/// show only while idle (hosting && !live); the announce line, IP picker,
/// and error line show whenever their data exists.
class LiveSetupSection extends StatelessWidget {
  final bool hosting;
  final bool live;
  final TextEditingController nameCtrl;
  final ValueChanged<String> onNameChanged;
  final String? serverLine;
  final List<String> allIps;
  final String currentIp;
  final VoidCallback onPickIp;
  final String? serverError;

  const LiveSetupSection({
    super.key,
    required this.hosting,
    required this.live,
    required this.nameCtrl,
    required this.onNameChanged,
    required this.serverLine,
    required this.allIps,
    required this.currentIp,
    required this.onPickIp,
    required this.serverError,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!hosting && serverError == null) ...[
          const SizedBox(height: 8),
          const Text('Starting host…'),
        ],
        if (hosting && !live) ...[
          const SizedBox(height: 8),
          const Text(
              'Advertising on WiFi + Bluetooth — students can see this class now and join the waiting area. Tap Start when the class has joined. If students on institute WiFi can\u2019t see it, have them type the IP shown below (this screen) with Bluetooth on — discovery broadcasts are advisory, the typed IP always works.'),
          const SizedBox(height: 8),
          TextField(
            controller: nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Your name (optional, shown to students)',
            ),
            onChanged: onNameChanged,
          ),
        ],
        if (serverLine != null) ...[
          const SizedBox(height: 4),
          Text(serverLine!, style: Theme.of(context).textTheme.bodyMedium),
        ],
        if (allIps.length > 1) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: live ? null : onPickIp,
              child: Text('Announcing on $currentIp · change'),
            ),
          ),
        ],
        if (serverError != null) ...[
          const SizedBox(height: 4),
          ProxErrorNote(serverError!),
        ],
      ],
    );
  }
}
