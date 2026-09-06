// Local IPv4 enumeration without a hard dart:io dependency: native builds
// list real interfaces, the web records build gets loopback (it never
// hosts). Canonical conditional-export order (real first).
library;

export 'net_if_io.dart' if (dart.library.html) 'net_if_web.dart';
