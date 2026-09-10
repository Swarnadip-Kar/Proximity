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
// - `Expand` pushes the filterable full-screen `debug/log` view
//   (carrying the drawer's tag selection); the Account menu's `System log`
//   row remains the permanent entry point.
//
// The drawer is an overlay, never a route push of its own — proving/face
// screens keep listening while it is open (no navigation/lifecycle
// interruption).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:proximity_ble/ble.dart';

import '../design/tokens.dart';
import '../features/debug/debug_log_screen.dart';
import 'log_category.dart';

/// Opens the log drawer (peek ~30%, draggable full). Tag selection made
/// here carries into `Expand`.
Future<void> showLogDrawer(
  BuildContext context, {
  Set<String>? initialTags,
}) {
  final c = ProximityColors.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Scrim token end-stop (barrier takes a color, not a gradient).
    barrierColor: c.gradientScrim.colors.last,
    backgroundColor: c.gradientScrim.colors.first,
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

  const LogDrawerContent({
    super.key,
    required this.scrollController,
    this.initialTags,
  });

  @override
  State<LogDrawerContent> createState() => _LogDrawerContentState();
}

class _LogDrawerContentState extends State<LogDrawerContent> {
  static const _flushEvery = ProxDurations.logFlush;
  static const _stickThreshold = 100.0;

  final List<BleLogEntry> _entries = [];
  final List<BleLogEntry> _pending = [];
  StreamSubscription<BleLogEntry>? _sub;
  Timer? _flush;

  /// True while pinned near the bottom (autoscroll engaged).
  var _stick = true;

  /// Empty = show all tags.
  late final Set<String> _only = {...?widget.initialTags};

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

  List<BleLogEntry> get _visible => _only.isEmpty
      ? _entries
      : _entries.where((e) => _only.contains(e.tag)).toList();

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
    final tags = Set<String>.of(_only);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DebugLogScreen(initialTags: tags),
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
                  '${visible.length} of ${_entries.length}',
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
                    label: const Text('All'),
                    selected: _only.isEmpty,
                    onSelected: (_) => setState(_only.clear),
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
