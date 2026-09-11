// Partial + absent lists (modular UI): students present in SOME but not
// all rounds of a session, and course-mates missing from it entirely.
// The course roster is the UNION of everyone seen in any of the course's
// sessions — no schema change needed: every synced session already carries
// its names/rolls, so a newcomer in a new class simply joins the union and
// reads as absent in earlier sessions (matching the matrix exports, which
// already treat missing as Absent). Pure computation plus the cards; the
// host screen supplies navigation and mark-present actions.
library;

import 'package:proximity_storage/storage.dart';

import 'clock.dart';

/// One course-mate: newest-seen name/roll wins.
class RosterEntry {
  final String email;
  final String name;
  final String roll;
  const RosterEntry(
      {required this.email, required this.name, required this.roll});
}

/// Union of all attendees over [sessions], newest session first so the
/// freshest name/roll wins. Pure — unit-tested without widgets.
List<RosterEntry> courseRoster(List<ClassRecord> sessions) {
  final names = <String, String>{};
  final rolls = <String, String>{};
  // Oldest first so the newest-seen name/roll wins.
  final ordered = List.of(sessions)
    ..sort((a, b) => a.timestampIso.compareTo(b.timestampIso));
  for (final r in ordered) {
    names.addAll(r.names);
    rolls.addAll(r.rolls);
  }
  final emails = <String>{
    for (final r in sessions) ...r.allEmails,
  };
  final out = [
    for (final e in emails)
      RosterEntry(email: e, name: names[e] ?? e, roll: rolls[e] ?? ''),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// One partially-present student: per-session round ticks, newest first.
class PartialEntry {
  final String email;
  final String name;
  final String roll;
  final List<(String sessionId, String label, String ticks)> sessions;
  const PartialEntry(
      {required this.email,
      required this.name,
      required this.roll,
      required this.sessions});
}

String _ticksFor(List<Map<String, bool>> windows, String email) =>
    ticksForWindows(windows, email);

/// Per-round ticks for one student ('R1 ✓ · R2 ✗'). Shared by the partial
/// cards, the session detail rows, and the saved-session editor subtitle.
/// Pure — unit-tested without widgets.
String ticksForWindows(List<Map<String, bool>> windows, String email) {
  final parts = <String>[];
  for (var i = 0; i < windows.length; i++) {
    parts.add('R${i + 1} ${windows[i][email] == true ? '✓' : '✗'}');
  }
  return parts.join(' · ');
}

/// Person subtitle: roll + email ('10000001 · a@x.in'), email alone when
/// no roll. Shared by live roster/inbox, session detail/edit, and partial
/// cards so every person row reads identically.
String rosterSubtitle(String roll, String email) =>
    [if (roll.isNotEmpty) roll, email].join(' · ');

/// Count of partially-present students in one record (some but not all
/// rounds). Shared by the overview card marker and the session detail
/// header. Pure.
int partialCountOf(
    List<Map<String, bool>> windows, Iterable<String> emails) {
  if (windows.length <= 1) return 0;
  var n = 0;
  for (final email in emails) {
    var some = false;
    var all = true;
    for (final w in windows) {
      if (w[email] == true) {
        some = true;
      } else {
        all = false;
      }
    }
    if (some && !all) n++;
  }
  return n;
}

/// Collects partial students over [sessions] (single-round sessions never
/// produce partials). Sorted by name. Pure — unit-tested without widgets.
List<PartialEntry> partialsOfCourse(List<ClassRecord> sessions) {
  final byEmail = <String, List<(String, String, String)>>{};
  final names = <String, String>{};
  final rolls = <String, String>{};
  for (final r in sessions) {
    if (r.windows.length <= 1) continue;
    // Global date rule, display only: with-day DD-MM-YYYY.
    final label =
        r.dateIso.isNotEmpty ? shortDayDateOf(r.dateIso) : r.classLabel;
    for (final email in r.allEmails) {
      var some = false;
      var all = true;
      for (final w in r.windows) {
        if (w[email] == true) {
          some = true;
        } else {
          all = false;
        }
      }
      if (some && !all) {
        byEmail.putIfAbsent(email, () => []).add(
            (r.id, label, _ticksFor(r.windows, email)));
        names.putIfAbsent(email, () => r.names[email] ?? email);
        if ((r.rolls[email] ?? '').isNotEmpty) {
          rolls[email] = r.rolls[email]!;
        }
      }
    }
  }
  final out = [
    for (final e in byEmail.entries)
      PartialEntry(
          email: e.key,
          name: names[e.key] ?? e.key,
          roll: rolls[e.key] ?? '',
          sessions: e.value),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}
