library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/tokens.dart';
import 'theme_mode.dart';

/// Theme row: Dark/Light/System 3-way segmented control, inline (the one
/// row that's a control, not a push). No checkboxes anywhere.
class AccountThemeRow extends ConsumerWidget {
  const AccountThemeRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final c = ProximityColors.of(context);
    // §10 narrow breakpoint: three icon+label segments overflow below
    // 360dp at large system type, so narrow renders label-only segments
    // (words carry the choice; icons return at ≥360dp).
    final narrow = ProxLayout.isNarrow(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Theme',
          style: ProxType.label(color: c.contentSecondary),
        ),
        const SizedBox(height: ProxSpacing.sm),
        SegmentedButton<ThemeMode>(
          key: const Key('account-theme-control'),
          style: SegmentedButton.styleFrom(
            minimumSize: const Size(64, ProxSpacing.minTap),
          ),
          segments: [
            ButtonSegment(
              value: ThemeMode.system,
              label: const Text('System'),
              icon: narrow ? null : const Icon(Icons.settings_suggest_outlined),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              label: const Text('Light'),
              icon: narrow ? null : const Icon(Icons.light_mode_outlined),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              label: const Text('Dark'),
              icon: narrow ? null : const Icon(Icons.dark_mode_outlined),
            ),
          ],
          selected: {mode},
          onSelectionChanged: (s) {
            unawaited(ref.read(themeModeProvider.notifier).set(s.first));
          },
        ),
      ],
    );
  }
}
