// Review/export of the past for one course: per-session CSV
// preview/share/save plus the calendar date-range matrix export (email
// primary key, P/A per session). Split out of the old course page so the
// overview stays about managing the course. Export is allowed on web
// records builds (Save downloads in-browser); only the Live tab runs the
// room capture, which is never referenced here.
//
// Selection is tap-to-select (no hold needed): tapping a row toggles it,
// the trailing share icon previews that one session, and the bottom
// toolbar exports the tapped set as one combined matrix. Web builds keep
// tap-to-preview (no multi-select on web records builds).
//
// Data logic preserved per the Phase-1 exemption (filter, sort, CSV bytes,
// filenames, matrix builder): restyle only.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
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
import '../../widgets/partial_list.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_shimmer.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/selection_controller.dart';
import '../../widgets/selection_toolbar.dart';
import '../../widgets/web_banner.dart';
import 'session_row_card.dart';

/// Export header for CSV previews: ONE metadata line —
/// `<prof>,<class>,<email>` — followed by the body CSV unchanged
/// (header row, then entries). Values come from the host
/// identity/account at export time (account displayName/email) and the
/// threaded course/class label; no new plumbing or transport fields.
/// Escaping/quoting is identical to the old org line and body (raw
/// interpolation, no quoting).
/// Shared by the export center and the course overview's selected-dates
/// export — one builder, identical bytes.
String exportHeader(String csv,
        {required String profName,
        required String className,
        required String profEmail}) =>
    '$profName,$className,$profEmail\n$csv';

class ExportCenterScreen extends ConsumerStatefulWidget {
  final String courseName;
  const ExportCenterScreen({super.key, required this.courseName});

  /// Canonical in-tab route name: `prof/courses/<course>/export`.
  /// Matches the IA node in `proxOnGenerateRoute` so NAV logs, `popUntil`
  /// by name/prefix, and deep-links share ONE identity with the named
  /// route (no duplicate unnamed push).
  static String routeName(String course) => 'prof/courses/$course/export';

  @override
  ConsumerState<ExportCenterScreen> createState() => _ExportCenterScreenState();
}

class _ExportCenterScreenState extends ConsumerState<ExportCenterScreen> {
  String? _rangeError;

  List<ClassRecord> _sessions(List<ClassRecord> history, String myOrg) {
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

  /// Export header for CSV previews: one `<prof>,<class>,<email>`
  /// top line (see [exportHeader]).
  /// Top-level (not on the private State) so the course overview's
  /// selected-dates export shares the exact builder.
  static String withExportHeader(String csv,
          {required String profName,
          required String className,
          required String profEmail}) =>
      exportHeader(csv,
          profName: profName, className: className, profEmail: profEmail);

  /// Tight title: short weekday + day/month, time when known.
  String _sessionLabel(ClassRecord r) =>
      sessionTightLabel(r.classLabel, r.dateIso, r.timestampIso);

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
    final acct = ref.read(accountProvider).valueOrNull;
    final csv = withExportHeader(
      r.toCsv(),
      profName: (acct?.displayName ?? '').trim(),
      className: r.classLabel,
      profEmail: (acct?.email ?? '').trim(),
    );
    await _showCsvDialog(
      title: _sessionLabel(r),
      csv: csv,
      filename:
          'attendance_${r.classLabel}_${r.dateIso}_${r.id.substring(0, r.id.length.clamp(0, 8))}.csv',
      subject: 'Attendance ${r.classLabel} ${r.dateIso}',
    );
  }

  /// Exports the tapped sessions as one combined matrix (same builder as
  /// the date-range export) in the shared CSV preview dialog. Selection
  /// stays armed afterwards so the professor can re-export without
  /// re-tapping.
  Future<void> _exportSelected(
      List<ClassRecord> sessions, Set<String> ids) async {
    final sel = sessions.where((s) => ids.contains(s.id)).toList()
      ..sort((a, b) => b.timestampIso.compareTo(a.timestampIso));
    if (sel.isEmpty || !mounted) return;
    final acct = ref.read(accountProvider).valueOrNull;
    final csv = withExportHeader(
      buildDateRangeMatrix(sel),
      profName: (acct?.displayName ?? '').trim(),
      className: widget.courseName,
      profEmail: (acct?.email ?? '').trim(),
    );
    final label =
        sel.length == 1 ? _sessionLabel(sel.first) : '${sel.length} sessions';
    BleLog.log('NAV', 'export ${widget.courseName} → selected $label');
    await showCsvPreviewDialog(
      context,
      title: '${widget.courseName} · $label',
      csv: csv,
      onSave: () =>
          _saveCsv(csv, 'attendance_${widget.courseName}_selected.csv'),
      onShare: () => _shareCsv(csv, 'Attendance ${widget.courseName} ($label)'),
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
    final startIso = dateIsoOf(picked.start);
    final endIso = dateIsoOf(picked.end);
    final inRange = sessionsInRange(sessions, startIso, endIso);
    final rangeLabel =
        '${shortDayDateOf(startIso)} … ${shortDayDateOf(endIso)}';
    if (inRange.isEmpty) {
      setState(() => _rangeError = 'No classes took place in $rangeLabel.');
      return;
    }
    setState(() => _rangeError = null);
    final acct = ref.read(accountProvider).valueOrNull;
    final csv = withExportHeader(
      buildDateRangeMatrix(inRange),
      profName: (acct?.displayName ?? '').trim(),
      className: widget.courseName,
      profEmail: (acct?.email ?? '').trim(),
    );
    await _showCsvDialog(
      title: '${widget.courseName} · $rangeLabel',
      csv: csv,
      filename: 'attendance_${widget.courseName}_${startIso}_$endIso.csv',
      subject: 'Attendance ${widget.courseName} $startIso-$endIso',
    );
  }

  void _openLog() {
    BleLog.log('NAV', 'export → system log');
    showLogDrawer(context);
  }

  @override
  Widget build(BuildContext context) {
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
              return SelectionScope(
                child: _ExportBody(
                  courseName: widget.courseName,
                  sessions: sessions,
                  loading: snap.connectionState == ConnectionState.waiting,
                  onPreviewSession: _exportSession,
                  onExportSelected: (ids) => _exportSelected(sessions, ids),
                  sessionLabel: _sessionLabel,
                  rangeError: _rangeError,
                  onExportRange: () => _exportRange(sessions),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Export list content inside one [SelectionScope]: rows are tap-to-select
/// (plain taps toggle, no hold needed — there is no detail to open here,
/// so tap never conflicts with navigation). The trailing share icon
/// previews that one session; the bottom toolbar exports the tapped set as
/// one combined matrix. Web builds have no multi-select: tap previews.
class _ExportBody extends ConsumerWidget {
  final String courseName;
  final List<ClassRecord> sessions;
  final bool loading;
  final ValueChanged<ClassRecord> onPreviewSession;
  final Future<void> Function(Set<String>) onExportSelected;
  final String Function(ClassRecord) sessionLabel;
  final String? rangeError;
  final Future<void> Function() onExportRange;

  const _ExportBody({
    required this.courseName,
    required this.sessions,
    required this.loading,
    required this.onPreviewSession,
    required this.onExportSelected,
    required this.sessionLabel,
    required this.rangeError,
    required this.onExportRange,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ProximityColors.of(context);
    final controller = ref.watch(selectionControllerProvider);
    final count = controller.count;
    // Tap-to-select is native-only; web keeps tap-to-preview.
    final tapSelect = !kIsWeb;
    final selecting = controller.selecting && !kIsWeb;
    final rangeErr = rangeError;
    // Floating Export date range docked above the nav bar (same pattern
    // as the course overview's floating Review & export dock). Hidden
    // while the selection toolbar owns the bottom edge. List bottom
    // padding keeps content clear of the dock.
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  ProxSpacing.screenMargin,
                  ProxSpacing.lg,
                  ProxSpacing.screenMargin,
                  104,
                ),
            children: [
              const ClockHeader(),
              const WebRecordsBanner(),
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
                  tapSelect
                      ? 'Tap sessions to select them for a combined export. The share icon previews one session. Rows key by email; P means present in every round, else A.'
                      : 'Rows key by email. P means present in every round, else A. Same-day repeats add the time.',
                  style: ProxType.caption(color: c.contentSecondary),
                ),
              ),
              if (tapSelect && sessions.isNotEmpty && !loading) ...[
                const SizedBox(height: ProxSpacing.xs),
                Text(
                  'Tap to select',
                  style: ProxType.caption(color: c.contentTertiary),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ],
              if (rangeErr != null) ...[
                const SizedBox(height: ProxSpacing.sm),
                ProxErrorNote(rangeErr),
              ],
              const SizedBox(height: ProxSpacing.sm),
              if (loading)
                const ProxShimmerHost(
                  child: Column(
                    children: [
                      ProxShimmerRow(),
                      SizedBox(height: ProxSpacing.sm),
                      ProxShimmerRow(),
                      SizedBox(height: ProxSpacing.sm),
                      ProxShimmerRow(),
                    ],
                  ),
                )
              else if (sessions.isEmpty)
                const ProxEmptyState(
                  message: 'No sessions yet for this course.',
                )
              else
                for (final session in sessions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: ProxSpacing.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Builder(
                            builder: (context) {
                              // Same shared row card as the course
                              // overview: callers differ only in title
                              // + tap behavior, never in card chrome.
                              final partial = partialCountOf(
                                  session.windows, session.allEmails);
                              final union = courseRoster(sessions).length;
                              final absent =
                                  (union - session.presentCount - partial)
                                      .clamp(0, 1 << 30);
                              // Date-only rows: no avatar, no course
                              // name — same shared card otherwise.
                              return SessionRowCard(
                                courseName: courseName,
                                showAvatar: false,
                                title: sessionShortLine(session),
                                windows: session.windowCount,
                                present: session.presentCount,
                                partial: partial,
                                absent: absent,
                                selectionMode: tapSelect,
                                selected: controller.isSelected(session.id),
                                onSelectionChanged: tapSelect
                                    ? (select) {
                                        if (select) {
                                          controller.select(session.id);
                                        } else {
                                          controller.deselect(session.id);
                                        }
                                      }
                                    : null,
                                onTap: tapSelect
                                    ? null
                                    : () => onPreviewSession(session),
                              );
                            },
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.ios_share),
                          tooltip: 'Export CSV',
                          onPressed: () => onPreviewSession(session),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
            SelectionToolbar(
              visible: selecting,
              selectedCount: count,
              totalCount: sessions.length,
              actions: [
                SelectionToolbarAction(
                  label: 'Export $count',
                  onPressed: count == 0
                      ? null
                      : () async {
                          await onExportSelected(controller.selectedIds);
                        },
                ),
              ],
              onSelectAll: () =>
                  controller.selectAll(sessions.map((s) => s.id)),
              onCancel: controller.clear,
            ),
          ],
        ),
        if (!selecting)
          Positioned(
            left: ProxSpacing.lg,
            right: ProxSpacing.lg,
            bottom: ProxSpacing.sm,
            child: SafeArea(
              top: false,
              child: ProxFloatingAction(
                child: ProxPrimaryButton(
                  icon: const Icon(Icons.calendar_month),
                  label: const Text('Export date range'),
                  onPressed:
                      sessions.isEmpty ? null : () => onExportRange(),
                  expanded: true,
                  compact: true,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
