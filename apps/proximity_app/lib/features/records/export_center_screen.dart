// Review/export of the past for one course: per-session CSV
// preview/share/save plus the calendar date-range matrix export (email
// primary key, P/A per session). Split out of the old course page so the
// overview stays about managing the course. Export is allowed on web
// records builds (Save downloads in-browser); only the Live tab runs the
// room capture, which is never referenced here.
//
// Data logic preserved per the Phase-1 exemption (filter, sort, CSV bytes,
// filenames, matrix builder): restyle only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

import '../../core/auth.dart';
import '../../core/device_store.dart';
import '../../design/app_theme.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/clock.dart';
import '../../widgets/csv_preview.dart';
import '../../widgets/details_expander.dart';
import '../../widgets/log_drawer.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/web_banner.dart';

class ExportCenterScreen extends ConsumerStatefulWidget {
  final String courseName;
  const ExportCenterScreen({super.key, required this.courseName});

  @override
  ConsumerState<ExportCenterScreen> createState() => _ExportCenterScreenState();
}

class _ExportCenterScreenState extends ConsumerState<ExportCenterScreen> {
  String? _rangeError;

  List<ClassRecord> _sessions(
      List<ClassRecord> history, String myOrg) {
    final out = history
        .where((r) =>
            (r.courseId == widget.courseName ||
                (r.courseId.isEmpty && r.classLabel == widget.courseName)) &&
            // Org scope: same-org plus legacy '' (exportable locally only).
            // Cross-org sessions never list here.
            (r.org.isEmpty || myOrg.isEmpty || r.org == myOrg))
        .toList()
      ..sort((a, b) => b.timestampIso.compareTo(a.timestampIso));
    return out;
  }

  /// Org line for CSV previews: `Org,<org>` ('' = legacy local-only).
  static String withOrgLine(String csv, String org) =>
      'Org,${org.isEmpty ? '(legacy local-only)' : org}\n$csv';

  /// Tight title: short weekday + day/month, time when known.
  String _sessionLabel(ClassRecord r) => sessionTightLabel(
      r.classLabel, r.dateIso, r.timestampIso);

  Future<void> _saveCsv(String csv, String filename) async {
    BleLog.log('NAV', 'export: save $filename');
    await saveCsvToDevice(context, csv, filename);
  }

  Future<void> _shareCsv(String csv, String subject) async {
    BleLog.log('NAV', 'export: share $subject');
    await shareCsvText(csv, subject);
  }

  /// Shared preview dialog: Close + Save + Share (see csv_preview.dart).
  Future<void> _showCsvDialog(
      {required String title,
      required String csv,
      required String filename,
      required String subject}) async {
    if (!mounted) return;
    await showCsvPreviewDialog(
      context,
      title: title,
      csv: csv,
      onSave: () => _saveCsv(csv, filename),
      onShare: () => _shareCsv(csv, subject),
    );
  }

  Future<void> _exportSession(ClassRecord r) async {
    final csv = withOrgLine(r.toCsv(), r.org);
    await _showCsvDialog(
      title: _sessionLabel(r),
      csv: csv,
      filename:
          'attendance_${r.classLabel}_${r.dateIso}_${r.id.substring(0, r.id.length.clamp(0, 8))}.csv',
      subject: 'Attendance ${r.classLabel} ${r.dateIso}',
    );
  }

  Future<void> _exportRange(List<ClassRecord> sessions) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2),
      initialDateRange: DateTimeRange(
        start: now.subtract(const Duration(days: 30)),
        end: now,
      ),
    );
    if (picked == null || !mounted) return;
    final inRange =
        sessionsInRange(sessions, dateIsoOf(picked.start), dateIsoOf(picked.end));
    final rangeLabel =
        '${shortDayDateOf(dateIsoOf(picked.start))} … ${shortDayDateOf(dateIsoOf(picked.end))}';
    if (inRange.isEmpty) {
      setState(
          () => _rangeError = 'No classes took place in $rangeLabel.');
      return;
    }
    setState(() => _rangeError = null);
    // Matrix: rows keyed by email, P = intersection-present else A;
    // same-day repeats disambiguate with HH:mm in the header.
    final org = inRange.isNotEmpty ? inRange.first.org : '';
    final csv = withOrgLine(buildDateRangeMatrix(inRange), org);
    await _showCsvDialog(
      title: '${widget.courseName} · $rangeLabel',
      csv: csv,
      filename:
          'attendance_${widget.courseName}_${dateIsoOf(picked.start)}_${dateIsoOf(picked.end)}.csv',
      subject:
          'Attendance ${widget.courseName} ${dateIsoOf(picked.start)}-${dateIsoOf(picked.end)}',
    );
  }

  void _openLog() {
    BleLog.log('NAV', 'export → system log');
    showLogDrawer(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final store = ref.watch(deviceStoreProvider);
    final acct = ref.watch(accountProvider).valueOrNull;
    final myOrg = (acct?.org ?? '').trim().toLowerCase();
    return AdaptiveScaffold(
      title: 'Export · ${widget.courseName}',
      actions: [
        IconButton(
          icon: const Icon(Icons.terminal_outlined),
          tooltip: 'System log',
          onPressed: _openLog,
        ),
      ],
      body: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: ProxSpacing.maxContentWidth),
          child: FutureBuilder<List<ClassRecord>>(
            future: store.readHistory(),
            builder: (context, snap) {
              final sessions =
                  _sessions(snap.data ?? const <ClassRecord>[], myOrg);
              return ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: ProxSpacing.screenMargin,
                  vertical: ProxSpacing.lg,
                ),
                children: [
                  const ClockHeader(),
                  const WebRecordsBanner(),
                  const SizedBox(height: ProxSpacing.sm),
                  ProxSecondaryButton(
                    icon: const Icon(Icons.calendar_month),
                    label: const Text('Export date range'),
                    onPressed: sessions.isEmpty
                        ? null
                        : () => _exportRange(sessions),
                    expanded: true,
                  ),
                  if (_rangeError != null) ...[
                    const SizedBox(height: ProxSpacing.sm),
                    ProxErrorNote(_rangeError!),
                  ],
                  const SizedBox(height: ProxSpacing.sm),
                  Text(
                    '${sessions.length} sessions',
                    style: proxTabular(
                        context, ProxType.label(color: c.contentPrimary)),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  DetailsExpander(
                    title: 'Details',
                    child: Text(
                      'Rows key by email. P means present in every round, else A. Same-day repeats add the time.',
                      style: ProxType.caption(color: c.contentSecondary),
                    ),
                  ),
                  const SizedBox(height: ProxSpacing.sm),
                  if (snap.connectionState == ConnectionState.waiting)
                    const Center(child: CircularProgressIndicator())
                  else if (sessions.isEmpty)
                    const ProxEmptyState(
                      message: 'No sessions yet for this course.',
                    )
                  else
                    for (final session in sessions)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: ProxSpacing.sm),
                        child: _ExportRow(
                          title: _sessionLabel(session),
                          subtitle:
                              '${fullDateOf(session.dateIso)}\n${session.presentCount} present · ${session.windowCount} window${session.windowCount == 1 ? '' : 's'}',
                          onTap: () => _exportSession(session),
                          onExport: () => _exportSession(session),
                        ),
                      ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ExportRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback onExport;
  const _ExportRow(
      {required this.title,
      required this.subtitle,
      required this.onTap,
      required this.onExport});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: ProxSpacing.minTap),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: ProxRadii.cardSpecRadius,
        border: Border.all(color: c.divider),
        boxShadow: [c.elevationRaised],
      ),
      child: InkWell(
        borderRadius: ProxRadii.cardSpecRadius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(ProxSpacing.cardPadding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: ProxType.body(color: c.contentPrimary),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: ProxType.caption(color: c.contentSecondary),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: 'Export CSV',
                onPressed: onExport,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
