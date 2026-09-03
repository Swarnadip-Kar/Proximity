// One-time online enrollment: Google sign-in → device key → on-device
// face → upload key+faceHash. Nothing to type — identity imports from Gmail.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/enrollment.dart';
import '../main.dart';
import '../mode.dart';
import 'face_capture.dart';

class EnrollmentScreen extends ConsumerWidget {
  const EnrollmentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(enrollmentControllerProvider);
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    return AdaptiveScaffold(
      title: 'Enroll this device',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _step(1, 'Google sign-in', true,
                child: st.account == null
                    ? FilledButton.icon(
                        icon: const Icon(Icons.login),
                        label: const Text('Sign in with Google'),
                        onPressed: ctl.signIn,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                              'Signed in as ${st.account!.displayName}\n${st.account!.email}'),
                          const SizedBox(height: 8),
                          TextField(
                            decoration: const InputDecoration(
                              labelText: 'ID Number',
                              helperText:
                                  'Required. Saved with your profile.',
                            ),
                            onChanged: ctl.setRoll,
                          ),
                        ],
                      )),
            _step(2, 'Device key', st.phase.index >= 1,
                child: st.pkHex.isEmpty
                    ? FilledButton(
                        onPressed: ctl.generateKey,
                        child: const Text('Generate device key'),
                      )
                    : Text('Key: ${st.pkHex.substring(0, 16)}…')),
            _step(3, 'Face enrollment (on-device)',
                st.phase.index >= 2,
                child: st.phase.index < 3
                    ? FilledButton(
                        onPressed: () async {
                          final bytes =
                              await Navigator.of(context).push<Uint8List>(
                            MaterialPageRoute(
                                builder: (_) =>
                                    const FaceCaptureScreen()),
                          );
                          if (bytes != null) {
                            await ctl.captureFace(bytes);
                          }
                        },
                        child: const Text('Scan face'),
                      )
                    : const Text(
                        'Face detected and enrolled on this device. Template never leaves this phone.')),
            _step(4, 'Upload', st.phase.index >= 3,
                child: st.phase != EnrollPhase.uploaded
                    ? FilledButton(
                        onPressed: () async {
                          final id = await ctl.upload();
                          if (id != null && context.mounted) {
                            ref
                                .read(linkedIdentityProvider.notifier)
                                .state = id;
                          }
                        },
                        child: const Text('Upload enrollment'),
                      )
                    : const Text('✓ Enrolled. Identity linked for attendance.',
                        style: TextStyle(fontSize: 16))),
            if (st.phase == EnrollPhase.uploaded) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
            if (st.phase == EnrollPhase.error) ...[
              const SizedBox(height: 16),
              Text(st.message, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: ctl.dismissError,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _step(int n, String title, bool reached, {required Widget child}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('$n. $title',
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Opacity(opacity: reached || n == 1 ? 1.0 : 0.45, child: child),
        ],
      ),
    );
  }
}
