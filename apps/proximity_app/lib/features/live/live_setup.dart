// Live setup (prof live, §7.1): everything the professor configures BEFORE
// the first Start — display name, announce-IP picker, visibility guidance,
// and the Bluetooth/permission error line.
//
// The server line stays visible; the discovery/ladder explanation
// collapses into a shared [DetailsExpander] (§4.7) instead of an
// always-visible paragraph. Pinned copy (`Starting host…`, the name field
// label, `Announcing on <ip> · change`).
//
// This section is idle-time only: once the window is LIVE the header owns
// the screen and this collapses to the server line + errors. Nothing here
// is always-on mid-class (per the approved IA).
library;

import 'package:flutter/material.dart';
import 'package:proximity_transport/transport.dart';

import '../../design/tokens.dart';
import '../../widgets/details_expander.dart';
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

  /// Per-course opt-in: show my Gmail photo to joining students. False
  /// (default) hides the toggle's effect — students see initials. Null
  /// sink hides the toggle row (legacy call sites render as before).
  final bool showProfPhoto;
  final ValueChanged<bool>? onShowProfPhotoChanged;

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
    this.showProfPhoto = false,
    this.onShowProfPhotoChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Details sits ABOVE and OUTSIDE the session setup (always
        // visible — idle and mid-class): discovery + trust guidance must
        // stay reachable while attendance is live, when the setup block
        // below collapses to the server line.
        DetailsExpander(
          title: 'Details',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Advertising on WiFi + Bluetooth — students can see this class now and join the waiting area. Tap Start when the class has joined. If students on institute WiFi can\u2019t see it, have them type the IP shown below (this screen) with Bluetooth on — discovery broadcasts are advisory, the typed IP always works.',
                style: ProxType.caption(color: c.contentSecondary),
              ),
              const SizedBox(height: ProxSpacing.xs),
              Text(
                'Path: ${formatLadderLine(-1)}',
                style: ProxType.monoCaption(color: c.contentSecondary),
              ),
              // Trust explainer nested inside Details (guidance only —
              // no test-relevant copy): what students see next to this
              // class (Verified / New / Blocked) and why the first scan
              // is always New. Dropdown inside dropdown, same language
              // as the student browse screen.
              DetailsExpander(
                title: 'What students see: Verified or New',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Verified (green) — the student’s phone matched your saved class key. Nothing to do.\n'
                      'Unverified (yellow) — the student is seeing your class key for the first time on that phone. This is normal: the first scan is always Unverified, even when everything is fine. It turns Verified after they join once while online.\n'
                      'Blocked (red) — key mismatch. Ask the student to check they joined the right class; if it persists, re-announce the IP verbally.',
                      style: ProxType.caption(
                          color: c.contentSecondary),
                    ),
                  ],
                ),
              ),
              // Second nested explainer: the small Verified/Unverified
              // pill on each marked student row in the live roster, and
              // where to check your own device status.
              DetailsExpander(
                title: 'Student rows: Verified or Unverified',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Verified (green) — that student’s proof checked out clean.\n'
                      'Unverified (yellow) — that proof was flagged for review (device check or a duplicate-face pair). Presence is kept; check with the student after class.\n'
                      'Waiting students carry no pill — there is no proof to judge yet.\n'
                      'You can check your own device status in Account → Device.',
                      style: ProxType.caption(
                          color: c.contentSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: ProxSpacing.sm),
        // Same header as every other Live tab (exact Add-tab contract:
        // gradient accent bar + 17px title, zero padding — see
        // ProxSectionHeader). Worded `Session setup` so the exact-match
        // `Setup` sub-nav finder keeps resolving to the tab alone.
        const ProxSectionHeader(
          title: 'Session setup',
          padding: EdgeInsets.zero,
        ),
        if (!hosting && serverError == null) ...[
          const SizedBox(height: ProxSpacing.sm),
          Text(
            'Starting host…',
            style: ProxType.body(color: c.contentSecondary),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ],
        if (hosting && !live) ...[
          const SizedBox(height: ProxSpacing.sm),
          Text(
            'Advertising — students can join the waiting area. Tap Start when the class has joined.',
            style: ProxType.body(color: c.contentPrimary),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: ProxSpacing.sm),
          TextField(
            controller: nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Your name (optional, shown to students)',
            ),
            onChanged: onNameChanged,
          ),
          if (onShowProfPhotoChanged != null) ...[
            const SizedBox(height: ProxSpacing.xs),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                'Show my profile photo to students',
                style: ProxType.label(color: c.contentPrimary),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              subtitle: Text(
                showProfPhoto
                    ? 'On — joining students see your Gmail photo.'
                    : 'Off — students see your initial instead.',
                style: ProxType.caption(color: c.contentSecondary),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              value: showProfPhoto,
              activeThumbColor: c.accentBrand,
              onChanged: onShowProfPhotoChanged,
            ),
          ],
        ],
        if (serverLine != null) ...[
          const SizedBox(height: ProxSpacing.xs),
          // Address line: a short code/URL string, monospace per §2.2.
          // Plain Text (not SelectableText): the take-screen contract
          // reads this line with text finders, and it is short enough
          // to ellipsize rather than wrap.
          Text(
            serverLine!,
            style: ProxType.monoBody(color: c.contentPrimary),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ],
        if (allIps.length > 1) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: live ? null : onPickIp,
              child: Text(
                'Announcing on $currentIp · change',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ),
        ],
        if (serverError != null) ...[
          const SizedBox(height: ProxSpacing.xs),
          ProxErrorNote(serverError!),
        ],
      ],
    );
  }
}
