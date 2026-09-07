// Web implementation of [saveTextFile]: triggers a browser download,
// returns the filename as the "path".
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'file_saver_common.dart';

/// Writes [content] as [filename] via a browser download.
Future<String> saveTextFile(String filename, String content) async {
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
