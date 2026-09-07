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
  return showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: SelectableText(csv)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.save_alt),
          label: const Text('Save'),
          onPressed: onSave,
        ),
        FilledButton.icon(
          icon: const Icon(Icons.ios_share),
          label: const Text('Share'),
          onPressed: onShare,
        ),
      ],
    ),
  );
}

/// Writes [csv] to the device (or downloads on web) and reports the path
/// via SnackBar. Shared save path for the export center.
Future<void> saveCsvToDevice(
    BuildContext context, String csv, String filename) async {
  try {
    final path = await saveTextFile(filename, csv);
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
