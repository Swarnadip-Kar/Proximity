// Draft recovery (prof live): autosaved-session policy + prompts.
//
// Policy (behavioral law — mirrors the take screen it was split from):
// the "Recover old session?" prompt appears ONLY when the autosaved draft
// is older than 2.5h (a genuinely old visit). A recent draft (quick
// back-nav, crash, app kill mid-lecture) is auto-archived to history as
// marked attendance and the professor resumes live with zero taps.
//
// This file owns the pure policy ([shouldPromptRecover]), the age copy,
// the old-session dialog, and the resumed-session banner. Draft
// persistence itself (read/write/clear) stays with the live screen, which
// re-exports the policy so existing imports keep working.
library;

import 'package:flutter/material.dart';

import '../../widgets/prox_cards.dart';

/// Session-recovery policy: prompt ONLY for drafts older than 2.5h.
const recoverPromptThreshold = Duration(minutes: 150);

/// Pure policy: true = prompt, false = auto-archive + fresh.
/// (Production code — the live screen decides on it; covered by tests.)
bool shouldPromptRecover(DateTime? savedAt, DateTime now) {
  if (savedAt == null) return false;
  return now.toUtc().difference(savedAt.toUtc()) > recoverPromptThreshold;
}

/// Human age for the recover dialog ('3h ago', '2d ago', '25m ago').
String draftAgeLine(Duration age) {
  if (age.inHours >= 24) return '${age.inDays}d ago';
  if (age.inHours >= 1) return '${age.inHours}h ago';
  return '${age.inMinutes}m ago';
}

/// Old-session prompt. Returns true = Recover, false = save & fresh.
/// Barrier-dismissal is off: the professor must pick (data is never
/// dropped either way — fresh archives to history first).
Future<bool?> showRecoverOldDialog(
    BuildContext context, DateTime? savedAt) {
  final age = savedAt == null
      ? 'a while ago'
      : draftAgeLine(DateTime.now().toUtc().difference(savedAt.toUtc()));
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Recover old session?'),
      content: Text(
          'An autosaved session from $age is still here. Recover it to continue, or save it to history and start fresh.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Save & start fresh'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Recover'),
        ),
      ],
    ),
  );
}

/// Resumed-draft banner: the recent visit continues under the SAME record
/// id (End upserts it — no duplicates). Discard wipes draft + live tally.
class DraftResumedBanner extends StatelessWidget {
  final int present;
  final int windowsTaken;
  final VoidCallback onDiscard;

  const DraftResumedBanner({
    super.key,
    required this.present,
    required this.windowsTaken,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    return ProxCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.history),
        title: const Text('Resumed autosaved session'),
        subtitle: Text(
            '$present present · $windowsTaken window${windowsTaken == 1 ? '' : 's'} so far — retake the round, take again, or end attendance.'),
        trailing: TextButton(
          onPressed: onDiscard,
          child: const Text('Discard'),
        ),
      ),
    );
  }
}
