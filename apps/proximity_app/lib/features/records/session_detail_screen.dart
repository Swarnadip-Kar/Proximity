// One saved session, read-only: present/partial counts plus the per-student
// round ticks. Tapped from the course overview; native professors branch to
// the editor (fix marks) or the export center (CSV) from here. Records-only:
// viewing past marks here; the room-capture entry lives on another tab.
//
// Data logic preserved per the Phase-1 exemption (intersection present,
// partials, ticks, reload): restyle only.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

import '../../core/device_store.dart';
import '../../design/app_theme.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/clock.dart';
import '../../widgets/log_drawer.dart';
import '../../widgets/partial_list.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/student_card.dart';
import '../../widgets/web_banner.dart';
import 'export_center_screen.dart';
import 'session_edit_screen.dart';

class SessionDetailScreen extends ConsumerStatefulWidget {
  final ClassRecord record;
  /// All of the course's sessions (union source for absent/partial context).
  final List<ClassRecord> courseSessions;
  const SessionDetailScreen(
      {super.key, required this.record, this.courseSessions = const []});

  @override
  ConsumerState<SessionDetailScreen> createState() =>
      _SessionDetailScreenState();
}

class _SessionDetailScreenState extends ConsumerState<SessionDetailScreen> {
  late ClassRecord _record;

  @override
  void initState() {
    super.initState();
    _record = widget.record;
  }

  List<String> get _persons {
    final out = <String>{
      for (final w in _record.windows) ...w.keys,
      ..._record.names.keys,
    }.toList()
      ..sort();
    return out;
  }

  /// Present = in every window (intersection semantics, same as exports).
  bool _isPresent(String email) {
    if (_record.windows.isEmpty) return false;
    for (final w in _record.windows) {
      if (w[email] != true) return false;
    }
    return true;
  }

  /// Per-round ticks for one student: 'R1 ✓ · R2 ✗'.
  String _ticksFor(String email) =>
      ticksForWindows(_record.windows, email);

  int _partialCount() =>
      partialCountOf(_record.windows, _record.allEmails);

  /// Re-reads this session after the editor saves (upsert keeps the id).
  Future<void> _reload() async {
    try {
      final history = await ref.read(deviceStoreProvider).readHistory();
      for (final r in history) {
        if (r.id == _record.id && mounted) {
          setState(() => _record = r);
          return;
        }
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _openEdit() async {
    BleLog.log('NAV', 'session ${_record.dateIso} → edit');
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => SessionEditScreen(
              record: _record, courseSessions: widget.courseSessions)),
    );
    if (saved == true) await _reload();
    if (mounted) setState(() {});
  }

  void _openExport() {
    final course = _record.courseId.isNotEmpty
        ? _record.courseId
        : _record.classLabel;
    BleLog.log('NAV', 'session ${_record.dateIso} → export');
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ExportCenterScreen(courseName: course)));
  }

  void _openLog() {
    BleLog.log('NAV', 'session → system log');
    showLogDrawer(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final persons = _persons;
    final present = persons.where(_isPresent).length;
    final partials = _partialCount();
    final time = shortTimeOf(_record.timestampIso);
    return AdaptiveScaffold(
      title: 'Session',
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
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: ProxSpacing.screenMargin,
              vertical: ProxSpacing.lg,
            ),
            children: [
              Text(
                '${_record.classLabel} · ${fullDateOf(_record.dateIso)}'
                '${time.isEmpty ? '' : ' · $time'}',
                style: ProxType.title(color: c.contentPrimary),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
              const SizedBox(height: ProxSpacing.xs),
              Text(
                '$present present · ${persons.length} listed'
                '${partials > 0 ? ' · Partial ($partials)' : ''}',
                style: proxTabular(
                    context, ProxType.label(color: c.contentSecondary)),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              if (kIsWeb) ...[
                const SizedBox(height: ProxSpacing.sm),
                const WebRecordsBanner(),
              ],
              const SizedBox(height: ProxSpacing.sm),
              if (!kIsWeb)
                ProxPrimaryButton(
                  icon: const Icon(Icons.edit),
                  label: const Text('Fix marks'),
                  onPressed: _openEdit,
                ),
              if (!kIsWeb) const SizedBox(height: ProxSpacing.sm),
              ProxSecondaryButton(
                icon: const Icon(Icons.ios_share),
                label: const Text('Export CSV'),
                onPressed: _openExport,
                expanded: true,
              ),
              const SizedBox(height: ProxSpacing.md),
              const ProxSectionHeader(
                title: 'Attendance',
                padding: EdgeInsets.zero,
              ),
              if (persons.isEmpty)
                const ProxEmptyState(message: 'Nobody listed in this session.')
              else
                for (final email in persons)
                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: ProxSpacing.sm),
                    child: StudentCard(
                      name: _record.names[email] ?? email,
                      subtitle:
                          '${_ticksFor(email)} · ${rosterSubtitle(_record.rolls[email] ?? '', email)}',
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
