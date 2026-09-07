// Callable POST without a hard dart:io dependency: native builds use
// HttpClient (platform trust store — correct for cloudfunctions.net); the
// web records build never verifies (records only, no device key) and
// reports unreachable so the engine defers. Canonical conditional-export
// order (real first), same as file_saver.dart / net_if.dart.
library;

export 'attest_http_io.dart' if (dart.library.html) 'attest_http_web.dart';
