import 'dart:async';

import 'package:flutter/material.dart';

const _kWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _kMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

String formatDate(DateTime t) =>
    '${_kWeekdays[t.weekday - 1]}, ${t.day} ${_kMonths[t.month - 1]} ${t.year}';

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
