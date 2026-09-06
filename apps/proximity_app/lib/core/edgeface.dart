// EdgeFace-XS embedding runtime facade.
//
// Native builds get the TFLite runtime (edgeface_native.dart); the web
// records build gets throwing stubs with identical names (edgeface_web.dart
// — the web app never embeds faces). Canonical conditional-export order
// (real first): the analyzer resolves the first branch statically.
library;

export 'edgeface_native.dart' if (dart.library.html) 'edgeface_web.dart';
