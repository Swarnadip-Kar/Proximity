// kIsWeb-safe platform flags. dart:io Platform is unavailable on web, so
// every OS check in shared code goes through here (foundation only).
library;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

bool get isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
bool get isMacOS =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
bool get isLinux =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
bool get isWindows =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
