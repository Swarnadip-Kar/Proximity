// Join by IP (student mark): the single-field professor-IP entry +
// Join action. One dotted-quad box (digits + dots) + port; stray/double
// dots are ignored while parsing so pasted input still resolves.
//
// Modal-ready by construction (compact column, no screen padding of its
// own — the parent supplies it): it ships inline in the browse list today
// to preserve the tested join contract (keys `ipfield`/`ipport`, 'Join'),
// and can move into a `showModalBottomSheet` with no logic change.
// The last-joined IP pre-fills the field so rejoining costs zero taps.
library;

import 'package:flutter/material.dart';

import '../../widgets/ip_join.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_states.dart';

class JoinByIpSection extends StatelessWidget {
  final Key fieldKey;
  final String initial;
  final ValueChanged<String?> onChanged;
  final VoidCallback onJoin;
  final String joinError;

  const JoinByIpSection({
    super.key,
    required this.fieldKey,
    required this.initial,
    required this.onChanged,
    required this.onJoin,
    required this.joinError,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        IpJoinField(
          key: fieldKey,
          initial: initial,
          // Persist every complete IP as it is typed, so backing out
          // of Join never loses it — the next visit re-opens prefilled.
          onChanged: onChanged,
        ),
        const SizedBox(height: 8),
        ProxPrimaryButton(
          label: const Text('Join'),
          onPressed: onJoin,
        ),
        if (joinError.isNotEmpty) ...[
          const SizedBox(height: 8),
          ProxErrorNote(joinError),
        ],
      ],
    );
  }
}
