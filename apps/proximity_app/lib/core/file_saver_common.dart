// Shared filename sanitizer for the CSV save path (Track 6).
//
// Was byte-identical `replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')` copies
// in file_saver_io.dart and file_saver_web.dart. Lives here
// (platform-neutral: no dart:io / package:web import) so both
// implementations share it without an import cycle through the
// file_saver.dart conditional-export facade.
library;

/// Replaces every character outside `[A-Za-z0-9._-]` with `_`.
String sanitizeFilename(String filename) =>
    filename.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
