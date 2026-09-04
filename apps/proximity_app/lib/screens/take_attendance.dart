// Live attendance for one course instance: host (advertise on WiFi so
// students see the class) → Start #1/#2 (30s BLE+HTTPS windows) → End +
// Export (signed CSV, on-device history). Back always ends hosting first,
// so no window is ever orphaned.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_storage/storage.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/ble_radio.dart';
import '../core/device_store.dart';
import '../core/host_driver.dart';
import '../main.dart';
import '../mode.dart';
import '../widgets/animated.dart';
import '../widgets/clock.dart';

class TakeAttendanceScreen extends ConsumerStatefulWidget {
  final String courseName;
  final bool autoStart;
  const TakeAttendanceScreen(
      {super.key, required this.courseName, this.autoStart = false});

  @override
  ConsumerState<TakeAttendanceScreen> createState() =>
      _TakeAttendanceScreenState();
}

class _TakeAttendanceScreenState extends ConsumerState<TakeAttendanceScreen> {
  final TallyStore _fallbackTally = TallyStore();
  bool hosting = false;
  bool live = false;
  Duration remaining = const Duration(seconds: 30);
  Timer? _t;
  String search = '';
  String? exportCsv;
  String? serverLine;
  String? serverError;
  final _nameCtrl = TextEditingController();

  TallyStore get tally {
    try {
      return ref.read(hostDriverProvider).tally;
    } catch (_) {
      return _fallbackTally;
    }
  }

  @override
  void initState() {
    super.initState();
    _host();
    _loadName();
  }

  /// Prefills the professor display name (linked identity, else last saved).
  Future<void> _loadName() async {
    var name = ref.read(linkedIdentityProvider)?.name ?? '';
    try {
      final saved =
          await ref.read(deviceStoreProvider).readHostName();
      if (saved.isNotEmpty) name = saved;
    } catch (_) {}
    if (mounted && _nameCtrl.text.isEmpty && name.isNotEmpty) {
      setState(() => _nameCtrl.text = name);
    }
  }

  Future<void> _host() async {
    HostSession session;
    try {
      session = await ref
          .read(hostDriverProvider)
          .startHosting(classLabel: widget.courseName);
    } catch (e) {
      if (!mounted) return;
      setState(() => serverError = '$e');
      return;
    }
    if (!mounted) return;
    setState(() {
      hosting = true;
      serverError = null;
      serverLine = session.addressLine;
    });
    if (widget.autoStart) _start(1);
  }

  @override
  void dispose() {
    _t?.cancel();
    _nameCtrl.dispose();
    _setWake(false);
    try {
      ref.read(hostDriverProvider).stopWindow();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _leave() async {
    try {
      await ref.read(hostDriverProvider).endHosting();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _start(int windowNo) async {
    ref.read(windowNoProvider.notifier).state = windowNo;
    if (!await ref.read(blePermissionProvider)()) {
      if (!mounted) return;
      setState(() => serverError =
          'Bluetooth permission is required to host. Enable it in Settings.');
      return;
    }
    if (!await _ensureBt()) return;
    HostSession session;
    try {
      session = await ref.read(hostDriverProvider).startWindow(windowNo);
    } catch (e) {
      if (!mounted) return;
      setState(() => serverError = '$e');
      return;
    }
    if (!mounted) return;
    // Keep the screen awake for the 30s live window on all OS.
    _setWake(true);
    setState(() {
      live = true;
      remaining = const Duration(seconds: 30);
      exportCsv = null;
      serverError = null;
      serverLine = session.addressLine;
    });
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => remaining -= const Duration(seconds: 1));
      if (remaining.inSeconds <= 0) {
        t.cancel();
        setState(() => live = false);
        _setWake(false);
        try {
          ref.read(hostDriverProvider).stopWindow();
        } catch (_) {}
        _saveSnapshot();
      }
    });
  }

  /// Best-effort wakelock: fire-and-forget so a hung platform channel can
  /// never stall the attendance flow (caught once in widget tests).
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

  /// Powers Bluetooth on when it is off (Android system prompt).
  /// Returns false with an inline error when radio stays unavailable.
  Future<bool> _ensureBt() async {
    final state = await ref.read(btPowerProvider)();
    if (state == BtState.on) return true;
    if (state == BtState.off) {
      final enabled = await requestEnableBluetooth();
      if (enabled && await ref.read(btPowerProvider)() == BtState.on) {
        return true;
      }
      if (!mounted) return false;
      setState(() =>
          serverError = 'Bluetooth is off — turn it on to start the window.');
      return false;
    }
    if (!mounted) return false;
    setState(() =>
        serverError = 'Bluetooth unavailable on this device — cannot host.');
    return false;
  }

  Future<void> _export() async {
    try {
      final csv = tally.exportCsv(
          classLabel: widget.courseName, dateIso: dateIsoOf(DateTime.now()));
      final sig = await ref.read(hostDriverProvider).signExport(csv);
      if (!mounted) return;
      setState(() => exportCsv = '$csv\n-- sig:$sig');
      await _saveSnapshot();
      await ref.read(hostDriverProvider).endHosting();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => serverError = '$e');
    }
  }

  /// Persist the finished tally to on-device class history.
  Future<void> _saveSnapshot() async {
    try {
      await ref.read(deviceStoreProvider).appendHistory(
            tally.toClassRecord(
              courseId: widget.courseName,
              classLabel: widget.courseName,
              dateIso: dateIsoOf(DateTime.now()),
            ),
          );
    } catch (_) {
      // History is best-effort; live tally + export are unaffected.
    }
  }

  @override
  Widget build(BuildContext context) {
    final linked = ref.watch(linkedIdentityProvider);
    final present = tally.presentCount;
    final rows = search.isEmpty ? tally.present : tally.search(search);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: AdaptiveScaffold(
        title: widget.courseName,
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const ClockHeader(),
            if (!hosting && serverError == null) ...[
              const SizedBox(height: 8),
              const Text('Starting host…'),
            ],
            if (hosting && !live) ...[
              const SizedBox(height: 8),
              const Text(
                  'Advertising on WiFi — students can see this class now. Tap Start when ready.'),
              const SizedBox(height: 8),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Your name (optional, shown to students)',
                ),
                onChanged: (v) {
                  try {
                    ref.read(hostDriverProvider).setDisplayName(v);
                  } catch (_) {}
                },
              ),
            ],
            if (serverLine != null) ...[
              const SizedBox(height: 4),
              Text(serverLine!, style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (serverError != null) ...[
              const SizedBox(height: 4),
              Text(serverError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                CountdownRing(
                  total: const Duration(seconds: 30),
                  remaining: remaining,
                  centerLabel:
                      '00:${remaining.inSeconds.toString().padLeft(2, '0')}',
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PresentTicker(present: present, total: 480),
                      if (linked != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                              'Host: ${linked.name}${linked.roll.isNotEmpty ? ' · ${linked.roll}' : ''}',
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton(
                            onPressed:
                                (live || !hosting) ? null : () => _start(1),
                            child: const Text('Start #1'),
                          ),
                          FilledButton(
                            onPressed:
                                (live || !hosting) ? null : () => _start(2),
                            child: const Text('Start #2'),
                          ),
                          OutlinedButton(
                            onPressed: (live || !hosting) ? null : _export,
                            child: const Text('End + Export'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(
                  labelText: 'Search by name, ID, or email',
                  prefixIcon: Icon(Icons.search)),
              onChanged: (v) => setState(() => search = v),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < rows.length; i++)
              AnimatedContainer(
                duration: Duration(milliseconds: 200 + i * 40),
                curve: Curves.easeOut,
                child: ListTile(
                  leading: const Icon(Icons.check_circle, color: Colors.green),
                  title: Text(rows[i].name),
                  subtitle: Text(rows[i].roll.isNotEmpty
                      ? '${rows[i].roll} · ${rows[i].email}'
                      : rows[i].email),
                ),
              ),
            if (exportCsv != null) ...[
              const SizedBox(height: 16),
              SelectableText(exportCsv!),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.ios_share),
                label: const Text('Share CSV'),
                onPressed: () => SharePlus.instance.share(ShareParams(
                  text: exportCsv!,
                  subject: 'Attendance ${widget.courseName}',
                )),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
