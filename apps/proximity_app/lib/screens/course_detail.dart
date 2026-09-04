// One course: take attendance for a new instance on top, previous
// sessions below (most recent first), each exportable.
// (A cross-date matrix export per course lands later per plan.)
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_storage/storage.dart';
import 'package:share_plus/share_plus.dart';

import '../core/device_store.dart';
import '../main.dart';
import '../widgets/clock.dart';
import 'take_attendance.dart';

class CourseDetailScreen extends ConsumerStatefulWidget {
  final String courseName;
  const CourseDetailScreen({super.key, required this.courseName});

  @override
  ConsumerState<CourseDetailScreen> createState() => _CourseDetailScreenState();
}

class _CourseDetailScreenState extends ConsumerState<CourseDetailScreen> {
  final _renameCtrl = TextEditingController();
  String? _notice;

  @override
  void dispose() {
    _renameCtrl.dispose();
    super.dispose();
  }

  Future<void> _rename() async {
    _renameCtrl.text = widget.courseName;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit course'),
        content: TextField(
          controller: _renameCtrl,
          decoration: const InputDecoration(labelText: 'Course name'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_renameCtrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (picked == null || picked.isEmpty || picked == widget.courseName) {
      return;
    }
    final ok = await ref
        .read(deviceStoreProvider)
        .renameCourse(widget.courseName, picked);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(); // back to the refreshed course list
    } else {
      setState(
          () => _notice = 'Name unchanged — empty or already used.');
    }
  }

  List<ClassRecord> _sessions(List<ClassRecord> history) {
    final out = history
        .where((r) =>
            r.courseId == widget.courseName ||
            (r.courseId.isEmpty && r.classLabel == widget.courseName))
        .toList()
      ..sort((a, b) => b.dateIso.compareTo(a.dateIso));
    return out;
  }

  Future<void> _takeAttendance({bool autoStart = false}) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TakeAttendanceScreen(
            courseName: widget.courseName, autoStart: autoStart)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(deviceStoreProvider);
    return AdaptiveScaffold(
      title: widget.courseName,
      actions: [
        IconButton(
          icon: const Icon(Icons.edit),
          tooltip: 'Edit course',
          onPressed: _rename,
        ),
      ],
      body: FutureBuilder<List<ClassRecord>>(
        future: store.readHistory(),
        builder: (context, snap) {
          final sessions = _sessions(snap.data ?? const <ClassRecord>[]);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const ClockHeader(),
              const SizedBox(height: 8),
              FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Take attendance'),
                onPressed: _takeAttendance,
              ),
              if (_notice != null) ...[
                const SizedBox(height: 8),
                Text(_notice!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 8),
              if (snap.connectionState == ConnectionState.waiting)
                const Center(child: CircularProgressIndicator())
              else if (sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    'No sessions yet for this course.',
                    textAlign: TextAlign.center,
                  ),
                )
              else
                for (var i = 0; i < sessions.length; i++)
                  _session(context, sessions[i], i),
            ],
          );
        },
      ),
    );
  }

  Widget _session(BuildContext context, ClassRecord r, int i) {
    return AnimatedContainer(
      duration: Duration(milliseconds: 200 + i * 40),
      curve: Curves.easeOut,
      child: Card(
        child: ListTile(
          title: Text('${r.classLabel} · ${r.dateIso}'),
          subtitle: Text('W1 ${r.w1Count} · W2 ${r.w2Count} present'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: 'Export CSV',
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text('${r.classLabel} · ${r.dateIso}'),
                    content: SingleChildScrollView(
                      child: SelectableText(r.toCsv()),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                      FilledButton.icon(
                        icon: const Icon(Icons.ios_share),
                        label: const Text('Share'),
                        onPressed: () => SharePlus.instance.share(ShareParams(
                          text: r.toCsv(),
                          subject:
                              'Attendance ${r.classLabel} ${r.dateIso}',
                        )),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Retake attendance',
                onPressed: () => _takeAttendance(autoStart: true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
