// CSV saving without a hard dart:io dependency: native builds write into
// the app documents directory, the web records build downloads the file.
// Canonical conditional-export order (real first).
library;

export 'file_saver_io.dart' if (dart.library.html) 'file_saver_web.dart';
