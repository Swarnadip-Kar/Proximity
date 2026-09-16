// Shared CSV preview dialog: Close + Save to device + Share.
//
// Was two hand-rolled AlertDialog copies (per-session + date-range matrix
// in the old course page, now unified in the export center). One dialog,
// identical strings/buttons everywhere: 'Close', 'Save', 'Share'.
// Save downloads in-browser on web records builds, writes to app documents
// natively; Share uses the platform sheet. Pure presentation — callers own
// the CSV bytes + filename + subject.
library;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/file_saver.dart';
import '../design/tokens.dart';

/// Shows [csv] with Close + Save + Share. [onSave]/[onShare] are the
/// caller's persistence hooks so this dialog never touches providers —
/// the export center passes its `_saveCsv`/`_shareCsv` (which log NAV).
Future<void> showCsvPreviewDialog(
  BuildContext context, {
  required String title,
  required String csv,
  required Future<void> Function() onSave,
  required Future<void> Function() onShare,
}) {
  // Dead-screen guard: callers awaiting a previous dialog/sheet may resume
  // after dispose — never open on an unmounted context.
  if (!context.mounted) return Future.value();
  return showDialog(
    context: context,
    // Dialog-local context for every pop: the caller's context may
    // unmount while the dialog is open (records lists rebuild under
    // it), stranding taps on a route that never closes with a
    // null-check crash. Save/Share close FIRST so their SnackBars and
    // sheets land on the visible screen, not behind the dialog.
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: SelectableText(csv)),
      actions: [
        SizedBox(
          width: double.infinity,
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Save'),
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    onSave();
                  },
                ),
              ),
              const SizedBox(width: ProxSpacing.sm),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share'),
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    onShare();
                  },
                ),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Writes [csv] to the device (or downloads on web) and reports the path
/// via SnackBar. Shared save path for the export center. The destination
/// resolves inside [saveTextFile] (custom export default → Downloads →
/// documents); [directory] overrides it for one save only.
Future<void> saveCsvToDevice(
    BuildContext context, String csv, String filename,
    {String? directory}) async {
  try {
    final path =
        await saveTextFile(filename, csv, directory: directory);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to device: $path')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }
}

/// Shares [csv] via the platform sheet.
Future<void> shareCsvText(String csv, String subject) {
  return SharePlus.instance.share(ShareParams(text: csv, subject: subject));
}
