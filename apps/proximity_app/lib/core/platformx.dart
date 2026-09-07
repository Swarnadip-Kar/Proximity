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
bool get isWeb => kIsWeb;

/// Mobile-only predicate (Tracks 2+3 L1 domain gate): face verification
/// (plugin) + HW device key exist ONLY on Android/iOS. Desktop/web are
/// records-only (professor hosting + records review).
bool get isMobile => isAndroid || isIOS;

/// L1 domain gate: true only where the face/device trust stack exists.
/// Called by the FaceVerifier/DeviceKey adapters AND by
/// StudentDriver.checkFace/listenAndProve before anything signs.
bool canUseFace() => isMobile;

/// L1 enforcement: throws fail-closed on records-only devices (never a
/// silent mock pass — SK never signs without a real holder check).
void requireMobileFace() {
  if (!canUseFace()) {
    throw StateError(
        'Face verification needs the mobile app (Android/iOS) — this device is records-only.');
  }
}
