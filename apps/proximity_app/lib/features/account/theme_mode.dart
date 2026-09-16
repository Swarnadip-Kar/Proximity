// Account theme control — persistence for the Dark/Light/System switcher.
//
// THE called-out addition for the Account section (§5.1: no switcher exists
// today; `MaterialApp.themeMode` is fixed to `ThemeMode.system` in
// `lib/main.dart`). Presentation-scoped: a minimal SharedPreferences-backed
// provider colocated here in `features/account/`. No attendance semantics
// touched — this only decides which brightness the MaterialApp builds with.
//
// Wiring (mechanical, same addition): `ProximityApp` watches
// [themeModeProvider] for `MaterialApp.themeMode`. Key: `prox.themeMode.v1`
// (`dark`/`light`/`system`; anything else reads as system).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Prefs key for the persisted theme choice.
const themeModePrefsKey = 'prox.themeMode.v1';

/// Parses a persisted choice. Pure — unknown/missing reads as system.
ThemeMode themeModeFromName(String? name) => switch (name) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };

/// Serializes a choice for prefs. Pure.
String themeModeToName(ThemeMode mode) => switch (mode) {
      ThemeMode.dark => 'dark',
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
    };

/// Owns the app brightness choice: starts at system, loads the persisted
/// choice best-effort, persists every explicit set best-effort.
class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController() : super(ThemeMode.system) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = themeModeFromName(prefs.getString(themeModePrefsKey));
    } catch (_) {
      // Unreadable prefs (tests without mocks, odd devices): stay system.
    }
  }

  /// Persists [mode] and applies it. Never throws.
  Future<void> set(ThemeMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(themeModePrefsKey, themeModeToName(mode));
    } catch (_) {
      // Best-effort only: the in-memory choice still applies this launch.
    }
  }
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>(
        (ref) => ThemeModeController());
