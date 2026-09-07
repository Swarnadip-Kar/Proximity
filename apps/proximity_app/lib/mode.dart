import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';

import 'core/device_store.dart';
import 'design/tokens.dart';

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
/// Mode flips log STATE (previous → next) so the terminal + logcat show
/// the provider recompute reason; a persist failure logs too (a dropped
/// write would otherwise surface only as "relaunch forgot my mode").
Future<void> setMode(WidgetRef ref, AppMode mode) async {
  final prev = ref.read(appModeProvider);
  ref.read(appModeProvider.notifier).state = mode;
  BleLog.log(ProxLogTags.state, 'mode ${prev.name} → ${mode.name}');
  try {
    final store = ref.read(deviceStoreProvider);
    await store.writeMode(mode == AppMode.unset ? null : mode.name);
  } catch (_) {
    BleLog.log(ProxLogTags.state,
        'mode persist failed (${mode.name}) — relaunch returns to hub');
  }
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
