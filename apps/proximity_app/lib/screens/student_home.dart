// Student flow: manual join (IP shown by professor; BLE discovery lands
// with the radio slice) → real face scan → 30s listening radar → signed
// ACK. Foreground-required; backgrounding pauses. Identical Android/iOS.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_transport/transport.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/ble_radio.dart';
import '../core/student_driver.dart';
import '../main.dart';
import '../mode.dart';
import '../widgets/animated.dart';
import '../widgets/clock.dart';
import 'face_capture.dart';

enum StudentPhase {
  browsing,
  waiting,
  faceCheck,
  listening,
  marked,
  late,
  needsReview,
  noSignal,
  paused,
}

class StudentHomeScreen extends ConsumerStatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  ConsumerState<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends ConsumerState<StudentHomeScreen>
    with WidgetsBindingObserver {
  StudentPhase phase = StudentPhase.browsing;
  double listenProgress = 0;
  String ackDetail = '';
  String infoDetail = '';
  String joinError = '';
  final _hostCtrl = TextEditingController();
  final _listener = ClassListener();
  List<LiveClass> _live = [];
  ClassBeacon? _waitingTarget;
  int _runId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listener.onChange = () {
      if (!mounted) return;
      final live = _listener.live();
      // Auto-advance: the professor opened the window we are waiting for.
      final waiting = _waitingTarget;
      if (phase == StudentPhase.waiting && waiting != null) {
        final flipped = live.any((c) =>
            '${c.last.host}:${c.last.port}' ==
                '${waiting.host}:${waiting.port}' &&
            c.last.windowOpen);
        if (flipped) {
          _joinBeacon(waiting);
          return;
        }
      }
      if (phase == StudentPhase.browsing) {
        setState(() => _live = live);
      }
    };
    _listener.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _runId++;
    _setWake(false);
    _listener.stop();
    _hostCtrl.dispose();
    super.dispose();
  }

  /// Best-effort wakelock, never awaited (see take_attendance.dart).
  void _setWake(bool on) {
    Future.microtask(() async {
      try {
        if (on) {
          await WakelockPlus.enable();
        } else {
          await WakelockPlus.disable();
        }
      } catch (_) {}
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground-required UX on all OS: backgrounding pauses proving.
    if (state != AppLifecycleState.resumed &&
        (phase == StudentPhase.listening || phase == StudentPhase.faceCheck)) {
      _runId++;
      if (mounted) setState(() => phase = StudentPhase.paused);
    }
  }

  ClassBeacon? _parseTarget() {
    final raw = _hostCtrl.text.trim();
    if (raw.isEmpty) return null;
    var host = raw;
    var port = 8443;
    if (raw.contains(':')) {
      final parts = raw.split(':');
      host = parts.first.trim();
      port = int.tryParse(parts.last.trim()) ?? 8443;
    }
    if (host.isEmpty) return null;
    return ClassBeacon(
        classLabel: 'Class at $host',
        host: host,
        port: port,
        rssiDbm: 0,
        displayCode: '···');
  }

  Future<void> _join() async {
    final target = _parseTarget();
    if (target == null) {
      setState(() => joinError = 'Enter the professor IP shown in class.');
      return;
    }
    await _joinBeacon(target);
  }

  Future<void> _joinBeacon(ClassBeacon target) async {
    final linked = ref.read(linkedIdentityProvider);
    if (linked == null) {
      setState(
          () => joinError = 'Enroll this device first — identity is required.');
      return;
    }
    if (!await ref.read(blePermissionProvider)()) {
      setState(() => joinError =
          'Bluetooth permission is required for proximity proofs. Enable it in Settings and rejoin.');
      return;
    }
    if (await ref.read(btPowerProvider)() != BtState.on) {
      final enabled = await requestEnableBluetooth();
      if (!enabled || await ref.read(btPowerProvider)() != BtState.on) {
        setState(() =>
            joinError = 'Bluetooth is off — turn it on to join the class.');
        return;
      }
    }
    setState(() {
      joinError = '';
      phase = StudentPhase.faceCheck;
    });
  }

  Future<void> _scanFace(ClassBeacon target, LinkedIdentity linked) async {
    final bytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => const FaceCaptureScreen()),
    );
    if (bytes == null || !mounted) return;
    final score = await ref.read(studentDriverProvider).checkFace(bytes);
    if (!mounted) return;
    if (score == null) {
      setState(() => phase = StudentPhase.needsReview);
      return;
    }
    _listen(target, linked, score);
  }

  Future<void> _listen(
      ClassBeacon target, LinkedIdentity linked, double faceScore) async {
    final run = ++_runId;
    _setWake(true);
    setState(() {
      phase = StudentPhase.listening;
      listenProgress = 0;
    });
    final receipt = await ref.read(studentDriverProvider).listenAndProve(
          target: target,
          identity: linked,
          faceScore: faceScore,
          onProgress: (p) {
            if (mounted && run == _runId) {
              setState(() => listenProgress = p);
            }
          },
          hearChallenge: () => ref.read(bleEngineProvider).nextChallenge(),
        );
    if (!mounted || run != _runId) return;
    _setWake(false);
    setState(() {
      ackDetail = receipt.detail;
      phase = switch (receipt.result) {
        StudentResult.marked => StudentPhase.marked,
        StudentResult.late => StudentPhase.late,
        StudentResult.faceFailed => StudentPhase.needsReview,
        StudentResult.noSignal => StudentPhase.noSignal,
        StudentResult.error => StudentPhase.noSignal,
      };
      if (receipt.result == StudentResult.error) {
        infoDetail = receipt.detail;
      }
    });
  }

  Widget _browsing(
      BuildContext context, LinkedIdentity? linked, String identityLine) {
    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: ClockHeader(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child:
              Text(identityLine, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _hostCtrl,
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(
                    labelText: 'Professor IP',
                    hintText: '192.168.43.1',
                    helperText: 'Shown by the professor in class.',
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _join(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _join,
                child: const Text('Join'),
              ),
            ],
          ),
        ),
        if (joinError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(joinError,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Live on this WiFi',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
        if (_live.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Text(
                'No live classes heard yet. Stay on the classroom WiFi — professors appear here when they start hosting.'),
          )
        else
          for (final c in _live)
            ListTile(
              leading: Icon(
                c.last.windowOpen ? Icons.radio : Icons.radio_button_checked,
                color: c.last.windowOpen ? Colors.green : null,
              ),
                    title: Text(c.last.classLabel),
                    subtitle: Text(
                      [
                        if (c.last.prof.isNotEmpty) c.last.prof,
                        c.last.host,
                        if (c.last.display.isNotEmpty)
                          'Code ${c.last.display}',
                      ].join(' · '),
                    ),
              trailing: c.last.windowOpen
                  ? const Icon(Icons.chevron_right)
                  : const Text('idle'),
              enabled: true,
              onTap: () {
                final target = ClassBeacon(
                  classLabel: c.last.classLabel,
                  host: c.last.host,
                  port: c.last.port,
                  rssiDbm: 0,
                  displayCode: c.last.display,
                );
                _hostCtrl.text = '${c.last.host}:${c.last.port}';
                if (c.last.windowOpen) {
                  _joinBeacon(target);
                } else {
                  setState(() {
                    _waitingTarget = target;
                    joinError = '';
                    phase = StudentPhase.waiting;
                  });
                }
              },
            ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
              'Keep app in foreground. Backgrounding shows Paused — reopen.'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final linked = ref.watch(linkedIdentityProvider);
    final identityLine = linked == null
        ? 'Not enrolled — enroll this device to link identity.'
        : '${linked.name}${linked.roll.isNotEmpty ? ' · ${linked.roll}' : ''}\n${linked.gmail}';
    final target = _parseTarget();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Back never exits mid-flow: inner phases return to browsing,
        // browsing returns to the mode hub.
        if (phase == StudentPhase.browsing) {
          setMode(ref, AppMode.unset);
        } else {
          _runId++;
          setState(() {
            _waitingTarget = null;
            phase = StudentPhase.browsing;
          });
        }
      },
      child: AdaptiveScaffold(
        title: 'Student — Join class',
        actions: [
          IconButton(
            icon: const Icon(Icons.switch_account),
            tooltip: 'Switch mode',
            onPressed: () => setMode(ref, AppMode.unset),
          ),
        ],
        body: switch (phase) {
          StudentPhase.browsing => _browsing(context, linked, identityLine),
          StudentPhase.waiting => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.hourglass_top, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    'Attendance has not yet started for\n${_waitingTarget?.classLabel ?? 'this class'}.\nKeep this open — you will continue automatically.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => setState(() {
                      _waitingTarget = null;
                      phase = StudentPhase.browsing;
                    }),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          StudentPhase.faceCheck => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FaceOval(progress: 1.0, prompt: target?.displayCode ?? '···'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.face),
                    label: const Text('Scan face'),
                    onPressed: target == null || linked == null
                        ? null
                        : () => _scanFace(target, linked),
                  ),
                ],
              ),
            ),
          StudentPhase.listening => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadarSweep(progress: listenProgress),
                  const SizedBox(height: 12),
                  Text(
                      'Listening 00:${(30 * (1 - listenProgress)).round().toString().padLeft(2, '0')}'),
                ],
              ),
            ),
          StudentPhase.marked => Center(
              child: MarkedBadge(detail: ackDetail),
            ),
          StudentPhase.late => Center(
              child: MarkedBadge(detail: ackDetail, title: 'Late'),
            ),
          StudentPhase.needsReview => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Face check failed — see professor for review.'),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () =>
                        setState(() => phase = StudentPhase.browsing),
                    child: const Text('Back'),
                  ),
                ],
              ),
            ),
          StudentPhase.noSignal => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bluetooth_disabled, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    infoDetail.isNotEmpty ? infoDetail : ackDetail,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () =>
                        setState(() => phase = StudentPhase.browsing),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          StudentPhase.paused => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Paused — reopen'),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () =>
                        setState(() => phase = StudentPhase.browsing),
                    child: const Text('Back to join'),
                  ),
                ],
              ),
            ),
        },
      ),
    );
  }
}
