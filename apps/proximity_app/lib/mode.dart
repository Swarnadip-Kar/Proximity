import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Single app, two modes. Desktop defaults to prof; mobile switches freely.
enum AppMode { unset, student, prof, enroll }

final appModeProvider = StateProvider<AppMode>((ref) => _initialMode());

/// Debug entry for simulator visual checks (no taps needed):
/// `flutter build ios --simulator --dart-define=PROX_MODE=student|prof`.
/// Defaults to unset (role select); widget tests are unaffected.
AppMode _initialMode() {
  const v = String.fromEnvironment('PROX_MODE', defaultValue: 'unset');
  return switch (v) {
    'student' => AppMode.student,
    'prof' => AppMode.prof,
    'enroll' => AppMode.enroll,
    _ => AppMode.unset,
  };
}

/// Class label + window number under way (1 or 2). Present rule default 2/2.
final classLabelProvider = StateProvider<String>((ref) => 'CS201-Room301');
final windowNoProvider = StateProvider<int>((ref) => 1);
final lenientOneOfTwoProvider = StateProvider<bool>((ref) => false);

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
