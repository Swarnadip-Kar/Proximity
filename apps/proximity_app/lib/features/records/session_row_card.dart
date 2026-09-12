// Shared session-row card: ONE module, two homes (course overview +
// export center). Avatar course disc, caller-formatted main line,
// rounds/present/partial/absent counts row, attendance % top-right,
// share bar footer — everything from one place, never copy-pasted per
// screen. Selection visuals ride the shared StudentCard contract
// (hold-and-tap on overview, tap-to-select on export).
library;

import 'package:flutter/material.dart';

import 'package:proximity_storage/storage.dart';

import '../../design/app_theme.dart';
import '../../design/tokens.dart';
import '../../widgets/clock.dart';
import '../../widgets/student_card.dart';

/// Short main line for session rows: short day + short date + time
/// ('Fri, 11-09-26 · 12:26 PM'). Time omitted when unknown. Shared by the
/// overview and the export center (one formatter, one card).
String sessionShortLine(ClassRecord r) {
  final day = shortDayDateOf(r.dateIso).split(' ');
  final date = day.length > 1 ? day.last : r.dateIso;
  final parts = date.split('-');
  final shortDate = parts.length == 3
      ? '${parts[0]}-${parts[1]}-${parts[2].substring(parts[2].length - 2)}'
      : date;
  final weekday = day.isNotEmpty ? day.first.replaceAll(',', '') : '';
  final time = shortTimeOf(r.timestampIso);
  return '$weekday, $shortDate${time.isEmpty ? '' : ' · $time'}';
}

/// One session row: date main line, % top-right, four evenly-spaced
/// cells (rounds | present ✓ | partial | absent), slim share bar.
/// Callers pass raw counts; segments, clamps and labels live here.
class SessionRowCard extends StatelessWidget {
  final String courseName;
  final String title;
  final int windows;
  final int present;
  final int partial;
  final int absent;

  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool>? onSelectionChanged;
  final VoidCallback? onTap;

  /// False hides the avatar disc + course identity (the export page
  /// shows date-only rows). True keeps the course disc.
  final bool showAvatar;

  const SessionRowCard({
    super.key,
    required this.courseName,
    required this.title,
    required this.windows,
    required this.present,
    required this.partial,
    required this.absent,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectionChanged,
    this.onTap,
    this.showAvatar = true,
  });

  @override
  Widget build(BuildContext context) {
    final total = present + partial + absent;
    return StudentCard(
      name: title,
      avatarName: courseName,
      showAvatar: showAvatar,
      // Symmetric slim padding (top == bottom).
      padding: const EdgeInsets.all(ProxSpacing.md),
      subtitleTrailing: _countsLine(context),
      status: Text(
        total == 0 ? '–' : '${(100 * present / total).round()}%',
        style: proxTabular(
          context,
          ProxType.title(color: ProximityColors.of(context).contentPrimary),
        ),
      ),
      footer: SessionShareBar(
        present: present,
        partial: partial,
        absent: absent,
      ),
      selectionMode: selectionMode,
      selected: selected,
      onSelectionChanged: onSelectionChanged,
      onTap: onTap,
    );
  }

  /// Four equal centered cells: rounds | present | partial | absent.
  Widget _countsLine(BuildContext context) {
    final c = ProximityColors.of(context);
    Widget roundsCell() => Expanded(
          child: Text(
            '$windows round${windows == 1 ? '' : 's'}',
            style: ProxType.caption(color: c.contentSecondary),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            softWrap: false,
            textAlign: TextAlign.center,
          ),
        );
    Widget countCell(int n, IconData icon, Color color) => Expanded(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  '$n',
                  style: ProxType.label(color: color).copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.clip,
                  maxLines: 1,
                  softWrap: false,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 2),
              Icon(icon, size: 12, color: color),
            ],
          ),
        );
    Widget partialCell() => Expanded(
          child: Text(
            '$partial partial',
            style: ProxType.label(
              color: ProxIcons.statusForeground(context, ProxStatus.late),
            ).copyWith(fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            softWrap: false,
            textAlign: TextAlign.center,
          ),
        );
    return Row(
      children: [
        roundsCell(),
        countCell(
          present,
          Icons.check,
          ProxIcons.statusForeground(context, ProxStatus.marked),
        ),
        partialCell(),
        countCell(
          absent,
          Icons.close,
          ProxIcons.statusForeground(context, ProxStatus.absent),
        ),
      ],
    );
  }
}

/// Attendance share bar: green ([statusMarked]) present, yellow
/// ([statusLate]) partial, red ([statusError]) absent — hard stops at
/// each fraction, never a blend. Slim strip only (counts live above);
/// empty roster = plain divider track. Static — no timers, settle-safe.
/// Shared by the session rows and the session detail header (one bar,
/// never copy-pasted per screen).
class SessionShareBar extends StatelessWidget {
  final int present;
  final int partial;
  final int absent;

  const SessionShareBar({
    super.key,
    required this.present,
    required this.partial,
    required this.absent,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final total = present + partial + absent;
    if (total <= 0) {
      return Container(
        height: 8,
        decoration: BoxDecoration(
          color: c.divider,
          borderRadius: BorderRadius.circular(ProxRadii.pill),
        ),
      );
    }
    final p = present / total;
    final pa = (present + partial) / total;
    return Container(
      height: 8,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ProxRadii.pill),
        gradient: LinearGradient(
          stops: [0.0, p, p, pa, pa, 1.0],
          colors: [
            c.statusMarked,
            c.statusMarked,
            c.statusLate,
            c.statusLate,
            c.statusError,
            c.statusError,
          ],
        ),
      ),
    );
  }
}
