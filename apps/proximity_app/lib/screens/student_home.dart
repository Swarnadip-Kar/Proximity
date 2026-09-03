// Student flow: nearby-class list (RSSI-sorted) → face oval → listening
// (30s radar/countdown) → ✓ Marked on signed ACK. Identical Android/iOS.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_transport/transport.dart';

import '../main.dart';
import '../mode.dart';
import '../widgets/animated.dart';
enum StudentPhase { browsing, faceCheck, listening, marked, needsReview, paused }

class StudentHomeScreen extends ConsumerStatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  ConsumerState<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends ConsumerState<StudentHomeScreen>
    with WidgetsBindingObserver {
  StudentPhase phase = StudentPhase.browsing;
  double faceProgress = 0;
  double listenProgress = 0;
  String ackDetail = '';
  Timer? _t;
  List<ClassBeacon> beacons = [
    ClassBeacon(
        classLabel: 'CS201-Room301',
        host: '192.168.43.1',
        port: 8443,
        rssiDbm: -55,
        displayCode: 'KQ7'),
    ClassBeacon(
        classLabel: 'CS202-Room302',
        host: '192.168.43.2',
        port: 8443,
        rssiDbm: -72,
        displayCode: 'AX2'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _t?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground-required UX on all OS: backgrounding pauses proving.
    if (state != AppLifecycleState.resumed &&
        (phase == StudentPhase.listening ||
            phase == StudentPhase.faceCheck)) {
      setState(() => phase = StudentPhase.paused);
      _t?.cancel();
    }
  }

  void _join(ClassBeacon b) {
    setState(() {
      phase = StudentPhase.faceCheck;
      faceProgress = 0;
    });
    _t?.cancel();
    _t = Timer.periodic(const Duration(milliseconds: 100), (t) {
      setState(() => faceProgress += 0.1);
      if (faceProgress >= 1.0) {
        t.cancel();
        _startListening(b);
      }
    });
  }

  void _startListening(ClassBeacon b) {
    setState(() {
      phase = StudentPhase.listening;
      listenProgress = 0;
    });
    var elapsedSec = 0;
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      elapsedSec += 1;
      setState(() => listenProgress = elapsedSec / 30);
      if (elapsedSec >= 30) {
        t.cancel();
        // P0: fake signed ACK (real Sig_pAck verify lands with transport).
        setState(() {
          phase = StudentPhase.marked;
          ackDetail = '${b.displayCode} · 10:04:12';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final linked = ref.watch(linkedIdentityProvider);
    final identityLine = linked == null
        ? 'Not enrolled — enroll this device to link identity.'
        : '${linked.name}${linked.roll.isNotEmpty ? ' · ${linked.roll}' : ''}\n${linked.gmail}';
    return AdaptiveScaffold(
      title: 'Student — Nearby classes',
      actions: [
        IconButton(
          icon: const Icon(Icons.switch_account),
          tooltip: 'Switch mode',
          onPressed: () =>
              ref.read(appModeProvider.notifier).state = AppMode.unset,
        ),
      ],
      body: switch (phase) {
        StudentPhase.browsing => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(identityLine,
                    style: Theme.of(context).textTheme.bodyMedium),
              ),
              for (final b in sortBeaconsByRssi(beacons))
                ListTile(
                  leading: const Icon(Icons.bluetooth),
                  title: Text(b.classLabel),
                  subtitle: Text('${b.rssiDbm} dBm · ${b.displayCode}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _join(b),
                ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                    'Keep app in foreground. Backgrounding shows Paused — reopen.'),
              ),
            ],
          ),
        StudentPhase.faceCheck => Center(
            child: FaceOval(progress: faceProgress, prompt: 'blink'),
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
        StudentPhase.needsReview => const Center(
            child: Text('Face check failed — see professor for review.'),
          ),
        StudentPhase.paused => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Paused — reopen'),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: null,
                  child: Text('Resume'),
                ),
              ],
            ),
          ),
      },
    );
  }
}
