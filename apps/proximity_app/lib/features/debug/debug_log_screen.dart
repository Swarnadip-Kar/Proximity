// Full-screen filterable system-log terminal. Replaces every inline
// Show-log toggle: records screens now carry a Log affordance (terminal
// icon) that pushes here instead of embedding a collapsible log.
//
// Design: mirrors the BleLog ring (50k entries — a full lecture stays
// greppable); the view renders a 500-row window, never the whole ring.
// Bursty entries coalesce through a 200ms flush timer (≤5 setStates/s);
// rows are plain monospace Text (SelectableText regions cost real
// frames under beacon load — the Copy button is the copy path);
// autoscroll jumps once per flush and only while pinned near the bottom.
// BLE/MESH chatter is muted BY DEFAULT (stored, just not shown — tap a
// chip to include it); an explicit chip selection shows exactly that.
// Filter chips narrow by tag (dots colored by category via
// logCategoryColor, §4.5); no entrance animation (a terminal must never
// replay motion), so this screen is reduced-motion safe by construction.
//
// Restyle notes (presentation only — data contract unchanged): chrome
// reads Foundation tokens. The terminal well itself stays
// brightness-independent black by design ([ProxPalette.terminalBlack] +
// frozen [ProxLogColors] line vocabulary); header/borders/count copy read
// `ProximityColors` so both themes ship at parity. [initialTags] carries
// the log drawer's tag selection into `Expand` (additive — an explicit
// selection disables the BLE/MESH mute for exactly those tags).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proximity_ble/ble.dart';

import '../../design/app_theme.dart';
import '../../design/tokens.dart';
import '../../main.dart';
import '../../widgets/log_category.dart';

class DebugLogScreen extends StatefulWidget {
  /// Pre-selected tag filter (empty = show all tags).
  final Set<String> initialTags;

  const DebugLogScreen({super.key, this.initialTags = const {}});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  static const _cap = BleLog.cap;

  /// Rows rendered (the ring holds far more — this window keeps frames).
  static const _renderCap = 500;

  /// Lines the Copy button places on the clipboard (bounded: a full-ring
  /// paste would jank + overflow mobile clipboards).
  static const _copyCap = 2000;

  static const _flushEvery = ProxDurations.logFlush;
  static const _tags = ProxLogTags.all;

  final List<BleLogEntry> _entries = [];
  final List<BleLogEntry> _pending = [];
  StreamSubscription<BleLogEntry>? _sub;
  Timer? _flush;
  final ScrollController _scroll = ScrollController();

  /// True while the user is pinned near the bottom (autoscroll engaged).
  var _stick = true;

  /// Empty = show all tags.
  late final Set<String> _only = {...widget.initialTags};

  /// True once named-route arguments have been merged (once per mount).
  var _routeTagsApplied = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Named `debug/log` pushes via the route table build a const screen
    // (no constructor tags) — the drawer's Expand carries its selection in
    // settings.arguments instead (see log_drawer). Merge once so the
    // filter survives the named identity without touching the table.
    if (_routeTagsApplied) return;
    _routeTagsApplied = true;
    try {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map && args['initialTags'] is List) {
        final tags =
            (args['initialTags'] as List).whereType<String>().toSet();
        if (tags.isNotEmpty) _only.addAll(tags);
      } else if (args is Set<String> && args.isNotEmpty) {
        _only.addAll(args);
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    final history = BleLog.history;
    _entries.addAll(
        history.length > _cap ? history.sublist(history.length - _cap) : history);
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
      if (_entries.length > _cap) {
        _entries.removeRange(0, _entries.length - _cap);
      }
    });
    if (_stick) _scrollToEnd();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _flush?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    Future.microtask(() {
      if (!mounted || !_scroll.hasClients) return;
      try {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      } catch (_) {}
    });
  }

  List<BleLogEntry> get _filtered {
    final base = _only.isEmpty
        ? _entries
        : _entries.where((e) => _only.contains(e.tag)).toList();
    // Quiet by default: radio chatter hides until the reader taps its
    // chip. An explicit chip selection shows exactly that (mute never
    // overrides a choice).
    if (_only.isEmpty) {
      return base.where((e) => !BleLog.mutedTags.contains(e.tag)).toList();
    }
    return base;
  }

  /// Render window over [_filtered] (newest slice, never the whole ring).
  List<BleLogEntry> get _visible {
    final all = _filtered;
    return all.length > _renderCap
        ? all.sublist(all.length - _renderCap)
        : all;
  }

  /// True while the quiet default applies (no inclusive chip selection).
  bool get _quiet => _only.isEmpty;

  Color _colorFor(String tag) => ProxLogColors.of(tag);

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

  /// Copies the filtered buffer (bounded — newest slice + truncation
  /// note, never a 50k-line paste) to the clipboard for field reports.
  Future<void> _copy() async {
    final all = _filtered;
    final take = all.length > _copyCap
        ? all.sublist(all.length - _copyCap)
        : all;
    final buf = StringBuffer();
    for (final e in take) {
      buf.writeln(e.line);
    }
    if (take.length < all.length) {
      buf.writeln(
          '…(latest $take of ${all.length} matching lines)');
    }
    try {
      await Clipboard.setData(ClipboardData(text: buf.toString()));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Copied ${take.length} lines'),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final total = _entries.length;
    final visible = _visible;
    return AdaptiveScaffold(
      title: 'System log',
      actions: [
        IconButton(
          icon: const Icon(Icons.content_copy),
          tooltip: 'Copy',
          onPressed: () => unawaited(_copy()),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Clear',
          onPressed: _clear,
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(ProxSpacing.screenMargin),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: ProxSpacing.xs),
                  child: FilterChip(
                    label: const Text('All'),
                    selected: _only.isEmpty,
                    onSelected: (_) => setState(_only.clear),
                  ),
                ),
                for (final tag in _tags)
                  Padding(
                    padding: const EdgeInsets.only(right: ProxSpacing.xs),
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
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ProxSpacing.screenMargin,
            ),
            child: Text(
              _quiet
                  ? 'showing latest ${visible.length} of $total events · BLE, MESH hidden — tap a chip to show'
                  : 'showing latest ${visible.length} of $total events'
                      '${_only.isEmpty ? '' : ' · ${_only.join(', ')}'}',
              style: proxTabular(
                context,
                Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: c.contentSecondary,
                    ),
              ),
            ),
          ),
          const SizedBox(height: ProxSpacing.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                ProxSpacing.screenMargin,
                0,
                ProxSpacing.screenMargin,
                ProxSpacing.screenMargin,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: ProxPalette.terminalBlack,
                  borderRadius:
                      BorderRadius.circular(ProxRadii.terminal),
                  border: Border.all(color: c.divider),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: ProxSpacing.sm,
                          vertical: ProxSpacing.xs),
                      decoration: BoxDecoration(
                        color: c.surfaceOverlay,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(ProxRadii.terminal),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.terminal,
                            size: 14,
                            color: c.contentSecondary,
                          ),
                          const SizedBox(width: ProxSpacing.sm),
                          Expanded(
                            child: Text(
                              'system log',
                              style: ProxType.caption(
                                color: c.contentSecondary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: visible.isEmpty
                          ? Center(
                              child: Text(
                                'No events yet — start a window / join a class.',
                                style: ProxType.monoCaption(
                                  color: ProxLogColors.of(
                                    ProxLogTags.state,
                                  ),
                                ),
                              ),
                            )
                          : NotificationListener<ScrollNotification>(
                              onNotification: (n) {
                                if (n is ScrollUpdateNotification &&
                                    n.metrics.maxScrollExtent > 0) {
                                  _stick =
                                      n.metrics.maxScrollExtent -
                                              n.metrics.pixels <
                                          100;
                                }
                                return false;
                              },
                              child: ListView.builder(
                                controller: _scroll,
                                padding: const EdgeInsets.all(
                                  ProxSpacing.sm,
                                ),
                                itemCount: visible.length,
                                addAutomaticKeepAlives: false,
                                itemBuilder: (ctx, i) {
                                  final e = visible[i];
                                  return Text(
                                    e.line,
                                    style: ProxType.monoCaption(
                                      color: _colorFor(e.tag),
                                    ),
                                  );
                                },
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
