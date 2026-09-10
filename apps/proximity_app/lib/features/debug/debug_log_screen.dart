// Full-screen filterable system-log terminal. Replaces every inline
// Show-log toggle: records screens now carry a Log affordance (terminal
// icon) that pushes here instead of embedding a collapsible log.
//
// Design: mirrors the 500-entry BleLog ring buffer (never grows unbounded);
// bursty entries coalesce through a 200ms flush timer (≤5 setStates/s);
// rows are plain monospace Text (500 SelectableText regions cost real
// frames under beacon load — adb logcat remains the grep/copy path);
// autoscroll jumps once per flush and only while pinned near the bottom.
// Filter chips narrow by tag (dots colored by category via
// logCategoryColor, §4.5); no entrance animation (a terminal must never
// replay motion), so this screen is reduced-motion safe by construction.
//
// Restyle notes (presentation only — data contract unchanged): chrome
// reads Foundation tokens. The terminal well itself stays
// brightness-independent black by design ([ProxPalette.terminalBlack] +
// frozen [ProxLogColors] line vocabulary); header/borders/count copy read
// `ProximityColors` so both themes ship at parity. [initialTags] carries
// the log drawer's tag selection into `Expand` (additive — default shows
// all, exactly as before).
library;

import 'dart:async';

import 'package:flutter/material.dart';
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

  List<BleLogEntry> get _visible => _only.isEmpty
      ? _entries
      : _entries.where((e) => _only.contains(e.tag)).toList();

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

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final visible = _visible;
    return AdaptiveScaffold(
      title: 'System log',
      actions: [
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
              '${visible.length} of ${_entries.length} events'
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
