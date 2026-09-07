// dart:io implementation of [saveTextFile].
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'file_saver_common.dart';

/// Writes [content] as [filename] into the app documents directory and
/// returns the saved path.
Future<String> saveTextFile(String filename, String content) async {
  final dir = await getApplicationDocumentsDirectory();
  final safe = sanitizeFilename(filename);
  final file = File('${dir.path}/$safe');
  await file.writeAsString(content);
  return file.path;
}
