// dart:io implementation of [saveTextFile] (+ [isExportDirWritable]).
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'export_location.dart';
import 'file_saver_common.dart';

/// Writable check for a picked export directory: creates it (recursive,
/// so a deleted-then-reselected folder still passes) and proves a write
/// with a probe file that is deleted immediately. Never throws.
Future<bool> isExportDirWritable(String path) async {
  final dirPath = normalizeExportDir(path);
  if (dirPath == null) return false;
  try {
    final dir = Directory(dirPath);
    await dir.create(recursive: true);
    final probe = File('${dir.path}/.prox_write_test');
    await probe.writeAsString('ok');
    await probe.delete();
    return true;
  } catch (_) {
    return false;
  }
}

/// Writes [content] as [filename] into the resolved export directory
/// (see [resolveExportDir]: explicit [directory] override, else the
/// stored per-device default, else system Downloads, else app documents)
/// and returns the saved path. Filename bytes are untouched — only WHERE
/// the file lands is resolved here.
Future<String> saveTextFile(String filename, String content,
    {String? directory}) async {
  final stored = await _storedExportDir();
  final dirPath = await resolveExportDir(
    customDir: normalizeExportDir(directory) ?? stored,
    getDownloadsPath: () async => (await getDownloadsDirectory())?.path,
    getDocumentsPath: () async =>
        (await getApplicationDocumentsDirectory()).path,
  );
  final safe = sanitizeFilename(filename);
  await Directory(dirPath).create(recursive: true);
  final file = File('$dirPath/$safe');
  await file.writeAsString(content);
  return file.path;
}

/// Best-effort read of the stored per-device default. Never throws —
/// unreadable prefs just mean "no custom location".
Future<String?> _storedExportDir() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(exportDirPrefsKey);
  } catch (_) {
    return null;
  }
}
