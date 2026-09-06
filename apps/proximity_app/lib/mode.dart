import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/device_store.dart';

/// Single app, two modes. Desktop defaults to prof; mobile switches freely.
enum AppMode { unset, student, prof, enroll, take }

final appModeProvider = StateProvider<AppMode>((ref) => _initialMode());

/// Debug entry for simulator visual checks (no taps needed):
/// `flutter build ios --simulator --dart-define=PROX_MODE=student|prof|enroll|take`.
/// Defaults to unset (role select); widget tests are unaffected.
AppMode _initialMode() {
  const v = String.fromEnvironment('PROX_MODE', defaultValue: 'unset');
  return switch (v) {
    'student' => AppMode.student,
    'prof' => AppMode.prof,
    'enroll' => AppMode.enroll,
    'take' => AppMode.take,
    _ => AppMode.unset,
  };
}

/// Whether a compile-time preview flag was given.
bool get hasPreviewMode =>
    const String.fromEnvironment('PROX_MODE', defaultValue: 'unset') !=
    'unset';

/// Sets the mode and persists it: relaunch returns straight to the profile
/// main page. [AppMode.unset] clears it (next launch shows the hub).
Future<void> setMode(WidgetRef ref, AppMode mode) async {
  ref.read(appModeProvider.notifier).state = mode;
  try {
    final store = ref.read(deviceStoreProvider);
    await store.writeMode(mode == AppMode.unset ? null : mode.name);
  } catch (_) {}
}

/// Restores a persisted mode name (or null).
AppMode? modeFromName(String? name) => switch (name) {
      'student' => AppMode.student,
      'prof' => AppMode.prof,
      _ => null,
    };

/// Linked account identity (bound once at enrollment from the Gmail
/// account itself — name imported directly, no institute-ID matching.
/// Auto-attached to /prove during attendance; student never types anything).
class LinkedIdentity {
  final String name;
  final String gmail;
  final String roll; // institute ID / roll number: user-entered, unverified
  const LinkedIdentity(
      {required this.name, required this.gmail, this.roll = ''});
}

final linkedIdentityProvider = StateProvider<LinkedIdentity?>((ref) => null);
