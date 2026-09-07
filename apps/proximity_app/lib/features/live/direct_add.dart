// Direct add (prof live): professor-typed manual entry reusing the ONE
// unified [ManualAddForm] (shared with the saved-session editor).
//
// The form's three fields ARE the directory search (debounced online
// lookup, tap-a-card fills all three); ID-only submits resolve online or
// queue offline with a queued note — nothing is lost. Present means every
// round taken (intersection): re-adding one shows 'Already marked
// present.' while partials still go through.
library;

import 'package:flutter/material.dart';

import '../../widgets/manual_add.dart';
import '../../widgets/prox_states.dart';

class DirectAddSection extends StatelessWidget {
  final String course;
  final String sessionId;
  final Future<void> Function(
      {required String name,
      required String roll,
      required String email}) onAdd;
  final bool Function(String email) isPresent;

  const DirectAddSection({
    super.key,
    required this.course,
    required this.sessionId,
    required this.onAdd,
    required this.isPresent,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const ProxSectionHeader(
          title: 'Direct manual entry',
          padding: EdgeInsets.zero,
        ),
        ManualAddForm(
          fieldPrefix: 'direct',
          course: course,
          sessionId: sessionId,
          onAdd: onAdd,
          isPresent: isPresent,
        ),
      ],
    );
  }
}
