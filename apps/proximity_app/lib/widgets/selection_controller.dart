// Per-list selection state (§4.1, §11).
//
// Selection-mode state is a small [ChangeNotifier] scoped to the screen
// that owns the list — never lifted to a global provider. Multiple lists
// (roster vs inbox) must never share selection state.
//
// Usage per list (e.g. `live/<course>/inbox`, session multi-delete):
// ```dart
// SelectionScope( // fresh controller for THIS list only
//   child: MyListView(emails: [...]),
// )
// ```
// Inside, read `ref.watch(selectionControllerProvider)` /
// `ref.read(selectionControllerProvider)` (Riverpod) or place a
// `ListenableBuilder` on the controller directly. Exiting the scope
// disposes the controller (autoDispose) — state never leaks across lists.
//
// The manual-attendance module (`features/manual_attendance/`, Live
// section) owns its own [SelectionScope] instance per §4.8.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/platformx.dart' as platformx;
import '../design/tokens.dart';

/// Hold-and-tap membership for one list. IDs are caller-owned row keys
/// (e.g. lowercased emails); this class stores strings only.
class SelectionController extends ChangeNotifier {
  final Set<String> _ids = {};

  /// True while any row is selected (i.e. the list is in selection mode).
  bool get selecting => _ids.isNotEmpty;

  /// Currently selected IDs (unmodifiable snapshot).
  Set<String> get selectedIds => Set.unmodifiable(_ids);

  /// Number of selected rows (toolbar `Approve N` numerator).
  int get count => _ids.length;

  bool isSelected(String id) => _ids.contains(id);

  /// Enter selection mode with [id] selected (long-press entry).
  void select(String id) {
    if (_ids.add(id)) notifyListeners();
  }

  void deselect(String id) {
    if (_ids.remove(id)) notifyListeners();
  }

  void toggle(String id) {
    if (_ids.contains(id)) {
      _ids.remove(id);
    } else {
      _ids.add(id);
    }
    notifyListeners();
  }

  void selectAll(Iterable<String> ids) {
    final before = _ids.length;
    _ids.addAll(ids);
    if (_ids.length != before) notifyListeners();
  }

  /// Exit selection mode (toolbar Cancel / second long-press / back).
  void clear() {
    if (_ids.isNotEmpty) {
      _ids.clear();
      notifyListeners();
    }
  }
}

/// Scoped provider for the enclosing [SelectionScope]. Never read above a
/// scope — there is intentionally no app-wide instance.
final selectionControllerProvider =
    ChangeNotifierProvider.autoDispose<SelectionController>(
  (ref) => SelectionController(),
);

/// Provides a fresh [SelectionController] to exactly one list subtree.
/// Each list that supports hold-and-tap gets its own [SelectionScope];
/// siblings never share state.
class SelectionScope extends StatelessWidget {
  final Widget child;

  const SelectionScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        selectionControllerProvider
            .overrideWith((ref) => SelectionController()),
      ],
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Desktop mouse-first selection entry (tester-verified defect fix).
//
// Long-press is undiscoverable with a mouse, so desktop lists get two
// mouse-first affordances alongside the unchanged touch path: an explicit
// Select/Done toggle ([SelectionModeToggle], placed per list) and
// right-click-to-select (wired in `student_card.dart`). Both are gated on
// [isDesktopSelection]; both drive the SAME controller + toolbar (no new
// selection semantics, no Checkbox widgets anywhere).
// ---------------------------------------------------------------------------

/// True on desktop platforms via the repo's existing platformx flags —
/// never hardcoded [TargetPlatform] values. Web is excluded by the flags
/// themselves. Gates the mouse-first affordances only; touch paths never
/// read this (mobile behavior byte-identical).
bool get isDesktopSelection =>
    platformx.isMacOS || platformx.isWindows || platformx.isLinux;

/// Explicit Select/Done mode toggle for hold-and-tap lists (desktop only).
///
/// On desktop this renders a `Select` text button that arms selection
/// mode (plain left-clicks then toggle via the existing row behavior),
/// switching to `Done` (disarm + clear) while armed/selecting. Arming
/// only widens the rows' `selectionMode` in the owning list — the
/// [SelectionController] and [SelectionToolbar] contracts are untouched.
/// Renders nothing off-desktop (no toggle button on mobile).
class SelectionModeToggle extends StatelessWidget {
  /// Effective selection mode (`controller.selecting || armed`).
  final bool selecting;

  /// Arm selection mode (show `Done`, clicks toggle).
  final VoidCallback? onSelect;

  /// Disarm + clear (back to `Select`).
  final VoidCallback? onDone;

  const SelectionModeToggle({
    super.key,
    required this.selecting,
    this.onSelect,
    this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    if (!isDesktopSelection) return const SizedBox.shrink();
    return TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(64, ProxSpacing.minTap),
      ),
      onPressed: selecting ? onDone : onSelect,
      child: Text(selecting ? 'Done' : 'Select'),
    );
  }
}

// ---------------------------------------------------------------------------
// Hold-to-select coach-mark (§9): one-time, dismissible, once per list-type
// per install. Presentation-scoped: a SharedPreferences flag colocated here
// with the selection controller (same per-list-type vocabulary), never in
// attendance state. Parent lists place ONE [SelectionCoachMark] above their
// rows (inbox, session multi-delete); it renders nothing once seen, while
// selecting, or when prefs are unreadable (fail-silent, never nagging).
// ---------------------------------------------------------------------------

/// List-type vocabulary for the coach-mark flag. One entry per selectable
/// list in the app (§4.1): the manual-attendance inbox + the course
/// sessions multi-delete. Roster/waiting rows are not selectable, so they
/// get no entry and no mark.
abstract final class SelectionCoachMarks {
  /// Manual-attendance inbox (`ManualInboxView`).
  static const String inbox = 'inbox';

  /// Saved-session multi-delete (`_OverviewBody`).
  static const String sessions = 'sessions';

  /// Prefs key for [listType]. Versioned (`v1`) so future copy changes can
  /// re-show once without colliding with old flags.
  static String prefsKey(String listType) => 'prox.coachMark.$listType.v1';
}

/// Reads the persisted coach-mark flag. Pure async helper (unit-testable
/// against [SharedPreferences.setMockInitialValues]); false on any error.
Future<bool> selectionCoachMarkSeen(String listType) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(SelectionCoachMarks.prefsKey(listType)) ?? false;
  } catch (_) {
    // Fail-silent: callers treat unreadable prefs as seen (hide the mark
    // rather than risk nagging every launch when persistence is broken).
    return true;
  }
}

/// Persists the coach-mark flag. Never throws.
Future<void> dismissSelectionCoachMark(String listType) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(SelectionCoachMarks.prefsKey(listType), true);
  } catch (_) {
    // Best-effort only: the in-memory hide below still applies this launch.
  }
}

/// One-time "Hold to select" discoverability hint (§9) for exactly one
/// list type. Collapsed by default in spirit: renders nothing once the
/// persisted flag is set, once dismissed this launch, or while the owning
/// list is in selection mode (the toolbar owns that moment instead).
class SelectionCoachMark extends StatefulWidget {
  /// Which list this mark belongs to ([SelectionCoachMarks.inbox] etc.).
  final String listType;

  /// True while the owning list is in selection mode (bind to
  /// `controller.selecting`) — the mark hides while selecting.
  final bool selecting;

  const SelectionCoachMark({
    super.key,
    required this.listType,
    required this.selecting,
  });

  @override
  State<SelectionCoachMark> createState() => _SelectionCoachMarkState();
}

class _SelectionCoachMarkState extends State<SelectionCoachMark> {
  bool? _seen;
  var _dismissed = false;

  @override
  void initState() {
    super.initState();
    _query();
  }

  void _query() {
    selectionCoachMarkSeen(widget.listType).then((seen) {
      if (mounted) setState(() => _seen = seen);
    });
  }

  @override
  void didUpdateWidget(SelectionCoachMark old) {
    super.didUpdateWidget(old);
    // A reused element retargeted at another list re-queries that list's
    // own flag (per-list-type, never shared).
    if (old.listType != widget.listType) {
      setState(() {
        _seen = null;
        _dismissed = false;
      });
      _query();
    }
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    await dismissSelectionCoachMark(widget.listType);
  }

  @override
  Widget build(BuildContext context) {
    // Unresolved → nothing yet (never a layout pop-in under content);
    // seen, dismissed, or selecting → nothing ever.
    if (_seen != false || _dismissed || widget.selecting) {
      return const SizedBox.shrink();
    }
    final c = ProximityColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: ProxSpacing.sm),
      child: Container(
        decoration: BoxDecoration(
          color: c.accentBrand.withValues(alpha: 0.08),
          borderRadius: ProxRadii.cardSpecRadius,
          border: Border.all(
            color: c.accentBrand.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: ProxSpacing.md),
            Icon(
              Icons.touch_app_outlined,
              size: 20,
              color: c.accentBrand,
            ),
            const SizedBox(width: ProxSpacing.sm),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: ProxSpacing.md,
                ),
                child: Text(
                  'Hold to select',
                  style: ProxType.label(color: c.contentPrimary),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(64, ProxSpacing.minTap),
              ),
              onPressed: _dismiss,
              child: const Text('Got it'),
            ),
          ],
        ),
      ),
    );
  }
}
