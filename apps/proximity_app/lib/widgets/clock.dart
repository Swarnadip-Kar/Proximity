import 'dart:async';

import 'package:flutter/material.dart';

const _kWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _kMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];
const _kWeekdaysFull = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
];
const _kMonthsFull = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'
];

String formatDate(DateTime t) =>
    '${_kWeekdays[t.weekday - 1]}, ${t.day} ${_kMonths[t.month - 1]} ${t.year}';

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

/// Short UI date: day + month ('4 Sep'). Falls back to the raw string.
String shortDateOf(String dateIso) {
  final d = tryParseDate(dateIso);
  return d == null ? dateIso : '${d.day} ${_kMonths[d.month - 1]}';
}

/// Short weekday + date for tight rows ('Fri, 4 Sep').
String shortDayDateOf(String dateIso) {
  final day = shortDayOf(dateIso);
  final date = shortDateOf(dateIso);
  return day.isEmpty ? date : '$day, $date';
}

/// Full date with weekday and year for roomy UI
/// ('Friday, 4 September 2026'). Falls back to the raw string.
String fullDateOf(String dateIso) {
  final d = tryParseDate(dateIso);
  return d == null
      ? dateIso
      : '${_kWeekdaysFull[d.weekday - 1]}, ${d.day} ${_kMonthsFull[d.month - 1]} ${d.year}';
}

/// Short date + time for a full timestamp ('Fri, 4 Sep · 10:04').
/// Empty when the timestamp carries no clock time or is unparseable.
String shortTimeOf(String timestampIso) {
  final d = tryParseDate(timestampIso);
  if (d == null) return '';
  final local = d.toLocal();
  if (local.hour == 0 && local.minute == 0 && local.second == 0) return '';
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

String formatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';

String dateIsoOf(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

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
