// dart:io implementation of [saveTextFile].
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Writes [content] as [filename] into the app documents directory and
/// returns the saved path.
Future<String> saveTextFile(String filename, String content) async {
  final dir = await getApplicationDocumentsDirectory();
  final safe = filename.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  final file = File('${dir.path}/$safe');
  await file.writeAsString(content);
  return file.path;
}
