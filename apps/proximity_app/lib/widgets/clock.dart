import 'dart:async';

import 'package:flutter/material.dart';

/// Global date rule — DISPLAY STRINGS ONLY, app-wide (storage/CSV/
/// filenames stay yyyy-MM-dd via `dateIsoOf`):
/// - plain dates: DD-MM-YYYY (e.g. 03-09-2026) via [shortDateOf] /
///   [displayDate];
/// - with weekday: `[Day], DD-MM-YYYY` (e.g. `Thu, 03-09-2026` for short
///   rows, `Thursday, 03-09-2026` for roomy lines) via [shortDayDateOf] /
///   [fullDateOf] / [formatDate].
const _kWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _kWeekdaysFull = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
];

/// Plain display date for a DateTime: DD-MM-YYYY (e.g. 03-09-2026).
/// Global rule, display only — storage stays yyyy-MM-dd.
String displayDate(DateTime t) =>
    '${t.day.toString().padLeft(2, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.year.toString().padLeft(4, '0')}';

/// With-weekday display for a DateTime: `Thu, 03-09-2026`.
/// Global rule, display only (ClockHeader + dateless-session fallback).
String formatDate(DateTime t) =>
    '${_kWeekdays[t.weekday - 1]}, ${displayDate(t)}';

/// Lenient ISO date parse (yyyy-MM-dd or full timestamp); null when garbage.
DateTime? tryParseDate(String iso) {
  try {
    return DateTime.parse(iso);
  } catch (_) {
    return null;
  }
}

/// Short weekday for a yyyy-MM-dd date ('Fri'); '' when unparseable.
String shortDayOf(String dateIso) {
  final d = tryParseDate(dateIso);
  return d == null ? '' : _kWeekdays[d.weekday - 1];
}

/// Plain display date: DD-MM-YYYY (e.g. 03-09-2026). Global rule,
/// display only — storage stays yyyy-MM-dd. Falls back to the raw string.
String shortDateOf(String dateIso) {
  final d = tryParseDate(dateIso);
  if (d == null) return dateIso;
  return '${d.day.toString().padLeft(2, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.year.toString().padLeft(4, '0')}';
}

/// Short weekday + display date for tight rows ('Thu, 03-09-2026').
/// Global rule, display only. Session cards (course overview rows +
/// student session tiles) must use this (WITH the day), never the plain
/// [shortDateOf].
String shortDayDateOf(String dateIso) {
  final day = shortDayOf(dateIso);
  final date = shortDateOf(dateIso);
  return day.isEmpty ? date : '$day, $date';
}

/// Full-weekday display date for roomy UI ('Thursday, 03-09-2026').
/// Global rule, display only. Falls back to the raw string.
String fullDateOf(String dateIso) {
  final d = tryParseDate(dateIso);
  if (d == null) return dateIso;
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  final yyyy = d.year.toString().padLeft(4, '0');
  return '${_kWeekdaysFull[d.weekday - 1]}, $dd-$mm-$yyyy';
}

/// Display date + time for a full timestamp
/// ('Thu, 03-09-2026 · 10:04 AM'). Global rule, display only.
/// 12-hour with AM/PM — every on-screen clock time uses this shape.
/// Empty when the timestamp carries no clock time or is unparseable.
String shortTimeOf(String timestampIso) {
  final d = tryParseDate(timestampIso);
  if (d == null) return '';
  final local = d.toLocal();
  if (local.hour == 0 && local.minute == 0 && local.second == 0) return '';
  return _twelveHourMinute(local.hour, local.minute);
}

/// 24-hour HH:mm for a full timestamp ('14:30'). STORAGE/CSV ONLY — never
/// for on-screen UI text. Preserves the pre-12-hour bytes for matrix
/// column disambiguation / export headers; UI callers must use
/// [shortTimeOf] (12-hour with AM/PM).
String shortTime24Of(String timestampIso) {
  final d = tryParseDate(timestampIso);
  if (d == null) return '';
  final local = d.toLocal();
  if (local.hour == 0 && local.minute == 0 && local.second == 0) return '';
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// 12-hour HH:mm with AM/PM ('02:26 PM'). Display only — shared by
/// [shortTimeOf] and [formatTime] so every UI clock reads identically.
String _twelveHourMinute(int hour24, int minute) {
  final period = hour24 >= 12 ? 'PM' : 'AM';
  var h12 = hour24 % 12;
  if (h12 == 0) h12 = 12;
  return '${h12.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')} $period';
}

/// Ticking clock time ('02:26:05 PM'). Display only — 12-hour with AM/PM,
/// consumed by [ClockHeader]. Seconds preserved; CSV/storage never routes
/// through here.
String formatTime(DateTime t) {
  final period = t.hour >= 12 ? 'PM' : 'AM';
  var h12 = t.hour % 12;
  if (h12 == 0) h12 = 12;
  return '${h12.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')} $period';
}

/// Tight session title: short weekday + DD-MM-YYYY, time when known
/// ('CS201 · Thu, 03-09-2026 · 10:00 AM'). Global rule, display only.
/// Shared by the course overview and the export center so both lists read
/// identically. Pure — no record import.
String sessionTightLabel(
    String classLabel, String dateIso, String timestampIso) {
  final time = shortTimeOf(timestampIso);
  return '$classLabel · ${shortDayDateOf(dateIso)}'
      '${time.isEmpty ? '' : ' · $time'}';
}

/// Roomy subtitle line: full weekday + DD-MM-YYYY
/// ('Thursday, 03-09-2026 · 10:00 AM'). Global rule, display only.
/// Shared by the overview + export lists.
String sessionRoomyLine(String dateIso, String timestampIso) {
  final time = shortTimeOf(timestampIso);
  return '${fullDateOf(dateIso)}${time.isEmpty ? '' : ' · $time'}';
}

/// Tight-row last-date label: short weekday + DD-MM-YYYY
/// ('Thu, 03-09-2026'). Global rule, display only.
/// Pass-through for the 'no sessions yet' sentinel. Shared by the prof
/// course picker rows.
String lastDateLabel(String lastDate) =>
    lastDate.startsWith('no') ? lastDate : shortDayDateOf(lastDate);

/// Clearly visible date + ticking clock for every screen.
class ClockHeader extends StatefulWidget {
  const ClockHeader({super.key});

  @override
  State<ClockHeader> createState() => _ClockHeaderState();
}

class _ClockHeaderState extends State<ClockHeader> {
  DateTime _now = DateTime.now();
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text('${formatDate(_now)} · ${formatTime(_now)}',
        style: Theme.of(context).textTheme.titleMedium);
  }
}
