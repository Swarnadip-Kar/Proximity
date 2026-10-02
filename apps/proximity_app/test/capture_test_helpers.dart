// Shared capture-suite helpers (was copy-pasted across the overlay
// fidelity suites). No tests live here — this file holds only the three
// helpers every preview-geometry suite needs.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';

/// Test stand-in for a live frame: self-maintains its native aspect
/// internally (like `CameraPreview`), so the suites can prove the loose
/// Stack never distorts it. The keyed child marks the painted frame for
/// measurement.
class NativeFeed extends StatelessWidget {
  final double ratio;
  const NativeFeed({super.key, required this.ratio});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: ratio,
      child: const SizedBox.expand(key: Key('feed')),
    );
  }
}

/// The preview Stack: the loose, centered Stack carrying the overlay
/// (Navigator/Overlay internals use different fits, so this is unique).
Finder previewStackFinder() => find.byWidgetPredicate((w) =>
    w is Stack &&
    w.fit == StackFit.loose &&
    w.alignment == Alignment.center &&
    w.children.whereType<CaptureOverlay>().isNotEmpty);

/// Strips `//` doc/provenance comments so source pins only see code.
String codeOf(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');
