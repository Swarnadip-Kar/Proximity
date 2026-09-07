// Shared filename sanitizer for the CSV save path (platform-neutral: no
// dart:io / package:web import, so both implementations share it without
// cycling through the file_saver.dart conditional-export facade).
library;

/// Replaces every character outside `[A-Za-z0-9._-]` with `_`.
String sanitizeFilename(String filename) =>
    filename.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
