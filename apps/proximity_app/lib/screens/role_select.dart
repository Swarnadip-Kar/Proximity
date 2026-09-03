import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../main.dart';
import '../mode.dart';
import 'enrollment.dart';

class RoleSelectScreen extends ConsumerWidget {
  const RoleSelectScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linked = ref.watch(linkedIdentityProvider);
    void go(Widget screen) => Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen));
    return AdaptiveScaffold(
      title: 'Proximity',
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Campus Attendance',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(
                  linked == null
                      ? 'One app, two modes. Foreground-required during windows.'
                      : 'Enrolled as ${linked.name}${linked.roll.isNotEmpty ? ' · ${linked.roll}' : ''} · ${linked.gmail}. Identity auto-attaches in class.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.school),
                  label: const Text('Continue as Student'),
                  onPressed: () => ref.read(appModeProvider.notifier).state =
                      AppMode.student,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.present_to_all),
                  label: const Text('Continue as Professor (host)'),
                  onPressed: () => ref.read(appModeProvider.notifier).state =
                      AppMode.prof,
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  icon: const Icon(Icons.badge),
                  label: Text(linked == null
                      ? 'Enroll this device (online, once)'
                      : 'Re-enroll this device'),
                  onPressed: () => go(const EnrollmentScreen()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
