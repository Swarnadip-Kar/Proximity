// LogDrawer — the contextual quick-peek system-log drawer (§4.5).
//
// Data contract unchanged (`BleLog` stream, same tags, 500-entry ring —
// restyle only):
// - Collapsible drawer from the bottom edge: peek ~30% of screen
//   ([showLogDrawer] uses `initialChildSize: 0.3`), draggable to full
//   height (`maxChildSize: 1.0`).
// - Monospace, autoscroll (sticks while pinned near the bottom, <100px),
//   live while the drawer is open (subscribes on open, cancels on close),
//   still writing to the ring buffer while closed.
// - Tag chips colored by category (see [logCategoryColor], drawn from the
//   `status.*`/`accent.brand` family); log lines keep the frozen
//   [ProxLogColors] terminal vocabulary.
// - `Expand` closes the sheet and pushes the ONE named `debug/log` route
//   (carrying the drawer's tag selection, single back step tab-ward);
//   the Account menu's `System log` row remains the permanent entry point.
//
// The drawer is a persistent (non-modal) bottom sheet, never a route of
// its own: the shell tab bar stays tappable while it is open (Mark ↔
// Courses ↔ Account jumps keep working with the log peeked), and
// proving/face keep listening with no navigation/lifecycle interruption.
// Dismiss via the ✕ header action or drag-down; system back goes to the
// tab back contract, not the sheet.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:proximity_ble/ble.dart';

import '../design/tokens.dart';
import '../features/debug/debug_log_screen.dart';
import 'log_category.dart';
import 'log_filter.dart';

/// Opens the log drawer (peek ~30%, draggable full). Tag selection made
/// here carries into `Expand`.
///
/// Persistent (non-modal) sheet on the nearest Scaffold: no scrim, so the
/// shell tab bar stays tappable while the log is peeked. Falls back to a
/// modal sheet only when no Scaffold ancestor exists (never in production
/// — every opener sits under the shell or its own Scaffold).
///
/// UI Overhaul: uses a darker glass terminal treatment for a system
/// overlay feel rather than a standard sheet.
Future<void> showLogDrawer(
  BuildContext context, {
  Set<String>? initialTags,
}) {
  if (!context.mounted) return Future.value();
  final scaffold = Scaffold.maybeOf(context);
  if (scaffold == null) {
    return _showLogModal(context, initialTags: initialTags);
  }
  final height = MediaQuery.sizeOf(context).height;
  late final PersistentBottomSheetController controller;
  controller = scaffold.showBottomSheet(
    (sheetContext) => SizedBox(
      // Bounded height for the DraggableScrollableSheet (persistent
      // sheets size to content, which is unbounded): full-screen box,
      // the sheet inside still peeks at 30% and drags to full.
      height: height,
      child: DraggableScrollableSheet(
        initialChildSize: 0.3,
        minChildSize: 0.3,
        maxChildSize: 1.0,
        expand: false,
        builder: (_, scrollController) => LogDrawerContent(
          scrollController: scrollController,
          initialTags: initialTags,
          onClose: () => controller.close(),
        ),
      ),
    ),
    backgroundColor: Colors.transparent,
    enableDrag: true,
  );
  return controller.closed;
}

/// Modal fallback for Scaffold-less contexts (tests excluded — they pump
/// a Scaffold; production never hits this).
Future<void> _showLogModal(
  BuildContext context, {
  Set<String>? initialTags,
}) {
  if (!context.mounted) return Future.value();
  final c = ProximityColors.of(context);
  final glass = ProxGlass.terminalOf(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Scrim token end-stop (barrier takes a color, not a gradient).
    barrierColor: c.gradientScrim.colors.last,
    backgroundColor: glass.tintColor.withValues(alpha: glass.tintOpacity),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(ProxRadii.sheet),
      ),
    ),
    builder: (sheetContext) => DraggableScrollableSheet(
      initialChildSize: 0.3,
      minChildSize: 0.3,
      maxChildSize: 1.0,
      expand: false,
      builder: (_, scrollController) => LogDrawerContent(
        scrollController: scrollController,
        initialTags: initialTags,
        onClose: () => Navigator.of(sheetContext).maybePop(),
      ),
    ),
  );
}

/// Drawer body. Owns the live subscription while open; the ring buffer
/// keeps writing whether this is mounted or not.
class LogDrawerContent extends StatefulWidget {
  /// Scroll controller from the enclosing [DraggableScrollableSheet].
  final ScrollController scrollController;

  /// Pre-selected tag filter (empty = all). Carried into `Expand`.
  final Set<String>? initialTags;

  /// Dismisses the sheet (persistent-sheet close; modal pops). Null hides
  /// the ✕ action (direct test pumps that never open a sheet).
  final VoidCallback? onClose;

  const LogDrawerContent({
    super.key,
    required this.scrollController,
    this.initialTags,
    this.onClose,
  });

  @override
  State<LogDrawerContent> createState() => _LogDrawerContentState();
}

class _LogDrawerContentState extends State<LogDrawerContent> {
  static const _flushEvery = ProxDurations.logFlush;
  static const _stickThreshold = 100.0;

  final List<BleLogEntry> _entries = [];
  final List<BleLogEntry> _pending = [];
  int _dropped = 0;
  StreamSubscription<BleLogEntry>? _sub;
  Timer? _flush;

  /// True while pinned near the bottom (autoscroll engaged).
  var _stick = true;

  /// Empty = show all tags.
  late final Set<String> _only = {...?widget.initialTags};

  /// View density: quiet (default, BLE/MESH hidden) vs all (everything).
  /// An explicit tag selection always wins over the mode.
  var _mode = LogViewMode.quiet;

  @override
  void initState() {
    super.initState();
    final history = BleLog.history;
    _entries.addAll(
      history.length > BleLog.cap
          ? history.sublist(history.length - BleLog.cap)
          : history,
    );
    _sub = BleLog.stream.listen((e) {
      if (!mounted) return;
      // Storm cap: drawer buffers at most 200 pending lines per flush;
      // older lines drop with a counter instead of growing unbounded and
      // janking the 500ms flush on old phones.
      if (_pending.length >= 200) {
        _pending.removeAt(0);
        _dropped++;
      }
      _pending.add(e);
      _flush ??= Timer(_flushEvery, _applyPending);
    });
  }

  void _applyPending() {
    _flush = null;
    if (!mounted || _pending.isEmpty) return;
    setState(() {
      _entries.addAll(_pending);
      _pending.clear();
      if (_entries.length > BleLog.cap) {
        _entries.removeRange(0, _entries.length - BleLog.cap);
      }
    });
    if (_stick) _scrollToEnd();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _flush?.cancel();
    super.dispose();
  }

  void _scrollToEnd() {
    Future.microtask(() {
      if (!mounted) return;
      final ctl = widget.scrollController;
      if (!ctl.hasClients) return;
      try {
        ctl.jumpTo(ctl.position.maxScrollExtent);
      } catch (_) {}
    });
  }

  List<BleLogEntry> get _filtered => filterLogEntries(
        _entries,
        only: _only,
        mode: _mode,
        mutedTags: BleLog.mutedTags,
      );

  /// Render window over [_filtered] (the 50k ring never renders whole).
  List<BleLogEntry> get _visible {
    const renderCap = 500;
    final all = _filtered;
    return all.length > renderCap
        ? all.sublist(all.length - renderCap)
        : all;
  }

  /// True while the quiet default applies (no inclusive chip selection
  /// and the Quiet mode is armed).
  bool get _quiet => _only.isEmpty && _mode == LogViewMode.quiet;

  void _toggleTag(String tag) {
    setState(() {
      if (_only.contains(tag)) {
        _only.remove(tag);
      } else {
        _only.add(tag);
      }
    });
  }

  void _clear() {
    BleLog.clear();
    _pending.clear();
    setState(_entries.clear);
  }

  void _expand() {
    // ONE named `debug/log` identity: the persistent sheet is NOT a route
    // (replacing would eat the tab root), so close the sheet first, then
    // push — back still goes tab-ward in a single step. Named via
    // settings (same `debug/log` as the route table) while carrying the
    // drawer's tag selection + view mode via constructor — no table change
    // needed.
    // The Navigator is captured before the close (the sheet subtree
    // unmounts under it).
    final tags = Set<String>.of(_only);
    final showAll = _mode == LogViewMode.all;
    final nav = Navigator.of(context);
    widget.onClose?.call();
    nav.push(
      MaterialPageRoute(
        settings: RouteSettings(
          name: 'debug/log',
          arguments: {'initialTags': tags.toList(), 'showAll': showAll},
        ),
        builder: (_) =>
            DebugLogScreen(initialTags: tags, initialShowAll: showAll),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final visible = _visible;
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: ProxRadii.sheetTopRadius,
        boxShadow: [c.elevationSheet],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: ProxSpacing.sm),
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: c.divider,
                borderRadius: BorderRadius.circular(ProxRadii.pill),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ProxSpacing.screenMargin,
              ProxSpacing.sm,
              ProxSpacing.screenMargin,
              0,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 16,
                  color: c.contentSecondary,
                ),
                const SizedBox(width: ProxSpacing.sm),
                Expanded(
                  child: Text(
                    'System log',
                    style: ProxType.title(color: c.contentPrimary),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                Text(
                  _dropped > 0
                      ? '${visible.length} of ${_filtered.length} (+$_dropped dropped)'
                      : _quiet
                          ? '${visible.length} of ${_filtered.length} · BLE, MESH hidden'
                          : _only.isEmpty
                              ? '${visible.length} of ${_filtered.length} · all incl. BLE, MESH'
                              : '${visible.length} of ${_filtered.length}',
                  style: ProxType.caption(color: c.contentSecondary),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize:
                        const Size(64, ProxSpacing.minTap),
                  ),
                  onPressed: _expand,
                  child: const Text('Expand'),
                ),
                IconButton(
                  tooltip: 'Clear',
                  iconSize: 20,
                  constraints: const BoxConstraints(
                    minWidth: ProxSpacing.minTap,
                    minHeight: ProxSpacing.minTap,
                  ),
                  onPressed: _clear,
                  icon: const Icon(Icons.delete_outline),
                ),
                if (widget.onClose != null)
                  IconButton(
                    tooltip: 'Close',
                    iconSize: 20,
                    constraints: const BoxConstraints(
                      minWidth: ProxSpacing.minTap,
                      minHeight: ProxSpacing.minTap,
                    ),
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: ProxSpacing.screenMargin,
              vertical: ProxSpacing.sm,
            ),
            child: Row(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.only(right: ProxSpacing.xs),
                  child: FilterChip(
                    label: const Text('Quiet'),
                    tooltip: 'All except BLE/MESH radio chatter',
                    selected:
                        _only.isEmpty && _mode == LogViewMode.quiet,
                    onSelected: (_) => setState(() {
                      _only.clear();
                      _mode = LogViewMode.quiet;
                    }),
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.only(right: ProxSpacing.xs),
                  child: FilterChip(
                    label: const Text('All'),
                    tooltip: 'Everything, including BLE/MESH',
                    selected: _only.isEmpty && _mode == LogViewMode.all,
                    onSelected: (_) => setState(() {
                      _only.clear();
                      _mode = LogViewMode.all;
                    }),
                  ),
                ),
                for (final tag in ProxLogTags.all)
                  Padding(
                    padding:
                        const EdgeInsets.only(right: ProxSpacing.xs),
                    child: FilterChip(
                      avatar: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: logCategoryColor(context, tag),
                        ),
                      ),
                      label: Text(tag),
                      selected: _only.contains(tag),
                      onSelected: (_) => _toggleTag(tag),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(
                ProxSpacing.screenMargin,
                0,
                ProxSpacing.screenMargin,
                ProxSpacing.screenMargin,
              ),
              decoration: BoxDecoration(
                color: ProxPalette.terminalBlack,
                borderRadius:
                    BorderRadius.circular(ProxRadii.terminal),
                border: Border.all(color: c.divider),
              ),
              clipBehavior: Clip.antiAlias,
              child: visible.isEmpty
                  ? Center(
                      child: Text(
                        'No events yet — start a window / join a class.',
                        style: ProxType.monoCaption(
                          color: ProxLogColors.of(ProxLogTags.state),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n is ScrollUpdateNotification &&
                            n.metrics.maxScrollExtent > 0) {
                          _stick =
                              n.metrics.maxScrollExtent -
                                      n.metrics.pixels <
                                  _stickThreshold;
                        }
                        return false;
                      },
                      child: ListView.builder(
                        controller: widget.scrollController,
                        padding: const EdgeInsets.all(ProxSpacing.sm),
                        itemCount: visible.length,
                        addAutomaticKeepAlives: false,
                        itemBuilder: (_, i) {
                          final e = visible[i];
                          return Text(
                            e.line,
                            style: ProxType.monoCaption(
                              color: ProxLogColors.of(e.tag),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
