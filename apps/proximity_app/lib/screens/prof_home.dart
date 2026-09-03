// Professor flow (identical phone/laptop): start/end, LIVE ring, animated
// ticker, present/pending/face-flag/late lists w/ staggered entry, search,
// export with share sheet (host-only source of truth).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_storage/storage.dart';

import '../main.dart';
import '../mode.dart';
import '../widgets/animated.dart';

class ProfHomeScreen extends ConsumerStatefulWidget {
  const ProfHomeScreen({super.key});

  @override
  ConsumerState<ProfHomeScreen> createState() => _ProfHomeScreenState();
}

class _ProfHomeScreenState extends ConsumerState<ProfHomeScreen> {
  final TallyStore tally = TallyStore();
  bool live = false;
  Duration remaining = const Duration(seconds: 30);
  Timer? _t;
  String search = '';
  String? exportCsv;

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  void _start(int windowNo) {
    ref.read(windowNoProvider.notifier).state = windowNo;
    setState(() {
      live = true;
      remaining = const Duration(seconds: 30);
      exportCsv = null;
    });
    // Demo marks (real BLE+POST tally lands with transport in P0 loop).
    // Identity is account-linked: name+email come from Gmail, professor
    // sees both per row.
    tally.mark('aarav@institute.ac.in', 'Aarav S', windowNo);
    tally.mark('diya@institute.ac.in', 'Diya R', windowNo);
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => remaining -= const Duration(seconds: 1));
      if (remaining.inSeconds <= 0) {
        t.cancel();
        setState(() => live = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = ref.watch(classLabelProvider);
    final linked = ref.watch(linkedIdentityProvider);
    final present = tally.presentCount;
    final rows = search.isEmpty
        ? tally.present
        : tally.search(search);
    return AdaptiveScaffold(
      title: 'Prof — $label',
      actions: [
        IconButton(
          icon: const Icon(Icons.switch_account),
          tooltip: 'Switch mode',
          onPressed: () =>
              ref.read(appModeProvider.notifier).state = AppMode.unset,
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
                          onPressed: live ? null : () => _start(1),
                          child: const Text('Start #1'),
                        ),
                        FilledButton(
                          onPressed: live ? null : () => _start(2),
                          child: const Text('Start #2'),
                        ),
                        OutlinedButton(
                          onPressed: live
                              ? null
                              : () => setState(() => exportCsv = tally
                                  .exportCsv(
                                      classLabel: label,
                                      dateIso: '2026-09-03')),
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
          ],
        ],
      ),
    );
  }
}
