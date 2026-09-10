//
// `widgets/manual_add.dart` (shared by the live direct entry and the
// saved-session editor). It moved here into `features/manual_attendance/`
// Search/queue orchestration now lives in `manual_directory.dart` (same
// module); this file is the form UI only. Restyle is tokens-only (error /
// secondary copy onto `ProximityColors`; directory hits render as the one
// shared `StudentCard`, §4.1).
//
// Submit path (unchanged, owned by the directory controller):
//   1. name + email present (typed or card-filled) → added at once.
//   2. ID only + online + directory holds that exact ID → name/email are
//      fetched and the add completes with a "Matched online" note.
//   3. ID only + online + no match → error asking for full details.
//   4. ID only + offline → the task is stored in the pending queue and
//      applied on the next sync, with a queued note. Nothing is lost.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/tokens.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/student_card.dart';
import 'manual_directory.dart';

class ManualAddForm extends ConsumerStatefulWidget {
  final String fieldPrefix;
  final String course;
  final String sessionId;
  final Future<void> Function(
      {required String name,
      required String roll,
      required String email}) onAdd;

  /// Present-check for the hosting list (live tally intersection on the
  /// take screen, session intersection on the edit page). When it returns
  /// true the form shows "Already marked present." instead of re-adding —
  /// partials (not in every round) still go through.
  final bool Function(String email)? isPresent;

  const ManualAddForm(
      {super.key,
      required this.fieldPrefix,
      required this.course,
      required this.sessionId,
      required this.onAdd,
      this.isPresent});

  @override
  ConsumerState<ManualAddForm> createState() => _ManualAddFormState();
}

class _ManualAddFormState extends ConsumerState<ManualAddForm> {
  final _nameCtrl = TextEditingController();
  final _rollCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  late final ManualDirectoryController _dir =
      ManualDirectoryController(ref);

  @override
  void dispose() {
    _dir.dispose();
    _nameCtrl.dispose();
    _rollCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  void _scheduleSearch() => _dir.scheduleSearch(
        roll: _rollCtrl.text,
        name: _nameCtrl.text,
        email: _emailCtrl.text,
      );

  bool get _hasQuery =>
      _rollCtrl.text.trim().isNotEmpty ||
      _nameCtrl.text.trim().isNotEmpty ||
      _emailCtrl.text.trim().isNotEmpty;

  void _fill(String name, String roll, String email) {
    _nameCtrl.text = name;
    _rollCtrl.text = roll;
    _emailCtrl.text = email;
  }

  void _clear() {
    _nameCtrl.clear();
    _rollCtrl.clear();
    _emailCtrl.clear();
  }

  Future<void> _submit() => _dir.submit(
        rollRaw: _rollCtrl.text,
        nameRaw: _nameCtrl.text,
        emailRaw: _emailCtrl.text,
        course: widget.course,
        sessionId: widget.sessionId,
        onAdd: widget.onAdd,
        isPresent: widget.isPresent,
        clearFields: _clear,
      );

  @override
  Widget build(BuildContext context) {
    final p = widget.fieldPrefix;
    return ListenableBuilder(
      listenable: _dir,
      builder: (context, _) {
        // A 1-char name never queries (withheld load-side), so it must not
        // read as "no match".
        final effectiveQuery = _rollCtrl.text.trim().isNotEmpty ||
            _emailCtrl.text.trim().isNotEmpty ||
            _nameCtrl.text.trim().length >= 2;
        final c = ProximityColors.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Type to search the online directory — tap a card to fill:',
              style: ProxType.caption(color: c.contentSecondary),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
            const SizedBox(height: ProxSpacing.xs),
            TextField(
              key: ValueKey('$p-roll'),
              controller: _rollCtrl,
              onChanged: (_) => _scheduleSearch(),
              decoration: const InputDecoration(
                labelText: 'ID Number (required)',
                prefixIcon: Icon(Icons.badge_outlined),
                suffixIcon: Icon(Icons.cloud_outlined),
                helperText: 'Searches the online student directory',
              ),
            ),
            const SizedBox(height: ProxSpacing.sm),
            TextField(
              key: ValueKey('$p-name'),
              controller: _nameCtrl,
              onChanged: (_) => _scheduleSearch(),
              decoration: const InputDecoration(
                labelText: 'Student name (fills from ID when online)',
                prefixIcon: Icon(Icons.person_outline),
                suffixIcon: Icon(Icons.cloud_outlined),
                helperText: 'Searches the online student directory',
              ),
            ),
            const SizedBox(height: ProxSpacing.sm),
            TextField(
              key: ValueKey('$p-email'),
              controller: _emailCtrl,
              onChanged: (_) => _scheduleSearch(),
              decoration: const InputDecoration(
                labelText: 'Student email (fills from ID when online)',
                prefixIcon: Icon(Icons.email_outlined),
                suffixIcon: Icon(Icons.cloud_outlined),
                helperText: 'Searches the online student directory',
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            if (_dir.searching) ...[
              const SizedBox(height: ProxSpacing.sm),
              const ProxLoadingRow(label: 'Searching online…'),
            ],
            if (_dir.searchOffline && _hasQuery) ...[
              const SizedBox(height: ProxSpacing.sm),
              Text(
                'Directory unreachable — your entry still saves (queued when needed).',
                style: ProxType.caption(color: c.contentSecondary),
              ),
            ],
            if (_dir.searchError.isNotEmpty && _hasQuery) ...[
              const SizedBox(height: ProxSpacing.sm),
              Text(
                'Directory search failed: ${_dir.searchError}',
                style: ProxType.caption(color: c.statusError),
              ),
            ],
            if (_dir.searchError.isEmpty &&
                !_dir.searching &&
                !_dir.searchOffline &&
                _dir.searched &&
                _hasQuery &&
                effectiveQuery &&
                _dir.hits.isEmpty) ...[
              const SizedBox(height: ProxSpacing.sm),
              Text(
                'No enrolled students match — they enroll once online in the native app.',
                style: ProxType.caption(color: c.contentSecondary),
              ),
            ],
            for (final h in _dir.hits)
              Padding(
                padding: const EdgeInsets.only(top: ProxSpacing.sm),
                child: StudentCard(
                  name: h.name.isEmpty ? h.email : h.name,
                  subtitle:
                      [if (h.roll.isNotEmpty) h.roll, h.email].join(' · '),
                  onTap: () =>
                      _dir.pickHit(h, widget.isPresent, _fill),
                ),
              ),
            if (_dir.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: ProxSpacing.xs),
                child: Text(_dir.error,
                    style: ProxType.caption(color: c.statusError)),
              ),
            if (_dir.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: ProxSpacing.xs),
                child: Text(
                  _dir.note,
                  style: ProxType.caption(color: c.contentSecondary),
                ),
              ),
            const SizedBox(height: ProxSpacing.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: ProxSecondaryButton(
                icon: _dir.busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child:
                            CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.person_add),
                label: const Text('Add & mark present'),
                onPressed: _dir.busy ? null : _submit,
              ),
            ),
          ],
        );
      },
    );
  }
}
