// Web implementation of [saveTextFile]: triggers a browser download,
// returns the filename as the "path".
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'file_saver_common.dart';
import 'export_location.dart';

/// Web has no filesystem directory to validate (the browser owns the
/// download location): any non-blank path reads as writable so the
/// setting row shares the same validation call on every target.
Future<bool> isExportDirWritable(String path) async =>
    normalizeExportDir(path) != null;

/// Writes [content] as [filename] via a browser download. [directory] is
/// accepted (same signature as the io build) and ignored — the browser
/// manages the destination, so web keeps working exactly as today.
Future<String> saveTextFile(String filename, String content,
    {String? directory}) async {
  // ignore: unused_element_parameter — signature parity with the io
  // build; the browser manages the destination.
  final _ = directory;
  final safe = sanitizeFilename(filename);
  final blob = web.Blob([content.toJS].toJS,
      web.BlobPropertyBag(type: 'text/csv'));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = safe;
  web.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return safe;
}
